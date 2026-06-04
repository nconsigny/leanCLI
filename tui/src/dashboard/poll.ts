import { useEffect } from "react";

/** Interval-driven async poller with an in-flight guard so a slow tick
 *  never overlaps the next one (a 5s RPC on a 2s interval would otherwise
 *  pile up concurrent calls against the daemon). The first tick fires
 *  immediately on mount / dep change. `fn` receives an `isCancelled`
 *  probe so it can bail out of multi-step sequences after unmount. */
export function usePoll(
  fn: (isCancelled: () => boolean) => Promise<void>,
  intervalMs: number,
  deps: unknown[],
): void {
  useEffect(() => {
    let cancelled = false;
    let busy = false;
    const isCancelled = () => cancelled;
    const tick = () => {
      if (busy || cancelled) return;
      busy = true;
      void fn(isCancelled)
        .catch(() => {
          // Pollers are display-only; a failed tick renders as stale data
          // and the next tick retries. Never crash the dashboard.
        })
        .finally(() => {
          busy = false;
        });
    };
    tick();
    const t = setInterval(tick, intervalMs);
    return () => {
      cancelled = true;
      clearInterval(t);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [intervalMs, ...deps]);
}
