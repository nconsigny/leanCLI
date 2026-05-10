/**
 * Semantic color palette. Components must reference these tokens, never
 * raw hex/named colors. Honors `NO_COLOR` and non-TTY stdout.
 */

const colorEnabled =
  !process.env.NO_COLOR &&
  process.stdout.isTTY === true;

export const theme = {
  primary: "cyan",
  accent: "magenta",
  ok: "green",
  warn: "yellow",
  err: "red",
  // Menu-cursor highlight. Light blue stays legible on both the default
  // dark terminal and the Ubuntu purple background where bright cyan or
  // magenta tend to wash out.
  highlight: "#7ec8ff",
  // Was "gray" (bright black) — illegible on the Ubuntu purple terminal.
  // Light hex stays readable on dark backgrounds without being shouty on light ones.
  dim: "#bdbdbd",
  muted: "white",
  // Logo palette — used by the koi banner.
  koiRed: "#c8102e",
  koiCream: "#f5ecd6",
  koiInk: "#15304a",
} as const;

export const enabled = colorEnabled;
