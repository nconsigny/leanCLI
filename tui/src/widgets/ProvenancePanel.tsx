import React from "react";
import { Box, Text } from "ink";
import { theme } from "../theme.js";

/** Trust tier for the data shown inside a confirm panel.
 *
 *  - `local`    — content derived from code or files we ship in this repo
 *                 (Lean modules, the bundled ERC-7730 registry, 4byte fallback).
 *                 Border = green.
 *  - `verified` — content produced by a stateless light-client EVM that
 *                 re-executes the call against consensus-verified state
 *                 (Colibri). Border = primary cyan.
 *  - `remote`   — content fetched from an external execution-node RPC
 *                 (`eth_call`, `eth_estimateGas`, `eth_getLogs`,
 *                 `debug_traceCall`). The RPC is treated as untrusted —
 *                 the panel border is yellow precisely so the eye learns
 *                 that "an attacker who controls the RPC controls these
 *                 numbers". Border = yellow.
 */
export type ProvenanceTier = "local" | "verified" | "remote";

function tierColor(t: ProvenanceTier): string {
  switch (t) {
    case "local":    return theme.ok;
    case "verified": return theme.primary;
    case "remote":   return theme.warn;
  }
}

function tierLabel(t: ProvenanceTier): string {
  switch (t) {
    case "local":    return "LOCAL";
    case "verified": return "VERIFIED";
    case "remote":   return "REMOTE";
  }
}

/** Bordered sub-box used inside ConfirmGate / DecodeIntent screens to
 *  group one logical signal (intent decode, chain context, simulation,
 *  …) AND to surface its data-supply-chain so the user can see at a
 *  glance which lines are derived from local code and which lines come
 *  from a third-party RPC.
 *
 *  The footer is the load-bearing part. It is not optional. The intent
 *  of this widget is "no information without provenance". */
export function ProvenancePanel({
  title,
  tier,
  source,
  children,
}: {
  /** Short panel title — what this block is showing. Examples: "intent",
   *  "chain context", "simulation". */
  title: string;
  /** Trust tier — drives border colour and the [TIER] chip in the header. */
  tier: ProvenanceTier;
  /** One or more lines describing where each value in this panel came
   *  from. Be specific — name the file path, the JSON-RPC method, or
   *  the light-client module. The line(s) appear under the panel body
   *  preceded by "source:" (first line) / two-space indent (subsequent
   *  lines). */
  source: string | string[];
  children: React.ReactNode;
}) {
  const color = tierColor(tier);
  const chip = tierLabel(tier);
  const lines = Array.isArray(source) ? source : [source];
  return (
    <Box
      flexDirection="column"
      marginBottom={1}
      borderStyle="round"
      borderColor={color}
      paddingX={1}
    >
      <Box flexDirection="row" justifyContent="space-between">
        <Text color={theme.dim} bold>{title}</Text>
        <Text color={color}>[{chip}]</Text>
      </Box>
      <Box flexDirection="column" marginTop={0}>
        {children}
      </Box>
      <Box flexDirection="column" marginTop={1}>
        {lines.map((line, i) => (
          <Text key={i} color={theme.dim}>
            {i === 0 ? "source: " : "        "}
            {line}
          </Text>
        ))}
      </Box>
    </Box>
  );
}
