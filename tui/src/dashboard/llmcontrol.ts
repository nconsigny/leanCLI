import { useEffect, useState } from "react";
import { call } from "../daemon.js";

/**
 * Predefined llama.cpp launch profiles for the dashboard's "llama.cpp /
 * resources" pane. The wallet daemon exposes two RPCs:
 *
 *   llm.models  → { models: [{ name, description? }] }   (read-only)
 *   llm.launch  → { outcome, model }                     (stop + respawn)
 *
 * `llm.launch` is kill-then-launch: llama-server binds a single port, so
 * the daemon stops the running server before spawning the chosen profile
 * (LeanCli/Daemon/LlmServer.lean). This is read/chat-backend plumbing
 * only — it never feeds a signing decision.
 *
 * The profile list itself lives in the operator's LLM_MODELS_CONFIG JSON
 * file (hardware-sensitive args: MoE CPU-offload, -ngl, spec-decode),
 * NOT in the TUI — we only ever see the name + description here.
 */

export type LlmModel = { name: string; description?: string };

export type LlmControl = {
  models: LlmModel[];
  /** resolved profiles-file path the daemon read (LLM_MODELS_CONFIG or
   *  the ~/.config/leancli/models.json default); null until loaded. */
  configPath: string | null;
  /** false until the first llm.models call returns. */
  loaded: boolean;
  /** name currently being launched, or null. */
  pending: string | null;
  /** last launch outcome string (for surfacing in the picker), or null. */
  result: string | null;
  reload: () => void;
  launch: (name: string) => Promise<void>;
};

export function useLlmModels(): LlmControl {
  const [models, setModels] = useState<LlmModel[]>([]);
  const [configPath, setConfigPath] = useState<string | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [pending, setPending] = useState<string | null>(null);
  const [result, setResult] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const r = await call<{ models: LlmModel[]; configPath?: string }>("llm.models", {});
      if (cancelled) return;
      if (r.ok) {
        setModels(r.result.models ?? []);
        setConfigPath(r.result.configPath ?? null);
      }
      setLoaded(true);
    })();
    return () => {
      cancelled = true;
    };
  }, [refreshKey]);

  const reload = () => setRefreshKey((k) => k + 1);

  const launch = async (name: string) => {
    if (pending) return;
    setPending(name);
    setResult(null);
    // The daemon blocks only briefly (stop ~2s + a short health peek);
    // a full MoE / -hf-download load finishes in the background and the
    // pane's read-only poll surfaces loading → up. 30s covers the RPC.
    const r = await call<{ outcome: string; model?: string }>(
      "llm.launch",
      { name },
      { timeoutMs: 30_000 },
    );
    setPending(null);
    if (r.ok) setResult(`${r.result.model ?? name}: ${r.result.outcome}`);
    else setResult(`launch failed: ${r.error.message}`);
  };

  return { models, configPath, loaded, pending, result, reload, launch };
}
