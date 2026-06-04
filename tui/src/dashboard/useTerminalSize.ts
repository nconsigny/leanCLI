import { useEffect, useState } from "react";
import { useStdout } from "ink";

/** Terminal dimensions with live resize tracking. Extends the
 *  `useTerminalColumns` pattern from NetworkMonitor.tsx with `rows` —
 *  the dashboard is the first screen that must budget HEIGHT, because
 *  the TUI runs in the alternate screen buffer (index.tsx) where
 *  anything taller than the viewport is silently lost. */
export function useTerminalSize(): { columns: number; rows: number } {
  const { stdout } = useStdout();
  const [size, setSize] = useState<{ columns: number; rows: number }>({
    columns: stdout?.columns ?? 100,
    rows: stdout?.rows ?? 30,
  });
  useEffect(() => {
    if (!stdout) return;
    const onResize = () =>
      setSize({ columns: stdout.columns ?? 100, rows: stdout.rows ?? 30 });
    stdout.on("resize", onResize);
    return () => {
      stdout.off("resize", onResize);
    };
  }, [stdout]);
  return size;
}
