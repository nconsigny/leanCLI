import React from "react";
import { useInput } from "ink";
import Select from "../widgets/Select.js";
import { Layout } from "../widgets/Layout.js";

export type CreateKind = "eoa" | "r1" | "add-account" | "back";

type Props = {
  onPick: (k: CreateKind) => void;
};

/** Step 1 of the create-wallet flow: pick the slot type. The actual key
 *  generation lives in CreateEoaFlow / CreateR1Flow. */
export default function CreateWalletPicker({ onPick }: Props) {
  useInput((input, key) => {
    if (key.escape || input === "q") onPick("back");
  });

  const items: { label: string; value: CreateKind }[] = [
    { label: "EOA — BIP-39 mnemonic, passphrase-encrypted at rest",   value: "eoa" },
    { label: "TPM/R1 — hardware-backed P-256 key, biometric prompts", value: "r1" },
    { label: "Add account — new BIP-32 hardened branch on existing EOA", value: "add-account" },
    { label: "← Back",                                                value: "back" },
  ];

  return (
    <Layout
      title="Create wallet / Add account"
      subtitle="Choose: a new EOA slot, a new TPM/R1 slot, or a fresh hardened sub-account on an existing EOA."
      hint="↑/↓ move · → / enter select · ← / esc back"
    >
      <Select
        items={items}
        arrowNav
        onBack={() => onPick("back")}
        onSelect={(it) => onPick(it.value)}
      />
    </Layout>
  );
}
