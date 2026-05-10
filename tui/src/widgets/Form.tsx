import React, { useState } from "react";
import { Box, Text, useInput } from "ink";
import TextInput from "ink-text-input";
import { theme } from "../theme.js";
import RecipientInput from "./RecipientInput.js";

export type Field = {
  name: string;
  label: string;
  /** Hint shown dimmed under the input. */
  placeholder?: string;
  /** If true, show as `*` characters. */
  secret?: boolean;
  /** Pre-filled value. */
  initial?: string;
  /** Sync validation. Return null on ok, an error message on failure. */
  validate?: (v: string) => string | null;
  /** Optional — skip the field if `false`. Lets a single Form definition
   *  conditionally drop fields based on prior answers. */
  when?: (values: Record<string, string>) => boolean;
  /** When set to "recipient", the field renders a RecipientInput that
   *  lets the user cycle their own accounts with ↑/↓ and colorizes the
   *  address when it matches one. */
  kind?: "recipient";
  /** For `kind: "recipient"` — the sender address, surfaced as "(self)"
   *  in the matched-account hint. */
  excludeAddress?: string;
};

type Props = {
  fields: Field[];
  /** Called once every required field is filled. */
  onSubmit: (values: Record<string, string>) => void;
  /** Esc handler. */
  onCancel: () => void;
};

/** Sequential field collector. One field at a time, Enter advances,
 *  Esc cancels. Keeps the trust profile of the CLI: secrets are never
 *  echoed and live only in this process's memory until forwarded to the
 *  daemon. */
export default function Form({ fields, onSubmit, onCancel }: Props) {
  const [values, setValues] = useState<Record<string, string>>(
    Object.fromEntries(
      fields.filter((f) => f.initial !== undefined).map((f) => [f.name, f.initial!]),
    ),
  );
  const [idx, setIdx] = useState(0);
  const [draft, setDraft] = useState("");
  const [error, setError] = useState<string | null>(null);

  const visible = fields.filter((f) => !f.when || f.when(values));
  const current = visible[idx];

  useInput((_, key) => {
    if (key.escape) onCancel();
  });

  if (!current) {
    // All fields collected — fire submit on next tick to avoid mid-render side effects.
    setTimeout(() => onSubmit(values), 0);
    return null;
  }

  return (
    <Box flexDirection="column">
      {visible.slice(0, idx).map((f) => (
        <Text key={f.name} color={theme.dim}>
          {f.label}: {f.secret ? "•".repeat((values[f.name] || "").length) : values[f.name]}
        </Text>
      ))}
      <Box>
        <Text color={theme.accent}>{current.label}: </Text>
        {current.kind === "recipient" ? (
          <RecipientInput
            value={draft}
            onChange={(v) => {
              setDraft(v);
              if (error) setError(null);
            }}
            placeholder={current.placeholder}
            excludeAddress={current.excludeAddress}
            onSubmit={(v) => {
              const err = current.validate?.(v) ?? null;
              if (err) {
                setError(err);
                return;
              }
              setValues((prev) => ({ ...prev, [current.name]: v }));
              setDraft("");
              setIdx((i) => i + 1);
            }}
          />
        ) : (
          <TextInput
            value={draft}
            onChange={(v) => {
              setDraft(v);
              if (error) setError(null);
            }}
            mask={current.secret ? "*" : undefined}
            placeholder={current.placeholder}
            onSubmit={(v) => {
              const err = current.validate?.(v) ?? null;
              if (err) {
                setError(err);
                return;
              }
              setValues((prev) => ({ ...prev, [current.name]: v }));
              setDraft("");
              setIdx((i) => i + 1);
            }}
          />
        )}
      </Box>
      {error && <Text color={theme.err}>error: {error}</Text>}
      <Text color={theme.dim}>enter • next · esc • cancel</Text>
    </Box>
  );
}
