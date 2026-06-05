import React from "react";
import { Text, useInput } from "ink";
import Select from "../widgets/Select.js";
import { Layout } from "../widgets/Layout.js";
import { theme } from "../theme.js";

export type CreateKind =
  | "eoa"
  | "sphincs-hybrid"
  | "add-account"
  | "import-bip39"
  | "back";

type Props = {
  onPick: (k: CreateKind) => void;
};

/** Entry picker for "Create wallet / Add account / Import" — three
 *  separate-but-related ways to land a new wallet slot in the daemon.
 *  Import lived under its own main-menu item; folded in here so the
 *  user thinks "I want a new wallet" once, not "is this a create or an
 *  import." Routes through `onPick(...)`; the App stack handles the
 *  rest (CreateEoaFlow / AddAccountFlow / ImportEoaFlow). */
export default function CreateWalletPicker({ onPick }: Props) {
  useInput((input, key) => {
    if (key.escape || input === "q") onPick("back");
  });

  const items: { label: string; value: CreateKind | "soon" }[] = [
    { label: "Create EOA — fresh BIP-39 mnemonic, passphrase-encrypted",  value: "eoa" },
    { label: "Create SPHINCS- hybrid — ECDSA + post-quantum ERC-4337",    value: "sphincs-hybrid" },
    { label: "Add account — new hardened branch on an existing EOA",      value: "add-account" },
    { label: "Import BIP-39 mnemonic (12 or 24 words)",                   value: "import-bip39" },
    { label: "Import raw private key — not yet supported",                value: "soon" },
    { label: "Import raw seed (hex)   — not yet supported",               value: "soon" },
    { label: "← Back",                                                    value: "back" },
  ];

  return (
    <Layout
      title="Create wallet / Add account / Import"
      subtitle="Choose how the new slot is sourced."
      hint="↑/↓ move · → / enter select · ← / esc back"
    >
      <Select
        items={items}
        arrowNav
        onBack={() => onPick("back")}
        onSelect={(it) => {
          if (it.value === "soon") return; // disabled — daemon doesn't expose these yet
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
