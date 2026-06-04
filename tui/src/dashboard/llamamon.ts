import { useRef, useState } from "react";
import { usePoll } from "./poll.js";

/**
 * llama.cpp server monitor for the dashboard.
 *
 * The wallet daemon's only LLM RPC is `llm.ensureUp` ({outcome, baseUrl,
 * model?}) and it has a SIDE EFFECT — it may spawn llama-server. The
 * dashboard calls it once on open (Dashboard.tsx) and this module then
 * polls the server's own HTTP endpoints READ-ONLY on 127.0.0.1:
 *
 *   GET /v1/models  — liveness + model id (always available)
 *   GET /props      — n_ctx, total_slots, model path (no flag needed)
 *   GET /health     — 200 ok / 503 loading
 *   GET /slots      — per-slot busy state; REQUIRES `--slots` at launch
 *   GET /metrics    — Prometheus text; REQUIRES `--metrics` at launch
 *
 * The daemon's lazy spawn (LeanCli/Daemon/LlmServer.lean) hard-codes
 * --host/--port only, so /slots and /metrics 404 unless the operator set
 * LLM_SPAWN_ARGS="--slots --metrics" — we degrade to "n/a" and surface
 * that hint once. All of this is observability-only: nothing here ever
 * feeds a signing decision.
 */

export type LlamaStatus = {
  /** null until the first probe completes. */
  up: boolean | null;
  loading: boolean;
  model?: string;
  nCtx?: number;
  totalSlots?: number;
  slotsBusy?: number;
  /** false once /slots answered 404/501 — render the LLM_SPAWN_ARGS hint. */
  slotsAvailable: boolean | null;
  metricsAvailable: boolean | null;
  /** tokens/s derived from /metrics deltas (instantaneous) or lifetime avg. */
  tokPerSec?: number;
  tokSrc?: "metrics" | "metrics-avg";
};

const PROBE_TIMEOUT_MS = 1500;

async function getJson(url: string): Promise<{ status: number; body: unknown } | null> {
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(PROBE_TIMEOUT_MS) });
    let body: unknown = null;
    try {
      body = await r.json();
    } catch {
      body = null;
    }
    return { status: r.status, body };
  } catch {
    return null;
  }
}

async function getText(url: string): Promise<{ status: number; body: string } | null> {
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(PROBE_TIMEOUT_MS) });
    return { status: r.status, body: await r.text() };
  } catch {
    return null;
  }
}

/** "http://127.0.0.1:8080/v1" → "http://127.0.0.1:8080" (the non-/v1
 *  endpoints live at the server root). */
function rootOf(baseUrl: string): string {
  return baseUrl.replace(/\/v1\/?$/, "");
}

/** Pull `llamacpp:<name> <value>` out of Prometheus exposition text.
 *  llama.cpp emits unlabelled counters, so a line-wise split suffices. */
function promValue(text: string, name: string): number | null {
  const m = text.match(new RegExp(`^llamacpp:${name}(?:\\{[^}]*\\})? ([0-9.eE+-]+)$`, "m"));
  if (!m || !m[1]) return null;
  const n = Number(m[1]);
  return Number.isFinite(n) ? n : null;
}

type MetricsSample = { tokens: number; seconds: number; atMs: number };

const INITIAL: LlamaStatus = {
  up: null,
  loading: false,
  slotsAvailable: null,
  metricsAvailable: null,
};

/** Poll llama.cpp monitoring endpoints. `baseUrl` is llm.ensureUp's
 *  baseUrl (LLM_BASE_URL, "…/v1"); pass null to probe the default. */
export function useLlamaStatus(baseUrl: string | null, intervalMs: number): LlamaStatus {
  const [status, setStatus] = useState<LlamaStatus>(INITIAL);
  const prevMetrics = useRef<MetricsSample | null>(null);
  const base = baseUrl ?? "http://127.0.0.1:8080/v1";
  const root = rootOf(base);

  usePoll(
    async (isCancelled) => {
      const [models, props, health, slots, metrics] = await Promise.all([
        getJson(`${base}/models`),
        getJson(`${root}/props`),
        getJson(`${root}/health`),
        getJson(`${root}/slots`),
        getText(`${root}/metrics`),
      ]);
      if (isCancelled()) return;

      const next: LlamaStatus = {
        up: models !== null && models.status >= 200 && models.status < 500,
        loading: health !== null && health.status === 503,
        slotsAvailable: null,
        metricsAvailable: null,
      };

      // Model name: OpenAI shape data[0].id, llama.cpp legacy models[0].model
      // (same fallback order as the daemon's MiscRpc.lean probe).
      if (models?.body && typeof models.body === "object") {
        const b = models.body as Record<string, unknown>;
        const data = Array.isArray(b.data) ? (b.data as Record<string, unknown>[]) : undefined;
        const legacy = Array.isArray(b.models) ? (b.models as Record<string, unknown>[]) : undefined;
        const id = data?.[0]?.id ?? legacy?.[0]?.model;
        if (typeof id === "string" && id.length > 0) {
          // Model ids are often full .gguf paths — keep the basename.
          next.model = id.split("/").pop() ?? id;
        }
      }

      if (props?.status === 200 && props.body && typeof props.body === "object") {
        const b = props.body as Record<string, unknown>;
        const gen = b.default_generation_settings as Record<string, unknown> | undefined;
        if (gen && typeof gen.n_ctx === "number") next.nCtx = gen.n_ctx;
        if (typeof b.total_slots === "number") next.totalSlots = b.total_slots;
        if (!next.model && typeof b.model_path === "string") {
          next.model = b.model_path.split("/").pop();
        }
      }

      if (slots !== null) {
        if (slots.status === 200 && Array.isArray(slots.body)) {
          next.slotsAvailable = true;
          const arr = slots.body as Record<string, unknown>[];
          next.slotsBusy = arr.filter(
            (s) => s.is_processing === true || s.state === 1,
          ).length;
          if (next.totalSlots === undefined) next.totalSlots = arr.length;
        } else if (next.up) {
          next.slotsAvailable = false; // 404/501 — server up but flag missing
        }
      }

      if (metrics !== null) {
        if (metrics.status === 200) {
          next.metricsAvailable = true;
          const tokens = promValue(metrics.body, "tokens_predicted_total");
          const seconds = promValue(metrics.body, "tokens_predicted_seconds_total");
          if (tokens !== null && seconds !== null) {
            const now = Date.now();
            const prev = prevMetrics.current;
            // Instantaneous rate from the counter delta between polls;
            // fall back to lifetime average when idle since last poll.
            if (prev && tokens > prev.tokens && seconds > prev.seconds) {
              next.tokPerSec = (tokens - prev.tokens) / (seconds - prev.seconds);
              next.tokSrc = "metrics";
            } else if (seconds > 0) {
              next.tokPerSec = tokens / seconds;
              next.tokSrc = "metrics-avg";
            }
            prevMetrics.current = { tokens, seconds, atMs: now };
          }
        } else if (next.up) {
          next.metricsAvailable = false;
        }
      }

      setStatus(next);
    },
    intervalMs,
    [base],
  );

  return status;
}
