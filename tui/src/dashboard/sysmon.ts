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
  /** nvidia-smi / driver probe failure (e.g. the "Driver/library version
   *  mismatch" after a partial driver upgrade). null when the probe
   *  succeeded or the host genuinely has no NVIDIA tooling. Surfaced so a
   *  broken GPU driver no longer masquerades as "no GPU detected" — that
   *  silent fallback is exactly what hides llama running on CPU. */
  gpuError: string | null;
  /** llama-server process CPU%, htop convention (100% = one full core, so
   *  multi-core CPU inference reads e.g. 720%). null until two samples land
   *  or when no llama-server process is found. The tell-tale that the model
   *  is running on CPU rather than the GPU. */
  llamaCpuPct: number | null;
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

/** First non-blank line of a (possibly multi-line) string, capped so a
 *  surprise stderr dump can't blow up the render. */
function firstLine(s: string | null | undefined): string {
  if (!s) return "";
  const line = s.split("\n").find((l) => l.trim().length > 0) ?? "";
  return line.trim().slice(0, 120);
}

/** Best-effort NVIDIA probe. Never rejects. Resolves `{gpus, error}`:
 *  `error` is null on success OR when nvidia-smi is simply absent (ENOENT —
 *  an AMD/CPU-only box, not worth shouting about), and carries the failure
 *  message otherwise — notably the "Driver/library version mismatch" that
 *  follows a partial driver upgrade and silently drops llama onto the CPU. */
function probeNvidia(): Promise<{ gpus: GpuStat[]; error: string | null }> {
  return new Promise((resolve) => {
    try {
      execFile(
        "nvidia-smi",
        [
          "--query-gpu=name,utilization.gpu,memory.used,memory.total",
          "--format=csv,noheader,nounits",
        ],
        { timeout: 1500 },
        (err, stdout, stderr) => {
          if (err) {
            const code = (err as NodeJS.ErrnoException).code;
            if (code === "ENOENT") return resolve({ gpus: [], error: null });
            return resolve({
              gpus: [],
              error: firstLine(stderr) || firstLine(err.message) || "nvidia-smi failed",
            });
          }
          if (!stdout) return resolve({ gpus: [], error: null });
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
          resolve({ gpus, error: null });
        },
      );
    } catch {
      resolve({ gpus: [], error: null });
    }
  });
}

/** Sum of utime+stime (jiffies) for a pid, or null. The comm field in
 *  /proc/<pid>/stat may contain spaces and parens, so we slice after the
 *  final ')': the remaining whitespace-split tokens start at field 3
 *  (state), putting utime at index 11 and stime at index 12. */
function readProcJiffies(pid: number): number | null {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    const rparen = stat.lastIndexOf(")");
    if (rparen < 0) return null;
    const rest = stat.slice(rparen + 1).trim().split(/\s+/);
    const utime = Number(rest[11]);
    const stime = Number(rest[12]);
    if (!Number.isFinite(utime) || !Number.isFinite(stime)) return null;
    return utime + stime;
  } catch {
    return null;
  }
}

/** Find the llama-server PID by scanning /proc cmdlines. Best-effort:
 *  returns null when no matching process runs (server not spawned) or when
 *  /proc is hidden in a locked-down container. */
function findLlamaPid(): number | null {
  try {
    for (const entry of readdirSync("/proc")) {
      if (!/^\d+$/.test(entry)) continue;
      let cmd: string;
      try {
        cmd = readFileSync(`/proc/${entry}/cmdline`, "utf8").replace(/\0/g, " ");
      } catch {
        continue; // process exited mid-scan, or not ours to read
      }
      if (/llama[-_]?server|llama\.cpp/i.test(cmd)) return Number(entry);
    }
  } catch {
    // /proc unreadable — process CPU renders as n/a.
  }
  return null;
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
  gpuError: null,
  llamaCpuPct: null,
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
  const gpuErrRef = useRef<string | null>(null);
  // null = unknown, false = probed and none found (stop forking nvidia-smi).
  const gpuPresent = useRef<boolean | null>(null);
  const gpuEveryNTicks = Math.max(1, Math.round(10_000 / intervalMs));
  // llama-server pid cache + its previous (jiffies, total-cpu-jiffies) sample.
  const llamaPid = useRef<number | null>(null);
  const prevLlamaJif = useRef<{ jif: number; total: number } | null>(null);

  usePoll(
    async (isCancelled) => {
      const cur = readCpuSample();
      let cpuPct: number | null = null;
      if (cur && prevCpu.current) {
        const dBusy = cur.busy - prevCpu.current.busy;
        const dTotal = cur.total - prevCpu.current.total;
        if (dTotal > 0) cpuPct = Math.max(0, Math.min(100, Math.round((100 * dBusy) / dTotal)));
      }
      // llama-server process CPU% (htop convention, 100% = one core). Shares
      // the system total-jiffies delta as its denominator, so it must read
      // `cur.total` BEFORE prevCpu is overwritten below.
      let llamaCpuPct: number | null = null;
      if (cur) {
        let jif = llamaPid.current === null ? null : readProcJiffies(llamaPid.current);
        if (jif === null) {
          // No cached pid, or it exited — rediscover and reset the baseline.
          llamaPid.current = findLlamaPid();
          prevLlamaJif.current = null;
          jif = llamaPid.current === null ? null : readProcJiffies(llamaPid.current);
        }
        if (jif !== null) {
          const prev = prevLlamaJif.current;
          if (prev) {
            const dJif = jif - prev.jif;
            const dTotal = cur.total - prev.total;
            if (dTotal > 0 && dJif >= 0) {
              llamaCpuPct = Math.max(0, Math.round((100 * dJif * CORE_COUNT) / dTotal));
            }
          }
          prevLlamaJif.current = { jif, total: cur.total };
        }
      }

      if (cur) prevCpu.current = cur;
      const mem = readMemInfo();

      // GPU: probe on the slow sub-cadence. Latch "no GPU" (and stop forking
      // nvidia-smi) ONLY on a clean empty probe — when the probe FAILED
      // (driver mismatch) keep polling so a later driver fix is picked up.
      const doGpu =
        gpuPresent.current !== false && gpuTick.current % gpuEveryNTicks === 0;
      gpuTick.current += 1;
      if (doGpu) {
        const nvidia = await probeNvidia();
        if (isCancelled()) return;
        let gpus = nvidia.gpus;
        let gpuError = nvidia.error;
        if (gpus.length === 0) {
          const amd = probeAmdgpu();
          if (amd.length > 0) {
            gpus = amd;
            gpuError = null; // an AMD card answered; the nvidia miss is moot
          }
        }
        gpuRef.current = gpus;
        gpuErrRef.current = gpuError;
        if (gpuPresent.current === null) {
          gpuPresent.current = gpus.length > 0 ? true : gpuError ? null : false;
        }
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
        gpuError: gpuErrRef.current,
        llamaCpuPct,
      });
    },
    intervalMs,
    [],
  );

  return stats;
}
