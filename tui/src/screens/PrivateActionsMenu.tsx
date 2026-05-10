import React from "react";
import { Box, Text, useInput } from "ink";
import { Layout } from "../widgets/Layout.js";
import Select from "../widgets/Select.js";
import { theme } from "../theme.js";

export type PrivateActionPick = "privacy-pools" | "railgun" | "back";

type Props = {
  onPick: (a: PrivateActionPick) => void;
};

/** "Private actions" hub — shielded transfer systems live here. Today
 *  Privacy Pools is the only wired-up backend; the Railgun row is dim
 *  and a no-op so the roadmap is visible without dropping into a
 *  half-implemented flow (the dim hint rides on the leading `\x01` byte
 *  that `Select`'s itemComponent strips before rendering). */
export default function PrivateActionsMenu({ onPick }: Props) {
  useInput((input, key) => {
    if (key.escape || input === "q") onPick("back");
  });

  const items = [
    {
      label: "Privacy Pools — balance · shield · unshield · mnemonic",
      value: "privacy-pools" as PrivateActionPick,
    },
    {
      label: "\x01Railgun — coming soon (not yet supported)",
      value: "railgun" as PrivateActionPick,
    },
    { label: "← Back", value: "back" as PrivateActionPick },
  ];

  return (
    <Layout
      title="Privacy Plugins"
      subtitle="shielded transfer backends — pick a plugin"
      hint="↑/↓ move · → / enter select · ← / esc back"
    >
      <Box
        flexDirection="column"
        borderStyle="double"
        borderColor={theme.koiRed}
        paddingX={2}
        paddingY={0}
      >
        <Text color={theme.koiCream} backgroundColor={theme.koiInk} bold>
          {" leanKohaku · privacy plugins "}
        </Text>
        <Box marginTop={1}>
          <Select
            items={items}
            arrowNav
            onBack={() => onPick("back")}
            onSelect={(it) => {
              if (it.value === "railgun") return; // dim row — no-op on enter
              onPick(it.value);
            }}
          />
        </Box>
        <Box marginTop={1}>
          <Text color={theme.dim}>
            Railgun integration is on the roadmap — the row will light up
            the moment the daemon-side bridge ships.
          </Text>
        </Box>
      </Box>
    </Layout>
  );
}
