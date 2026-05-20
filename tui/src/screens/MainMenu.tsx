import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Select from "../widgets/Select.js";
import { Layout } from "../widgets/Layout.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";

export type MainAction =
  | "wallets"
  | "le-chat"
  | "create-wallet"
  | "sphincs-accounts"
  | "private"
  | "status"
  | "toggle-colibri"
  | "unlock"
  | "more"
  | "quit";

type Props = {
  onPick: (a: MainAction) => void;
  colibriEnabled: boolean;
  colibriPending?: boolean;
  /** Bumped by App whenever master-lock state may have changed (e.g. after
   *  the unlock gate closes) so MainMenu re-fetches `wallet.master.status`
   *  and the locked badge disappears. */
  masterStatusKey: number;
};

/** Top-level entry. Labels are intentionally short — the verbose
 *  "(balance / mnemonic / unshield)"-type subtitles moved to the
 *  destination screens. The koi-red rectangle is the canonical leanKohaku
 *  framing; every hub-style screen reuses it. */
export default function MainMenu({
  onPick,
  colibriEnabled,
  colibriPending,
  masterStatusKey,
}: Props) {
  // null = unknown (probe in flight or failed); true/false = answered.
  // We deliberately do not block the menu on this probe — MainMenu must
  // stay usable even if the daemon hiccups, and the badge just stays
  // hidden in that case.
  const [masterUnlocked, setMasterUnlocked] = useState<boolean | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const r = await call<{ initialized: boolean; masterUnlocked: boolean }>(
        "wallet.master.status",
      );
      if (cancelled) return;
      if (!r.ok) {
        setMasterUnlocked(null);
        return;
      }
      setMasterUnlocked(r.result!.initialized ? r.result!.masterUnlocked : null);
    })();
    return () => {
      cancelled = true;
    };
  }, [masterStatusKey]);

  const locked = masterUnlocked === false;

  useInput((input) => {
    if (input === "q") onPick("quit");
    if (locked && (input === "u" || input === "U")) onPick("unlock");
  });

  const items: { label: string; value: MainAction }[] = [
    { label: "Wallets",                                                  value: "wallets" },
    { label: "le chat (local-LLM, experimental)",                        value: "le-chat" },
    { label: "Privacy Plugins",                                          value: "private" },
    { label: "Create wallet / Add account / Import",                     value: "create-wallet" },
    { label: "SPHINCS- hybrid accounts (post-quantum)",                  value: "sphincs-accounts" },
    { label: "Status (daemon · sidecars · sandbox · network)",           value: "status" },
    {
      label: `Colibri RPC verification: ${
        colibriPending ? "…" : colibriEnabled ? "ON  ✓" : "off"
      }`,
      value: "toggle-colibri",
    },
    { label: "More commands",                                            value: "more" },
    { label: "Quit",                                                     value: "quit" },
  ];

  const hint = locked
    ? "↑/↓ move · → / enter select · u unlock master · q quit"
    : "↑/↓ move · → / enter select · q quit";

  return (
    <Layout
      title="leanKohaku — interactive wallet"
      subtitle="formally-verified Ethereum wallet · daemon: leankohaku-daemon"
      hint={hint}
    >
      <Text color={theme.koiCream} backgroundColor={theme.koiInk} bold>
        {" leanKohaku · interactive wallet "}
      </Text>
      {locked && (
        <Box marginTop={1}>
          <Text color={theme.warn}>
            ⚠ master locked — per-slot unlock still works · press U to unlock
          </Text>
        </Box>
      )}
      <Box marginTop={1}>
        <Select
          items={items}
          onSelect={(it) => onPick(it.value)}
          arrowNav
        />
      </Box>
    </Layout>
  );
}
