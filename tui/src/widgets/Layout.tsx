import React from "react";
import { Box, Text } from "ink";
import { theme } from "../theme.js";
import { KoiFrame } from "./KoiFrame.js";
import { useNav } from "../nav.js";

/** Standard frame: title bar, optional subtitle, koi-framed content,
 *  footer hint row. The koi-frame is the "you are inside the wallet"
 *  identity cue and is on by default; pass `koi={false}` only for
 *  screens that paint their own frame (e.g. LlmChatFlow's Container).
 *
 *  Renders a top NavBar reading the history-nav context from App.tsx —
 *  Back / Forward affordances visible on every screen without each one
 *  having to opt in. NavBar dims itself when the screen is at the root
 *  of the stack or has nothing to forward to, so the chrome accurately
 *  reflects reachability instead of advertising buttons that do
 *  nothing. */
export function Layout(props: {
  title: string;
  subtitle?: string;
  hint?: string;
  koi?: boolean;
  children: React.ReactNode;
}) {
  const koi = props.koi ?? true;
  return (
    <Box flexDirection="column" paddingX={1}>
      <NavBar />
      <Text color={theme.primary} bold>
        {props.title}
      </Text>
      {props.subtitle && <Text color={theme.dim}>{props.subtitle}</Text>}
      <Box marginTop={1} flexDirection="column">
        {koi ? <KoiFrame>{props.children}</KoiFrame> : props.children}
      </Box>
      {props.hint && (
        <Box marginTop={1}>
          <Text color={theme.dim}>{props.hint}</Text>
        </Box>
      )}
    </Box>
  );
}

/** Two-button top strip showing browser-style Back / Forward. Reads
 *  availability from `NavContext` (App.tsx owns the stacks). The buttons
 *  are visual affordances; the actual nav fires from key chords
 *  registered at the App level (`←` / esc for back — already in every
 *  screen's `useInput`; `]` for forward — App-level listener). We don't
 *  intercept clicks here because Ink doesn't ship mouse-event support
 *  out of the box; the labels carry the chord so the affordance is
 *  honest. */
function NavBar() {
  const nav = useNav();
  const backColor = nav.canBack ? theme.primary : theme.dim;
  const fwdColor = nav.canForward ? theme.primary : theme.dim;
  return (
    <Box marginBottom={0}>
      <Text color={backColor}>
        [{nav.canBack ? "◀" : "·"} Back (Esc)]
      </Text>
      <Text color={theme.dim}>  ·  </Text>
      <Text color={fwdColor}>
        [Forward {nav.canForward ? "▶" : "·"} (])]
      </Text>
    </Box>
  );
}

/** Coloured one-line status: ok/warn/err. Used for inline result banners. */
export function Banner({
  kind,
  text,
}: {
  kind: "ok" | "warn" | "err" | "info";
  text: string;
}) {
  const color =
    kind === "ok"
      ? theme.ok
      : kind === "warn"
        ? theme.warn
        : kind === "err"
          ? theme.err
          : theme.primary;
  const glyph =
    kind === "ok" ? "✓" : kind === "warn" ? "⚠" : kind === "err" ? "✗" : "·";
  return (
    <Text color={color}>
      {glyph} {text}
    </Text>
  );
}
