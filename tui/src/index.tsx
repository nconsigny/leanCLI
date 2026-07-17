import React from "react";
import { render } from "ink";
import App from "./App.js";

if (!process.stdout.isTTY) {
  // eslint-disable-next-line no-console
  console.error(
    "leancli-tui: stdout is not a TTY. The interactive UI requires a real terminal — use `leancli` for non-interactive commands.",
  );
  process.exit(2);
}

// Enter the alternate screen buffer so Ink owns the whole viewport. Without
// this, tall screens (e.g. SPHINCS detail) scroll the terminal — and on the
// next transition Ink moves cursor up by the old render's row count, but
// the cursor can't climb above the visible viewport, so the rows that
// scrolled away never get overwritten and leak through as a "ghost" koi /
// header above the new screen. The alt buffer is what vim/less use; on
// exit we restore the user's prior terminal contents.
const ALT_ENTER = "\x1B[?1049h\x1B[H";
const ALT_LEAVE = "\x1B[?1049l";
process.stdout.write(ALT_ENTER);

// Synchronized output (DEC private mode 2026). Ink repaints a frame as
// erase-previous-lines + rewrite, and on a full-viewport dashboard the
// terminal is free to paint mid-rewrite — the bottom rows sit blank the
// longest, which reads as flicker in the lower half of the screen.
// Bracketing every write in BSU/ESU tells the terminal to composite the
// whole update atomically. Terminals without 2026 support (it's a
// private mode) ignore the sequences, so this is safe to emit
// unconditionally. Ink only sees the proxied stream via its `stdout`
// option; our own ALT_ENTER/ALT_LEAVE writes above bypass it on purpose.
const BSU = "\x1B[?2026h";
const ESU = "\x1B[?2026l";
const syncStdout = new Proxy(process.stdout, {
  get(target, prop) {
    if (prop === "write") {
      return (
        chunk: string | Uint8Array,
        ...rest: unknown[]
      ): boolean =>
        typeof chunk === "string"
          ? (target.write as (...a: unknown[]) => boolean)(BSU + chunk + ESU, ...rest)
          : (target.write as (...a: unknown[]) => boolean)(chunk, ...rest);
    }
    // Read with the real stream as receiver so internal-slot getters
    // (columns/rows) don't observe the proxy as `this`.
    const value = Reflect.get(target, prop, target);
    // EventEmitter methods (on/off/…) and write-adjacent helpers must run
    // with the real stream as `this`.
    return typeof value === "function" ? value.bind(target) : value;
  },
});

const restore = () => {
  try { process.stdout.write(ALT_LEAVE); } catch {}
};
// Cover the three exit paths: normal exit, Ctrl-C / kill, and uncaught
// crashes. Without all three you can land back in a terminal stuck inside
// the alt buffer (cursor visible, but prompt is gone).
process.on("exit", restore);
process.on("SIGINT", () => { restore(); process.exit(130); });
process.on("SIGTERM", () => { restore(); process.exit(143); });
process.on("uncaughtException", (e) => {
  restore();
  // eslint-disable-next-line no-console
  console.error(e);
  process.exit(1);
});

render(<App />, { stdout: syncStdout });
