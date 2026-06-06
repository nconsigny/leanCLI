import { useState } from "react";
import { call } from "../daemon.js";
import { usePoll } from "./poll.js";

/**
 * RPC-config box data: which endpoint is configured, which read backend
 * is active, and the light-client / ORAM-TEE sidecar states. One
 * Promise.all over five cheap status RPCs every few seconds —
 * deliberately NOT status.snapshot, which is ~10x heavier (sidecar
 * pings + DNS + ip-route subprocesses).
 *
 * Helios/Colibri status is {running, socket?} only — no chainId/sync
 * detail exists daemon-side. The ACTIVE read endpoint can differ from
 * the configured one: when SafeNode (ORAM-TEE) is running and chainId is
 * 1/11155111, the daemon substitutes the attested proxy as helios's
 * executionRpc (Endpoints.lean applySafeNodeOverride) — `oramProxyUrl`
 * surfaces that so the box can label the real read source.
 */

export type ReadBackend = "rpc" | "colibri" | "helios";

type RunStatus = { running: boolean; socket?: string };

type SafeNodeStatus = {
  running: boolean;
  socket?: string;
  attestation?: {
    proxyUrl?: string;
    teeType?: string;
    pin?: string;
    attestedAtMs?: number;
    supportedChainIds?: number[];
  } & Record<string, unknown>;
  error?: { code: number; message: string };
  crash?: string;
};

type NetworkShow = {
  chainId: number;
  rpc: { url: string; transport: string; backend: string };
  ens: { url: string; transport: string; backend: string } | null;
  perChain: { name: string; chainId: number; url: string; transport: string; backend: string; isCurrent: boolean }[];
  policy: string;
  logPath: string | null;
  lightclient: boolean;
};

export type RpcConfig = {
  chainId: number | null;
  /** Active chain's configured name (perChain isCurrent), else mapped. */
  chainName: string | null;
  rpcUrl: string | null;
  transport: string | null;
  policy: string | null;
  logPath: string | null | undefined;
  ensUrl: string | null;
  readBackend: ReadBackend | null;
  helios: RunStatus | null;
  colibri: RunStatus | null;
  safeNode: SafeNodeStatus | null;
  /** Non-null iff the ORAM proxy is actually substituted as the active
   *  execution endpoint (running + chainId in {1, 11155111}). */
  oramProxyUrl: string | null;
  /** Configured chains (from network.show perChain) for the chain
   *  cycler. `isCurrent` marks the daemon's active chain. */
  perChain: { name: string; chainId: number; isCurrent: boolean }[];
  error: string | null;
};

export type RpcActions = {
  /** Cycle the single-select provider rpc → helios → colibri → rpc.
   *  Atomic: starts the chosen light client, tears the other down, and
   *  points readBackend at it — so `✓ verified` is reached in one action
   *  instead of needing the backend and sidecar flipped separately. */
  cycleProvider: () => void;
  /** Set the provider directly (settings-menu rows). Same atomic switch. */
  setProvider: (p: ReadBackend) => void;
  /** ORAM-TEE (SafeNode) is an orthogonal on/off layer over whichever
   *  light client is active — NOT a third mutually-exclusive provider. */
  toggleSafeNode: () => void;
  /** Switch the daemon-wide active chain at runtime (network.use). */
  setChain: (chainId: number) => void;
  pending: string | null;
};

/** Providers in cycle order. Single-select: exactly one is the active
 *  read/simulate backend at a time. `rpc` is direct + unverified; helios
 *  and colibri are mutually-exclusive light clients. ORAM is not here —
 *  it is a separate layer (see `toggleSafeNode`). */
const PROVIDER_CYCLE: ReadBackend[] = ["rpc", "helios", "colibri"];

/**
 * Atomically switch the active provider. The daemon exposes three
 * decoupled knobs (`daemon.helios.toggle`, `daemon.colibri.toggle`,
 * `daemon.readBackend.set`); flipping only one leaves the others stale —
 * e.g. `backend=helios` with the helios sidecar down reads as "never
 * verified". This flips all of them together: it starts the chosen light
 * client, tears the other down (mutual exclusion), and sets readBackend.
 * SafeNode (ORAM) is left untouched — it layers over whichever provider
 * is active. Selecting `rpc` stops both light clients.
 */
