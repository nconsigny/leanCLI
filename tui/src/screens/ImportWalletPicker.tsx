import React from "react";
import { Text, useInput } from "ink";
import Select from "../widgets/Select.js";
import { Layout } from "../widgets/Layout.js";
import { theme } from "../theme.js";

export type ImportKind = "bip39" | "back";

type Props = {
  onPick: (k: ImportKind) => void;
};

/** Step 1 of the import flow: pick the source format. Only BIP-39 is wired
 *  through to the daemon today (`eoa.import`); raw private-key / seed
 *  imports aren't supported yet — listed but disabled so the structure is
 *  ready when the daemon grows those endpoints. */
export default function ImportWalletPicker({ onPick }: Props) {
  useInput((input, key) => {
    if (key.escape || input === "q") onPick("back");
  });

  const items: { label: string; value: ImportKind | "soon" }[] = [
    { label: "BIP-39 mnemonic (12 or 24 words)",         value: "bip39" },
    { label: "Raw private key (hex) — not yet supported", value: "soon" },
    { label: "Raw seed (hex)         — not yet supported", value: "soon" },
    { label: "← Back",                                    value: "back" },
  ];

  return (
    <Layout
      title="Import wallet"
      subtitle="Choose the source format."
      hint="↑/↓ move · → / enter select · ← / esc back"
    >
      <Select
        items={items}
        arrowNav
        onBack={() => onPick("back")}
        onSelect={(it) => {
          if (it.value === "soon") return; // ignore — disabled item
          onPick(it.value);
        }}
      />
      <Text color={theme.dim}>
        Private-key and raw-seed import will land when the daemon exposes
        them; today only `eoa.import` (BIP-39) is wired up.
      </Text>
    </Layout>
  );
}
