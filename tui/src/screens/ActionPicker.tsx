import React from "react";
import { Box, Text, useInput } from "ink";
import Select from "../widgets/Select.js";
import { theme } from "../theme.js";
import { Wallet } from "../types.js";
import { formatEth, shortAddr } from "../format.js";
import { archiveKey, readArchive } from "../archiveStore.js";

export type Action =
  | "send"
  | "swap"
  | "shield"
  | "unshield"
  | "history"
  | "details"
  | "balance-refresh"
  | "lock-toggle"
  | "reveal-mnemonic"
  | "add-account"
  | "archive"
  | "unstick"
  | "back";

type Props = {
  wallet: Wallet;
  onPick: (action: Action) => void;
  onBack: () => void;
};

export default function ActionPicker({ wallet, onPick, onBack }: Props) {
  useInput((input, key) => {
    if (key.escape || input === "q") onBack();
  });

  const items: { label: string; value: Action }[] = [
    { label: "Send ETH",                       value: "send" },
    ...(wallet.kind === "eoa"
      ? [{ label: "Swap (Uniswap V3)",          value: "swap" as Action }]
      : []),
    ...(wallet.kind === "eoa"
      ? [
          { label: "Shield (Privacy Pools or Railgun deposit)", value: "shield" as Action },
          { label: "Unshield (withdraw to derived / book / paste)", value: "unshield" as Action },
        ]
      : []),
    ...(wallet.kind === "eoa"
      ? [
          {
            label: wallet.unlocked
              ? "Lock wallet"
              : "Unlock wallet (passphrase)",
            value: "lock-toggle" as Action,
          },
        ]
      : []),
    { label: "View on-chain history",          value: "history" },
    { label: "Show wallet details",            value: "details" },
    { label: "Refresh balance",                value: "balance-refresh" },
    ...(wallet.kind === "eoa"
      ? [
          { label: "Add account (BIP-32 hardened branch)", value: "add-account" as Action },
          { label: "Reveal mnemonic (DANGER)",              value: "reveal-mnemonic" as Action },
        ]
      : []),
    {
      label: readArchive().has(
        archiveKey(wallet.kind, wallet.name, wallet.accountIndex),
      )
        ? "Unarchive (show again in wallet list)"
        : "Archive (hide from wallet list)",
      value: "archive",
    },
    { label: "← Back to wallet list",          value: "back" },
  ];

  return (
    <Box flexDirection="column" paddingX={1}>
      <Text color={theme.primary} bold>
        {wallet.name}{" "}
        <Text color={wallet.kind === "eoa" ? theme.primary : theme.ok}>
          [{wallet.kind}]
        </Text>
        {wallet.kind === "eoa" && wallet.unlocked === false && (
          <Text color={theme.warn}> [locked]</Text>
        )}
      </Text>
      <Text color={theme.dim}>
        {shortAddr(wallet.address)} ·{" "}
        {wallet.balanceWei !== undefined ? formatEth(wallet.balanceWei) : "…"}
      </Text>
      <Box marginTop={1}>
        <Select
          items={items}
          arrowNav
          onBack={onBack}
          onSelect={(it) => {
            if (it.value === "back") onBack();
            else onPick(it.value);
          }}
        />
      </Box>
      <Box marginTop={1}>
        <Text color={theme.dim}>↑/↓ move · → / enter select · ← / esc back</Text>
      </Box>
    </Box>
  );
}
