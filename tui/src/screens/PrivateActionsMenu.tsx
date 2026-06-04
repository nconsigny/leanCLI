import React from "react";
import { Box, Text, useInput } from "ink";
import { Layout } from "../widgets/Layout.js";
import Select from "../widgets/Select.js";
import { theme } from "../theme.js";

export type PrivateActionPick = "privacy-pools" | "railgun" | "back";

type Props = {
  onPick: (a: PrivateActionPick) => void;
};

/** "Private actions" hub — shielded transfer systems. Both backends are
 *  live: Privacy Pools v1 (0xBow) and Railgun. Shield deposits start
 *  from a wallet's "shield" action (which picks the protocol there);
 *  this hub is for post-deposit operations (balance, unshield, etc.). */
export default function PrivateActionsMenu({ onPick }: Props) {
  useInput((input, key) => {
    if (key.escape || input === "q") onPick("back");
  });

  const items = [
    {
      label: "Privacy Pools — balance · unshield · mnemonic",
      value: "privacy-pools" as PrivateActionPick,
    },
    {
      label: "Railgun — balance",
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
          {" leanCLI · privacy plugins "}
        </Text>
        <Box marginTop={1}>
          <Select
            items={items}
            arrowNav
            onBack={() => onPick("back")}
            onSelect={(it) => onPick(it.value)}
          />
        </Box>
        <Box marginTop={1}>
          <Text color={theme.dim}>
            To shield ETH into a pool, use the "shield" action from a
            wallet — protocol is picked there.
          </Text>
        </Box>
      </Box>
    </Layout>
  );
}
