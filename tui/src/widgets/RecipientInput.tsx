import React, { useEffect, useMemo, useRef, useState } from "react";
import { Box, Text, useInput } from "ink";
import TextInput from "ink-text-input";
import { call } from "../daemon.js";
import { theme } from "../theme.js";
import { EoaListEntry, TpmListEntry } from "../types.js";

type OwnAccount = {
  kind: "eoa" | "tpm";
  name: string;
  /** lowercased address — comparisons elsewhere are case-insensitive. */
  address: string;
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
      const tpm = await call<TpmListEntry[]>("tpm.listSepoliaAddresses");
      if (cancelled) return;
      const out: OwnAccount[] = [];
      if (eoa.ok && Array.isArray(eoa.result)) {
        for (const e of eoa.result) {
          if (!e?.name || !e?.address) continue;
          out.push({ kind: "eoa", name: e.name, address: e.address.toLowerCase() });
        }
      }
      if (tpm.ok && Array.isArray(tpm.result)) {
        for (const t of tpm.result) {
          if (!t?.name || !t?.address) continue;
          out.push({ kind: "tpm", name: t.name, address: t.address.toLowerCase() });
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
            {matched.kind === "eoa" ? "[eoa] " : "[tpm] "}
            {matched.name}
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
