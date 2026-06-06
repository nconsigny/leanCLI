import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { Layout, Banner } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import { call } from "../daemon.js";
import { verificationSourceLine } from "../format.js";
import { theme } from "../theme.js";
import { TransfersBlock } from "../widgets/TransfersBlock.js";
import { ProvenancePanel } from "../widgets/ProvenancePanel.js";

type Props = { onDone: (s: boolean) => void };

type Phase =
  | { kind: "form" }
  | { kind: "running"; chainId: number; to: string; value: string; data: string; from?: string }
  | { kind: "ok"; decoded: any; sim: any }
  | { kind: "err"; message: string };

const ADDR_RE = /^0x[0-9a-fA-F]{40}$/;
const HEX_RE = /^0x[0-9a-fA-F]*$/;

/** Phase 1 of clear-signing: paste calldata, see the ERC-7730-rendered
 *  intent. No signing — this is a read-only diagnostic screen. The Send
 *  flow will use the same daemon RPC as a pre-sign confirmation step
 *  in Phase 2. */
export default function DecodeIntentFlow({ onDone }: Props) {
  const [phase, setPhase] = useState<Phase>({ kind: "form" });

  if (phase.kind === "form") {
    const fields: Field[] = [
      {
        name: "chainId",
        label: "Chain ID",
        placeholder: "1 (mainnet) · 11155111 (sepolia)",
        validate: (v) => (/^\d+$/.test(v) ? null : "expected a positive integer"),
      },
      {
        name: "to",
        label: "Contract address",
        validate: (v) => (ADDR_RE.test(v) ? null : "expected a 0x… 20-byte address"),
      },
      {
        name: "value",
        label: "Value (wei, hex)",
        placeholder: "0x0",
        validate: (v) => (v === "" || HEX_RE.test(v) ? null : "expected a 0x-hex value"),
      },
      {
        name: "data",
        label: "Calldata (hex)",
        placeholder: "0xa9059cbb…",
        validate: (v) =>
          HEX_RE.test(v) && v.length >= 10
            ? null
            : "expected 0x + at least a 4-byte selector",
      },
      {
        name: "from",
        label: "From (optional, simulates as)",
        placeholder: "0x… (leave blank to skip)",
        validate: (v) =>
          v.length === 0 || ADDR_RE.test(v) ? null : "expected 0x… 20-byte address",
      },
    ];
    return (
      <Layout
        title="Decode transaction (ERC-7730)"
        subtitle="Paste calldata and see what the contract is being asked to do."
      >
        <Form
          fields={fields}
          onCancel={() => onDone(false)}
          onSubmit={(v) =>
            setPhase({
              kind: "running",
              chainId: Number(v.chainId ?? "1"),
              to: v.to ?? "",
              value: v.value && v.value.length > 0 ? v.value! : "0x0",
              data: v.data ?? "0x",
              from: v.from && v.from.length > 0 ? v.from : undefined,
            })
          }
        />
      </Layout>
    );
  }

  if (phase.kind === "running") {
    return <Runner phase={phase} setPhase={setPhase} />;
  }

  if (phase.kind === "err") {
    return (
      <Layout title="Decode failed" hint="enter / esc — back">
        <Banner kind="err" text={phase.message} />
        <BackOnInput onDone={() => onDone(false)} />
      </Layout>
    );
  }

  return (
    <Layout title="Transaction intent" hint="enter / esc — back">
      <ProvenancePanel
        title="intent"
        tier="local"
        source={
          phase.decoded?.matched === false
            ? [
                "selector not found in bundled registry — bridge/clearsign/registry/*.json",
                "4byte fallback registry is local but did not cover this selector either",
              ]
            : [
                "ERC-7730 descriptor from bundled registry — bridge/clearsign/registry/*.json",
                "calldata decoded against descriptor ABI in the clearsign sidecar (untrusted; UI-render only)",
                "token decimals/symbol via eth_call(decimals)/eth_call(symbol) — untrusted RPC (cached)",
              ]
        }
      >
        <DecodedView result={phase.decoded} />
      </ProvenancePanel>
      <ProvenancePanel
        title="simulation"
        tier="remote"
        source={decodeIntentSimSourceLines(phase.sim)}
      >
        <SimulationView sim={phase.sim} />
      </ProvenancePanel>
      <BackOnInput onDone={() => onDone(false)} />
    </Layout>
  );
}

