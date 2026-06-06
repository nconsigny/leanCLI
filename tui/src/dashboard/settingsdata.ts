import { useEffect, useState } from "react";
import { call } from "../daemon.js";

/**
 * Settings-pane data: the privacy-plugin allow-list + active provider.
 *
 * Sourced from the daemon's `daemon.privacy.status` RPC, which reads
 * `LEANCLI_PRIVACY` / `LEANCLI_PROVIDER` from its environment (set at
 * boot). There is NO runtime toggle for privacy plugins — the settings
 * pane displays them read-only with an "edit daemon.env & restart" note.
 * The read/simulate backend + light-client toggles DO change live and are
 * handled by `useRpcConfig` (rpcstatus.ts), not here.
 */

export type PrivacyStatus = {
  /** Enabled privacy plugins (subset of railgun / privacy-pools / tornado). */
  enabledPrivacy: string[];
  /** Active provider (LEANCLI_PROVIDER): helios / colibri / rpc / safenode. */
  provider: string | null;
  /** false until the first call returns. */
  loaded: boolean;
};

const INITIAL: PrivacyStatus = { enabledPrivacy: [], provider: null, loaded: false };

export function usePrivacyStatus(intervalMs = 10_000): PrivacyStatus {
  const [status, setStatus] = useState<PrivacyStatus>(INITIAL);

  useEffect(() => {
    let cancelled = false;
    const tick = async () => {
      const r = await call<{ enabledPrivacy?: string[]; provider?: string }>(
        "daemon.privacy.status",
        {},
      );
      if (cancelled) return;
      if (r.ok) {
        setStatus({
          enabledPrivacy: r.result.enabledPrivacy ?? [],
          provider: r.result.provider ?? null,
          loaded: true,
        });
      } else {
        setStatus((s) => ({ ...s, loaded: true }));
      }
    };
    void tick();
    const h = setInterval(() => void tick(), intervalMs);
    return () => {
      cancelled = true;
      clearInterval(h);
    };
  }, [intervalMs]);

  return status;
}