async function applyProvider(p: ReadBackend): Promise<void> {
  if (p === "helios") {
    await call("daemon.helios.toggle", { enable: true }, { timeoutMs: 60_000 });
    await call("daemon.readBackend.set", { backend: "helios" });
    await call("daemon.colibri.toggle", { enable: false }, { timeoutMs: 60_000 });
  } else if (p === "colibri") {
    await call("daemon.colibri.toggle", { enable: true }, { timeoutMs: 60_000 });
    await call("daemon.readBackend.set", { backend: "colibri" });
    await call("daemon.helios.toggle", { enable: false }, { timeoutMs: 60_000 });
  } else {
    await call("daemon.readBackend.set", { backend: "rpc" });
    await call("daemon.helios.toggle", { enable: false }, { timeoutMs: 60_000 });
    await call("daemon.colibri.toggle", { enable: false }, { timeoutMs: 60_000 });
  }
}

function chainIdToName(id: number): string | null {
  if (id === 1) return "mainnet";
  if (id === 11155111) return "sepolia";
  if (id === 17000) return "holesky";
  return null;
}

const INITIAL: RpcConfig = {
  chainId: null,
  chainName: null,
  rpcUrl: null,
  transport: null,
  policy: null,
  logPath: undefined,
  ensUrl: null,
  readBackend: null,
  helios: null,
  colibri: null,
  safeNode: null,
  oramProxyUrl: null,
  perChain: [],
  error: null,
};

export function useRpcConfig(intervalMs: number): { cfg: RpcConfig; actions: RpcActions } {
  const [cfg, setCfg] = useState<RpcConfig>(INITIAL);
  const [pending, setPending] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  usePoll(
    async (isCancelled) => {
      const [show, rb, helios, colibri, safeNode] = await Promise.all([
        call<NetworkShow>("network.show", {}),
        call<{ backend?: string }>("daemon.readBackend.status", {}),
        call<RunStatus>("daemon.helios.status", {}),
        call<RunStatus>("daemon.colibri.status", {}),
        call<SafeNodeStatus>("daemon.safeNode.status", {}),
      ]);
      if (isCancelled()) return;
      if (!show.ok) {
        setCfg((c) => ({ ...c, error: show.error.message }));
        return;
      }
      const s = show.result;
      const backend = rb.ok ? rb.result.backend : undefined;
      const sn = safeNode.ok ? safeNode.result : null;
      const oramActive =
        sn?.running === true && (s.chainId === 1 || s.chainId === 11155111);
      setCfg({
        chainId: s.chainId ?? null,
        chainName:
          s.perChain?.find((c) => c.isCurrent)?.name ??
          chainIdToName(s.chainId ?? -1),
        rpcUrl: s.rpc?.url ?? null,
        transport: s.rpc?.transport ?? null,
        policy: s.policy ?? null,
        logPath: s.logPath,
        ensUrl: s.ens?.url ?? null,
        readBackend:
          backend === "rpc" || backend === "colibri" || backend === "helios"
            ? backend
            : null,
        helios: helios.ok ? helios.result : null,
        colibri: colibri.ok ? colibri.result : null,
        safeNode: sn,
        oramProxyUrl: oramActive ? (sn?.attestation?.proxyUrl ?? null) : null,
        perChain: (s.perChain ?? [])
          .filter((c) => c.chainId > 0)
          .map((c) => ({ name: c.name, chainId: c.chainId, isCurrent: c.isCurrent })),
        error: null,
      });
    },
    intervalMs,
    [refreshKey],
  );

  const refresh = () => setRefreshKey((k) => k + 1);

  const guard = (name: string, fn: () => Promise<void>) => () => {
    if (pending) return;
    setPending(name);
    void fn()
      .catch(() => {})
      .finally(() => {
        setPending(null);
        refresh();
      });
  };

  const actions: RpcActions = {
    pending,
    cycleProvider: guard("provider", async () => {
      const cur = cfg.readBackend ?? "rpc";
      const idx = PROVIDER_CYCLE.indexOf(cur);
      const next = PROVIDER_CYCLE[(idx + 1) % PROVIDER_CYCLE.length] ?? "rpc";
      await applyProvider(next);
    }),
    setProvider: (p: ReadBackend) => {
      if (pending) return;
      setPending("provider");
      void applyProvider(p)
        .catch(() => {})
        .finally(() => {
          setPending(null);
          refresh();
        });
    },
    toggleSafeNode: guard("oram-tee", async () => {
      // Enabling runs the full TDX quote-verify flow — seconds of latency.
      await call("daemon.safeNode.toggle", { enable: !(cfg.safeNode?.running === true) }, { timeoutMs: 120_000 });
    }),
    setChain: (chainId: number) => {
      if (pending) return;
      setPending("chain");
      void call("network.use", { chainId })
        .catch(() => {})
        .finally(() => {
          setPending(null);
          refresh();
        });
    },
  };

  return { cfg, actions };
}