/** Footer-source lines for the simulation panel of the standalone
 *  DecodeIntent screen. Same provenance as SendRawFlow's simulation
 *  panel — the daemon RPC is identical (`tx.simulate` → eth_call +
 *  eth_estimateGas + optional debug_traceCall on the untrusted RPC). */
function decodeIntentSimSourceLines(sim: any): string[] {
  const lines: string[] = [verificationSourceLine(sim)];
  if (sim?.traceUnavailable) {
    lines.push("debug_traceCall not exposed by this RPC — token-flow trace unavailable");
  } else if (sim?.trace) {
    lines.push("debug_traceCall (callTracer + logs) on the same RPC — walked daemon-side");
  }
  if (sim?.simRpcError) {
    lines.push("daemon error: " + String(sim.simRpcError).slice(0, 120));
  }
  return lines;
}

function Runner({
  phase,
  setPhase,
}: {
  phase: Extract<Phase, { kind: "running" }>;
  setPhase: (p: Phase) => void;
}) {
  useEffect(() => {
    let cancelled = false;

    // Run decode + simulate in parallel — they're independent and the
    // pre-sign confirmation surface needs both. Decode renders intent;
    // simulate is the load-bearing security check (does this revert? what
    // gas? what return value?).
    const decodeReq: any = {
      chainId: phase.chainId,
      to: phase.to,
      value: phase.value,
      data: phase.data,
    };
    if (phase.from) decodeReq.from = phase.from;

    const simReq: any = {
      chainId: phase.chainId,
      to: phase.to,
      value: phase.value,
      data: phase.data,
      block: "latest",
      trace: true,
    };
    if (phase.from) simReq.from = phase.from;

    Promise.all([
      call<any>("tx.decodeIntent", decodeReq),
      call<any>("tx.simulate", simReq),
    ]).then(([dRes, sRes]) => {
      if (cancelled) return;
      if (!dRes.ok) {
        return setPhase({ kind: "err", message: `decode: ${dRes.error.message}` });
      }
      // Decode response is wrapped { ok, result } by the bridge → unwrap.
      const decoded = dRes.result?.result ?? dRes.result;
      if (decoded?.ok === false) {
        return setPhase({
          kind: "err",
          message: `decode: ${decoded.error?.message ?? "decode failed"}`,
        });
      }
      // Simulate response is plain — direct from the daemon, no bridge.
      const sim = sRes.ok
        ? sRes.result
        : { ok: false, simRpcError: sRes.error.message };
      setPhase({ kind: "ok", decoded, sim });
    });
    return () => {
      cancelled = true;
    };
  }, []);
  return (
    <Layout title="Decoding + simulating…">
      <Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>asking the daemon to decode {phase.data.slice(0, 10)}…</Text>
      </Text>
      <Text color={theme.dim}>
        running eth_call + eth_estimateGas against the configured RPC endpoint
      </Text>
    </Layout>
  );
}

