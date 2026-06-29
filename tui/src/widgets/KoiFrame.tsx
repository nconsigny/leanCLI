import React, { useContext } from "react";
import { Box } from "ink";
import AnimatedKoi from "./AnimatedKoi.js";
import { theme } from "../theme.js";
import { EmbeddedContext } from "../embedded.js";

/** [koi | red-bordered box] — the canonical "you are inside the wallet"
 *  framing. Used by Layout (default) and RpcRunner so every interactive
 *  flow + the broadcast screen keep the koi visible as wallet identity.
 *  Screens that need a different inner layout (e.g. LlmChatFlow's chat
 *  body below a header) consume KoiFrame directly. */
// Intrinsic dimensions of the "tiny" KohakuKoi grid (24 cols × 12 rows).
// Pinned on the wrapper so Ink reserves that space even when the right
// panel is wider than the terminal — without these, the koi's text lines
// get reflowed and the fish renders in pieces. flexShrink=0 prevents the
// row layout from squeezing the koi when content grows.
const KOI_W = 24;
const KOI_H = 12;

export function KoiFrame({ children }: { children: React.ReactNode }) {
  const embedded = useContext(EmbeddedContext);
  // In the dashboard's narrow main pane the 24-col koi would force the
  // content to wrap or spill, so drop it and keep just the red-bordered
  // box (still the "inside the wallet" identity cue, minus the fish).
  // Tighter horizontal padding too — every column counts in-pane.
  const content = (
    <Box
      flexDirection="column"
      borderStyle="double"
      borderColor={theme.koiRed}
      paddingX={embedded ? 1 : 2}
      paddingY={0}
      flexGrow={1}
      flexShrink={1}
      minWidth={0}
    >
      {children}
    </Box>
  );
  if (embedded) return content;
  return (
    <Box flexDirection="row">
      <Box
        marginRight={2}
        width={KOI_W}
        minWidth={KOI_W}
        height={KOI_H}
        flexShrink={0}
      >
        <AnimatedKoi size="tiny" />
      </Box>
      {content}
    </Box>
  );
}
