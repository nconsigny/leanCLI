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
  | "private"
  | "status"
  | "toggle-colibri"
  | "cycle-read-backend"
  | "unlock"
  | "more"
  | "quit";

export type ReadBackend = "rpc" | "colibri" | "helios";

type Props = {
  onPick: (a: MainAction) => void;
  colibriEnabled: boolean;
  colibriPending?: boolean;
  /** Daemon-side default backend for `tx.simulate` (leancli-provider-style
   *  toggle). Cycles rpc → colibri → helios on the menu entry; helios needs
   *  `LEANCLI_HELIOS=1` to actually serve (otherwise it falls through to the
   *  one-shot sidecar spawn per call). */
  readBackend: ReadBackend;
  readBackendPending?: boolean;
  /** Bumped by App whenever master-lock state may have changed (e.g. after
   *  the unlock gate closes) so MainMenu re-fetches `wallet.master.status`
   *  and the locked badge disappears. */
  masterStatusKey: number;
};

/** Top-level entry. Labels are intentionally short — the verbose
 *  "(balance / mnemonic / unshield)"-type subtitles moved to the
 *  destination screens. The koi-red rectangle is the canonical leanCLI
 *  framing; every hub-style screen reuses it. */
export default function MainMenu({
  onPick,
  colibriEnabled,
  colibriPending,
  readBackend,
  readBackendPending,
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
    { label: "Status (daemon · sidecars · sandbox · network)",           value: "status" },
    {
      label: `Colibri RPC verification: ${
        colibriPending ? "…" : colibriEnabled ? "ON  ✓" : "off"
      }`,
      value: "toggle-colibri",
    },
    {
      label: `Read/simulate backend: ${
        readBackendPending ? "…" : `${readBackend}${readBackend === "helios" ? "  ✓" : readBackend === "colibri" ? "  ✓" : ""}`
      }   (cycle: rpc → colibri → helios)`,
      value: "cycle-read-backend",
    },
    { label: "More commands",                                            value: "more" },
    { label: "Quit",                                                     value: "quit" },
  ];

  const hint = locked
    ? "↑/↓ move · → / enter select · u unlock master · q quit"
    : "↑/↓ move · → / enter select · q quit";

  return (
    <Layout
      title="leanCLI — interactive wallet"
      subtitle="formally-verified Ethereum wallet · daemon: leancli-daemon"
      hint={hint}
    >
      <Text color={theme.koiCream} backgroundColor={theme.koiInk} bold>
        {" leanCLI · interactive wallet "}
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