function DecodedView({ result }: { result: any }) {
  if (!result) {
    return <Banner kind="warn" text="(empty response)" />;
  }
  if (result.matched === false) {
    return (
      <Box flexDirection="column">
        <Banner kind="warn" text={`No descriptor matched (selector ${result.selector ?? "?"}).`} />
        <Text color={theme.dim}>{result.reason}</Text>
        <Text color={theme.dim}>
          Phase 2: fall back to ABI guess via 4byte / Etherscan and continue
          with raw display. For now, only contracts in the bundled registry
          can be decoded.
        </Text>
      </Box>
    );
  }
  return (
    <Box flexDirection="column">
      <Text>
        <Text color={theme.primary} bold>
          {result.intent ?? "(no intent)"}
        </Text>
      </Text>
      <Text color={theme.dim}>
        {result.contractName ?? "(unknown contract)"}
        {result.owner ? ` · ${result.owner}` : ""}
        {result.source ? ` · from ${result.source}` : ""}
      </Text>
      <Text color={theme.dim}>
        function {result.function} · selector {result.selector}
      </Text>
      <Box marginTop={1} flexDirection="column">
        {(result.fields ?? []).map((f: any, i: number) => (
          <Text key={i}>
            <Text color={theme.dim}>{f.label.padEnd(14)}</Text>{" "}
            <Text>{f.formatted}</Text>
          </Text>
        ))}
      </Box>
      {result.partial && (
        <Box marginTop={1}>
          <Banner kind="warn" text={`Partial match: ${result.error ?? "decode incomplete"}`} />
        </Box>
      )}
    </Box>
  );
}

/** Render the daemon's `tx.simulate` result as a small block under the
 *  decoded intent. The simulator output is the load-bearing security
 *  signal: "would this revert" + "how much gas" + "what return value". A
 *  green "ok" with a sane gas number means the call would succeed against
 *  current chain state; a red revert reason means do not sign. */
function SimulationView({ sim }: { sim: any }) {
  if (!sim) return null;
  if (sim.simRpcError) {
    return (
      <Box marginTop={1} flexDirection="column">
        <Text color={theme.warn}>⚠ simulate: daemon error</Text>
        <Text color={theme.dim}>{sim.simRpcError}</Text>
      </Box>
    );
  }

  // Daemon returns plain shape: { ok, block, tx, returnData?, revertReason?,
  // gasEstimate?, gasEstimateError? }.
  const okSim = sim.ok === true;
  return (
    <Box marginTop={1} flexDirection="column">
      <Text>
        <Text color={theme.dim}>simulation: </Text>
        {okSim ? (
          <Text color={theme.ok}>✓ would succeed</Text>
        ) : (
          <Text color={theme.err}>✗ would revert</Text>
        )}
        {sim.block && <Text color={theme.dim}> · block {sim.block}</Text>}
      </Text>
      {sim.gasEstimate && (
        <Text>
          <Text color={theme.dim}>gas: </Text>
          <Text>
            {sim.gasEstimate} ({decHex(sim.gasEstimate)} units)
          </Text>
        </Text>
      )}
      {sim.gasEstimateError && (
        <Text>
          <Text color={theme.dim}>gas: </Text>
          <Text color={theme.warn}>
            estimate failed — {String(sim.gasEstimateError).slice(0, 80)}
          </Text>
        </Text>
      )}
      {sim.returnData && sim.returnData !== "0x" && (
        <Text>
          <Text color={theme.dim}>returns: </Text>
          <Text>{shortHex(sim.returnData)}</Text>
        </Text>
      )}
      {sim.revertReason && (
        <Box flexDirection="column">
          <Text color={theme.err}>revert reason:</Text>
          <Text color={theme.dim}>{String(sim.revertReason)}</Text>
        </Box>
      )}
      <TransfersBlock sim={sim} />
    </Box>
  );
}

// Render a 0x… hex value as a decimal integer (best effort).
function decHex(hex: string): string {
  try {
    return BigInt(hex).toString();
  } catch {
    return hex;
  }
}

function shortHex(hex: string): string {
  if (hex.length <= 18) return hex;
  return `${hex.slice(0, 10)}…${hex.slice(-6)}`;
}

function BackOnInput({ onDone }: { onDone: () => void }) {
  useInput((_, key) => {
    if (key.return || key.escape) onDone();
  });
  return null;
}
