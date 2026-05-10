import React from "react";
import { Box, Text, useInput } from "ink";
import { theme } from "../theme.js";

export type Tab<V> = {
  label: string;
  value: V;
  /** When true, render the tab dimmed (still navigable for context but
   *  visually marked as not yet usable). Currently unused — provided so
   *  callers can flag tabs like "RAILGUN" later. */
  disabled?: boolean;
};

type Props<V> = {
  tabs: Tab<V>[];
  activeIndex: number;
  onChange: (index: number) => void;
  /** When false, the strip ignores ←/→ — useful when a parent screen
   *  needs to hand the keys to a different consumer for one render. */
  isActive?: boolean;
};

/** Horizontal action selector used at the top of the Wallets hub. ←/→
 *  cycle through tabs (wrapping at both ends); ↑/↓/Enter are left for
 *  whatever picker the parent renders below the strip. The active tab
 *  gets the koi-ink chip + light-blue label so it stands out even on
 *  light terminal backgrounds. */
export default function TabStrip<V>({
  tabs,
  activeIndex,
  onChange,
  isActive = true,
}: Props<V>) {
  useInput(
    (_, key) => {
      if (!isActive) return;
      if (key.leftArrow) {
        onChange((activeIndex - 1 + tabs.length) % tabs.length);
      } else if (key.rightArrow) {
        onChange((activeIndex + 1) % tabs.length);
      }
    },
    { isActive },
  );
  return (
    <Box flexDirection="row" marginBottom={1}>
      {tabs.map((t, i) => {
        const active = i === activeIndex;
        if (active) {
          return (
            <Text key={i}>
              <Text color={theme.koiRed} bold>
                {"▌"}
              </Text>
              <Text
                color={theme.highlight}
                backgroundColor={theme.koiInk}
                bold
              >
                {` ${t.label} `}
              </Text>
              <Text color={theme.koiRed} bold>
                {"▐"}
              </Text>
              <Text> </Text>
            </Text>
          );
        }
        return (
          <Text key={i} color={t.disabled ? theme.dim : theme.muted}>
            {`  ${t.label}   `}
          </Text>
        );
      })}
    </Box>
  );
}
