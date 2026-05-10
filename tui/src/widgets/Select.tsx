import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import SelectInput from "ink-select-input";
import { theme } from "../theme.js";

export type SelectItem<V> = {
  label: string;
  value: V;
  key?: string;
  /** When true, render the row in `theme.dim` (unselected only). Used
   *  to visually mute swap-from tokens with zero balance while keeping
   *  them selectable (the user may pick one to receive). */
  dim?: boolean;
};

/** Styled cursor used by both the wrapper below and any direct
 *  `SelectInput` callsites in wizard flows. Light blue is readable on
 *  every terminal background we ship against. */
export function SelectIndicator({ isSelected }: { isSelected?: boolean }) {
  return (
    <Box marginRight={1}>
      <Text color={isSelected ? theme.highlight : undefined}>
        {isSelected ? "▶" : " "}
      </Text>
    </Box>
  );
}

export function SelectItemRenderer({
  isSelected,
  label,
}: {
  isSelected?: boolean;
  label: string;
}) {
  // The `ink-select-input` itemComponent contract only forwards `label`,
  // so we encode the dim hint as a leading marker `` on the label
  // and strip it here. This keeps the widget API JSON-friendly without
  // a second prop channel. (Lower-end terminals just see the plain label
  // if they ignore the marker — but  is a control char so it's
  // never visible.)
  let text = label;
  let dim = false;
  if (label.startsWith("")) {
    text = label.slice(1);
    dim = true;
  }
  // `wrap="truncate-end"` keeps every row on a single terminal line —
  // long labels (full Ethereum addresses, wallet rows on a half-screen
  // tmux pane) clip with `…` instead of breaking onto a second row,
  // which would make the highlight bar look like it "jumps" by 1 line.
  return (
    <Text
      color={isSelected ? theme.highlight : dim ? theme.dim : undefined}
      bold={isSelected}
      wrap="truncate-end"
    >
      {text}
    </Text>
  );
}

type Props<V> = {
  items: SelectItem<V>[];
  onSelect: (item: SelectItem<V>) => void;
  onHighlight?: (item: SelectItem<V>) => void;
  initialIndex?: number;
  limit?: number;
  isFocused?: boolean;
  /** When true, ← invokes `onBack` (if set) and → confirms the currently
   *  highlighted item. Leave false in wizard flows that already consume
   *  ←/→ for phase navigation to avoid double-firing. */
  arrowNav?: boolean;
  onBack?: () => void;
};

/** Themed `ink-select-input` wrapper. Adds the light-blue highlight
 *  styling everywhere and an opt-in ←/→ shortcut for menu screens. */
export default function Select<V>({
  items,
  onSelect,
  onHighlight,
  initialIndex,
  limit,
  isFocused,
  arrowNav = false,
  onBack,
}: Props<V>) {
  const [highlighted, setHighlighted] = useState<SelectItem<V> | undefined>(
    items[initialIndex ?? 0],
  );

  useEffect(() => {
    if (!highlighted && items.length > 0) {
      setHighlighted(items[0]);
      return;
    }
    if (highlighted && !items.find((it) => it.value === highlighted.value)) {
      setHighlighted(items[0]);
    }
  }, [items, highlighted]);

  useInput(
    (_, key) => {
      if (!arrowNav) return;
      if (key.leftArrow) {
        if (onBack) onBack();
        return;
      }
      if (key.rightArrow && highlighted) {
        onSelect(highlighted);
      }
    },
    { isActive: isFocused !== false },
  );

  return (
    <SelectInput
      items={items}
      onSelect={onSelect}
      onHighlight={(it: SelectItem<V>) => {
        setHighlighted(it);
        onHighlight?.(it);
      }}
      initialIndex={initialIndex}
      limit={limit}
      isFocused={isFocused}
      indicatorComponent={SelectIndicator}
      itemComponent={SelectItemRenderer}
    />
  );
}
