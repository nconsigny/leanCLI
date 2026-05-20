import React from "react";
import { Box, Text } from "ink";
import { theme } from "../theme.js";
import { KoiFrame } from "./KoiFrame.js";

/** Standard frame: title bar, optional subtitle, koi-framed content,
 *  footer hint row. The koi-frame is the "you are inside the wallet"
 *  identity cue and is on by default; pass `koi={false}` only for
 *  screens that paint their own frame (e.g. LlmChatFlow's Container). */
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
