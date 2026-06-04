import { useRef, useState } from "react";
import { readFileSync, readdirSync } from "node:fs";
import { execFile } from "node:child_process";
import os from "node:os";
import { usePoll } from "./poll.js";

/**
 * Local system-resource sampler for the dashboard's llama.cpp/resource box.
 *
 * Deliberately client-side: these are read-only probes of /proc, /sys and
 * (best-effort) `nvidia-smi` — pure observability, no wallet state, so per
 * the layer discipline they do NOT get a daemon RPC. Matches the existing
 * pattern of the TUI shelling out (`tail -F` in NetworkMonitor, systemctl
 * in StatusFlow). Every read is wrapped so a locked-down deploy that hides
 * /sys or lacks nvidia-smi renders "n/a" instead of crashing the render.
 */

export type GpuStat = {
  name: string;
  utilPct?: number;
  vramUsedMb?: number;
  vramTotalMb?: number;
};

export type SystemStats = {
  cpuPct: number | null;
  load1: number | null;
  cores: number;
  memUsedKb: number | null;
  memTotalKb: number | null;
  gpus: GpuStat[];
};

type CpuSample = { busy: number; total: number };

/** Parse the aggregate "cpu " line of /proc/stat into busy/total jiffies.
 *  busy = user+nice+system+irq+softirq+steal; total = busy+idle+iowait. */
function readCpuSample(): CpuSample | null {
  try {
    const first = readFileSync("/proc/stat", "utf8").split("\n")[0];
    if (!first || !first.startsWith("cpu ")) return null;
    const nums = first.trim().split(/\s+/).slice(1).map((x) => Number(x));
    const [user = 0, nice = 0, system = 0, idle = 0, iowait = 0, irq = 0, softirq = 0, steal = 0] = nums;
    const busy = user + nice + system + irq + softirq + steal;
    return { busy, total: busy + idle + iowait };
  } catch {
    return null;
  }
}

function readMemInfo(): { totalKb: number; availKb: number } | null {
  try {
    const txt = readFileSync("/proc/meminfo", "utf8");
    const grab = (key: string): number | null => {
      const m = txt.match(new RegExp(`^${key}:\\s+(\\d+) kB`, "m"));
      return m && m[1] ? Number(m[1]) : null;
    };
    const totalKb = grab("MemTotal");
    // MemAvailable (not MemFree) — the kernel's own estimate of what's
    // reclaimable; MemFree under-reports because of the page cache.
    const availKb = grab("MemAvailable");
    if (totalKb === null || availKb === null) return null;
    return { totalKb, availKb };
  } catch {
    return null;
  }
}

/** Best-effort NVIDIA probe. Resolves [] when nvidia-smi is absent,
 *  errors, or times out — never rejects. */
function probeNvidia(): Promise<GpuStat[]> {
  return new Promise((resolve) => {
    try {
      execFile(
        "nvidia-smi",
        [
          "--query-gpu=name,utilization.gpu,memory.used,memory.total",
          "--format=csv,noheader,nounits",
        ],
        { timeout: 1500 },
        (err, stdout) => {
          if (err || !stdout) return resolve([]);
          const gpus: GpuStat[] = [];
          for (const line of stdout.trim().split("\n")) {
            const parts = line.split(",").map((s) => s.trim());
            if (parts.length < 4 || !parts[0]) continue;
            gpus.push({
              name: parts[0],
              utilPct: Number.isFinite(Number(parts[1])) ? Number(parts[1]) : undefined,
              vramUsedMb: Number.isFinite(Number(parts[2])) ? Number(parts[2]) : undefined,
              vramTotalMb: Number.isFinite(Number(parts[3])) ? Number(parts[3]) : undefined,
            });
          }
          resolve(gpus);
        },
      );
    } catch {
      resolve([]);
    }
  });
}

/** Best-effort AMD probe via sysfs. Card indices are NOT stable across
 *  boots/hosts, so we scan every /sys/class/drm/card* for the amdgpu
 *  utilization file rather than hardcoding card1. */
