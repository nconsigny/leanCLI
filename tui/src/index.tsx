import React from "react";
import { render } from "ink";
import App from "./App.js";

if (!process.stdout.isTTY) {
  // eslint-disable-next-line no-console
  console.error(
    "leankohaku-tui: stdout is not a TTY. The interactive UI requires a real terminal — use `kohaku` for non-interactive commands.",
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

render(<App />);
