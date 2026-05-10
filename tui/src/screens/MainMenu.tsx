import React from "react";
import { Box, Text, useInput } from "ink";
import Select from "../widgets/Select.js";
import { Layout } from "../widgets/Layout.js";
import AnimatedKoi from "../widgets/AnimatedKoi.js";
import { theme } from "../theme.js";

export type MainAction =
  | "wallets"
  | "create-wallet"
  | "import-wallet"
  | "private"
  | "network"
  | "toggle-colibri"
  | "more"
  | "quit";

type Props = {
  onPick: (a: MainAction) => void;
  colibriEnabled: boolean;
  colibriPending?: boolean;
};

/** Top-level entry. Labels are intentionally short — the verbose
 *  "(balance / mnemonic / unshield)"-type subtitles moved to the
 *  destination screens. The koi-red rectangle is the canonical leanKohaku
 *  framing; every hub-style screen reuses it. */
export default function MainMenu({
  onPick,
  colibriEnabled,
  colibriPending,
}: Props) {
  useInput((input) => {
    if (input === "q") onPick("quit");
  });

  const items: { label: string; value: MainAction }[] = [
    { label: "Wallets",                                                  value: "wallets" },
    { label: "Privacy Plugins",                                          value: "private" },
    { label: "Create wallet / Add account",                              value: "create-wallet" },
    { label: "Import wallet",                                            value: "import-wallet" },
    { label: "Network",                                                  value: "network" },
    {
      label: `Colibri RPC verification: ${
        colibriPending ? "…" : colibriEnabled ? "ON  ✓" : "off"
      }`,
      value: "toggle-colibri",
    },
    { label: "More commands",                                            value: "more" },
    { label: "Quit",                                                     value: "quit" },
  ];

  return (
    <Layout
      title="leanKohaku — interactive wallet"
      subtitle="formally-verified Ethereum wallet · daemon: leankohaku-daemon"
      hint="↑/↓ move · → / enter select · q quit"
    >
      <Box flexDirection="row">
        <Box marginRight={2}>
          <AnimatedKoi size="tiny" />
        </Box>
        <Box
          flexDirection="column"
          justifyContent="center"
          borderStyle="double"
          borderColor={theme.koiRed}
          paddingX={2}
          paddingY={0}
        >
          <Text color={theme.koiCream} backgroundColor={theme.koiInk} bold>
            {" leanKohaku · interactive wallet "}
          </Text>
          <Box marginTop={1}>
            <Select
              items={items}
              onSelect={(it) => onPick(it.value)}
              arrowNav
            />
          </Box>
        </Box>
      </Box>
    </Layout>
  );
}