function probeAmdgpu(): GpuStat[] {
  const gpus: GpuStat[] = [];
  try {
    for (const entry of readdirSync("/sys/class/drm")) {
      if (!/^card\d+$/.test(entry)) continue;
      const dev = `/sys/class/drm/${entry}/device`;
      let utilPct: number | undefined;
      try {
        utilPct = Number(readFileSync(`${dev}/gpu_busy_percent`, "utf8").trim());
        if (!Number.isFinite(utilPct)) continue;
      } catch {
        continue; // not an amdgpu render node
      }
      const readNum = (p: string): number | undefined => {
        try {
          const n = Number(readFileSync(p, "utf8").trim());
          return Number.isFinite(n) ? n : undefined;
        } catch {
          return undefined;
        }
      };
      const vramUsed = readNum(`${dev}/mem_info_vram_used`);
      const vramTotal = readNum(`${dev}/mem_info_vram_total`);
      gpus.push({
        name: `amdgpu/${entry}`,
        utilPct,
        vramUsedMb: vramUsed !== undefined ? Math.round(vramUsed / (1024 * 1024)) : undefined,
        vramTotalMb: vramTotal !== undefined ? Math.round(vramTotal / (1024 * 1024)) : undefined,
      });
    }
  } catch {
    // /sys hidden (locked-down container) — fine, GPU renders as absent.
  }
  return gpus;
}

const EMPTY_STATS: SystemStats = {
  cpuPct: null,
  load1: null,
  cores: 0,
  memUsedKb: null,
  memTotalKb: null,
  gpus: [],
};

/** Core count never changes for the process lifetime, and os.cpus()
 *  allocates a full per-core array on each call — compute it once. */
const CORE_COUNT: number = (() => {
  try {
    return os.cpus().length;
  } catch {
    return 0;
  }
})();

/** Poll CPU / mem / load / GPU. CPU% needs two samples; the first tick
 *  after mount reports null and the second onwards report the busy delta
 *  between consecutive ticks. The GPU probe is decoupled onto a slower
 *  cadence (`gpuEveryNTicks`) — `nvidia-smi` re-inits NVML per fork
 *  (tens-to-hundreds of ms), so we sample it ~every 10s instead of every
 *  CPU tick, and short-circuit once we've learned no GPU is present. */
export function useSystemStats(intervalMs: number): SystemStats {
  const [stats, setStats] = useState<SystemStats>(EMPTY_STATS);
  const prevCpu = useRef<CpuSample | null>(null);
  const gpuTick = useRef(0);
  const gpuRef = useRef<GpuStat[]>([]);
  // null = unknown, false = probed and none found (stop forking nvidia-smi).
  const gpuPresent = useRef<boolean | null>(null);
  const gpuEveryNTicks = Math.max(1, Math.round(10_000 / intervalMs));

  usePoll(
    async (isCancelled) => {
      const cur = readCpuSample();
      let cpuPct: number | null = null;
      if (cur && prevCpu.current) {
        const dBusy = cur.busy - prevCpu.current.busy;
        const dTotal = cur.total - prevCpu.current.total;
        if (dTotal > 0) cpuPct = Math.max(0, Math.min(100, Math.round((100 * dBusy) / dTotal)));
      }
      if (cur) prevCpu.current = cur;
      const mem = readMemInfo();

      // GPU: probe on the slow sub-cadence, and skip nvidia-smi entirely
      // once we've established there's no GPU on this host.
      const doGpu =
        gpuPresent.current !== false && gpuTick.current % gpuEveryNTicks === 0;
      gpuTick.current += 1;
      if (doGpu) {
        const nvidia = await probeNvidia();
        if (isCancelled()) return;
        const gpus = nvidia.length > 0 ? nvidia : probeAmdgpu();
        gpuRef.current = gpus;
        if (gpuPresent.current === null) gpuPresent.current = gpus.length > 0;
      }

      let load1: number | null = null;
      try {
        load1 = os.loadavg()[0] ?? null;
      } catch {
        load1 = null;
      }
      setStats({
        cpuPct,
        load1,
        cores: CORE_COUNT,
        memUsedKb: mem ? mem.totalKb - mem.availKb : null,
        memTotalKb: mem ? mem.totalKb : null,
        gpus: gpuRef.current,
      });
    },
    intervalMs,
    [],
  );

  return stats;
}
