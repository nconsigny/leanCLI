import React, { useEffect, useMemo, useRef, useState } from "react";
import { Box, Text, useInput } from "ink";
import TextInput from "ink-text-input";
import { call } from "../daemon.js";
import { theme } from "../theme.js";
import { EoaListEntry } from "../types.js";

type OwnAccount = {
  kind: "eoa" | "sphincs";
  name: string;
  /** lowercased address — comparisons elsewhere are case-insensitive. */
  address: string;
  /** BIP-32 account index for EOA sub-accounts (0 = primary).
   *  SPHINCS- hybrid wallets have no sub-accounts so this stays
   *  `undefined`. */
  accountIndex?: number;
  /** Derivation path, when known (e.g. "m/44'/60'/0'/0/0"). */
  path?: string;
};

type Props = {
  value: string;
  onChange: (v: string) => void;
  onSubmit?: (v: string) => void;
  placeholder?: string;
  /** Sender — kept in the cycle list but tagged "(self)" so the user can
   *  see when they would be sending to themselves. */
  excludeAddress?: string;
};

/** Recipient text input that lets the user cycle through their own
 *  accounts via ↑/↓. When the entered value matches a known account the
 *  row is rendered in `theme.ok` and the account name is shown next to
 *  it so the user can verify "this is mine" at a glance. */
export default function RecipientInput({
  value,
  onChange,
  onSubmit,
  placeholder,
  excludeAddress,
}: Props) {
  const [accounts, setAccounts] = useState<OwnAccount[]>([]);
  // -1 means "user-typed value, not a cycled pick" so the next ↓ jumps
  // to index 0 rather than 1. Held in a ref because keystrokes from
  // useInput shouldn't trigger re-renders to read it back.
  const cursorRef = useRef<number>(-1);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const eoa = await call<EoaListEntry[]>("eoa.list");
      if (cancelled) return;
      const out: OwnAccount[] = [];
      // Expand each EOA slot into one OwnAccount per BIP-32 sub-account
      // by calling eoa.account.list. A slot with no extra accounts
      // returns a single primary; one with sub-accounts returns every
      // derived address. Lets the user cycle through "leanWallet/0",
      // "leanWallet/1", … as recipients, not just the primary.
      if (eoa.ok && Array.isArray(eoa.result)) {
        for (const e of eoa.result) {
          if (!e?.name) continue;
          const sub = await call<{ accounts: { index: number; path: string; address: string }[] }>(
            "eoa.account.list",
            { name: e.name },
          );
          if (cancelled) return;
          if (sub.ok && Array.isArray(sub.result?.accounts) && sub.result.accounts.length > 0) {
            for (const a of sub.result.accounts) {
              if (!a?.address) continue;
              out.push({
                kind: "eoa",
                name: e.name,
                address: a.address.toLowerCase(),
                accountIndex: a.index,
                path: a.path,
              });
            }
          } else if (e.address) {
            // Fallback: slot exists but eoa.account.list returned
            // nothing (older record format) — surface the primary.
            out.push({ kind: "eoa", name: e.name, address: e.address.toLowerCase() });
          }
        }
      }
      // SPHINCS- hybrid smart accounts. The unified `account.list` RPC
      // already emits them; we pull only the ones that already have a
      // smart-account address computed (the on-chain identity of the
      // sphincs slot). Slots in the "pending compute" state are skipped
      // — sending to a zero-address counterfactual would be a bug, not
      // a feature, so we don't surface them as cycle targets.
      const acct = await call<{ accounts: { type: string; name: string; address: string }[] }>(
        "account.list",
        {},
      );
      if (cancelled) return;
      if (acct.ok && Array.isArray(acct.result?.accounts)) {
        for (const a of acct.result.accounts) {
          if (a?.type !== "sphincs" || !a.name || !a.address) continue;
          out.push({ kind: "sphincs", name: a.name, address: a.address.toLowerCase() });
        }
      }
      setAccounts(out);
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const matched = useMemo<OwnAccount | null>(() => {
    if (!value) return null;
    const v = value.toLowerCase();
    return accounts.find((a) => a.address === v) ?? null;
  }, [value, accounts]);

  useInput((_, key) => {
    if (accounts.length === 0) return;
    if (!key.upArrow && !key.downArrow) return;
    const dir = key.upArrow ? -1 : 1;
    const cur = cursorRef.current;
    const next =
      cur < 0
        ? dir > 0
          ? 0
          : accounts.length - 1
        : (cur + dir + accounts.length) % accounts.length;
    cursorRef.current = next;
    const picked = accounts[next];
    if (picked) onChange(picked.address);
  });

  const isOwn = matched != null;
  const isSelf =
    !!excludeAddress &&
    !!value &&
    excludeAddress.toLowerCase() === value.toLowerCase();

  return (
    <Box flexDirection="column">
      <Box>
        {/* Wrapping TextInput in a colored <Text> propagates the color
            into ink-text-input's internal <Text> rendering. */}
        <Text color={isOwn ? theme.ok : undefined}>
          <TextInput
            value={value}
            onChange={(v) => {
              cursorRef.current = -1;
              onChange(v);
            }}
            onSubmit={onSubmit}
            placeholder={placeholder}
          />
        </Text>
        {isOwn && matched && (
          <Text color={theme.ok}>
            {"  ← "}
            {matched.kind === "eoa" ? "[eoa] " : "[sphincs] "}
            {matched.name}
            {matched.kind === "eoa" && matched.accountIndex !== undefined
              ? `/${matched.accountIndex}`
              : ""}
            {isSelf ? " (self)" : ""}
          </Text>
        )}
      </Box>
      {accounts.length > 0 && (
        <Text color={theme.dim}>
          ↑/↓ cycle your {accounts.length} account
          {accounts.length === 1 ? "" : "s"}
        </Text>
      )}
    </Box>
  );
}
