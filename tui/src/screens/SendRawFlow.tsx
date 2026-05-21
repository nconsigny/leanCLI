import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import Select from "../widgets/Select.js";
import { Layout, Banner } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";
import { formatEth, hexToBigInt, shortAddr } from "../format.js";
import { SlotKind } from "../types.js";
import { TransfersBlock } from "../widgets/TransfersBlock.js";
import { ProvenancePanel } from "../widgets/ProvenancePanel.js";
import UnlockEoaStep from "./UnlockEoaStep.js";

/** A pre-selected signing wallet. Threaded in by callers (e.g. SwapFlow)
 *  who already know which wallet is active — skips the EOA picker and
 *  routes TPM/R1 wallets to the TPM-PIN path. */
export type SendRawWallet = {
  kind: SlotKind;
  name: string;
  address: string;
};

type Props = {
  /** The unsigned tx the caller (e.g. LlmDraftFlow) wants signed.
   *  `canonical` is the Lean-rendered structural description of the
   *  underlying Intent (from tx.encodeIntent's response); when present
   *  it is shown in ConfirmGate alongside the ERC-7730 decode and the
   *  simulation. Trusted-path callers (SendFlow, SwapFlow's approve
   *  step) currently omit it; the LLM chat flow always supplies it. */
  tx: { to: string; value: string; data: string; rationale?: string; canonical?: string };
  /** Optional chain id; defaults to whatever the daemon is configured for. */
  chainId?: number;
  /** Optional pre-selected wallet. When omitted, the historic behaviour
   *  (EOA picker + passphrase) is used. When provided as `tpm`, the
   *  flow skips the picker, prompts for the TPM PIN once, and routes
   *  through `r1.sendRawSepolia` with the PIN in the request params. */
  wallet?: SendRawWallet;
  onDone: (success: boolean) => void;
};

type Phase =
  | { kind: "loading-wallets" }
  | { kind: "pick-wallet"; eoas: EoaSlot[] }
  | { kind: "unlock"; wallet: EoaSlot }
  | { kind: "pin"; wallet: EoaSlot }
  | { kind: "unlock-error"; message: string }
  | {
      kind: "simulate";
      wallet: EoaSlot;
      pin: string;
      tpm: boolean;
    }
  | {
      kind: "confirm";
      wallet: EoaSlot;
      pin: string;
      decoded: any;
      sim: any;
      preflight: any;
      tpm: boolean;
    }
  | {
      kind: "send";
      wallet: EoaSlot;
      pin: string;
      tpm: boolean;
    };

type EoaSlot = { name: string; address: string };

/** Sign-and-broadcast an arbitrary {to, value, data} payload through an EOA
 *  slot. Reused by LlmDraftFlow when the user accepts a drafted candidate.
 *  Pipeline: pick wallet → passphrase → unlock → simulate → confirm → sign.
 *  ConfirmGate is the load-bearing security step; the rationale from the
 *  caller is shown alongside the simulation result. */
export default function SendRawFlow({ tx, chainId, wallet, onDone }: Props) {
  // If the caller already knows the wallet, skip the picker entirely:
  //   - TPM/R1 → prompt for the TPM PIN, then simulate
  //   - EOA    → prompt for the passphrase to unlock the slot
  const initialPhase: Phase =
    wallet?.kind === "tpm"
      ? { kind: "pin", wallet: { name: wallet.name, address: wallet.address } }
      : wallet?.kind === "eoa"
        ? { kind: "unlock", wallet: { name: wallet.name, address: wallet.address } }
        : { kind: "loading-wallets" };
  const [phase, setPhase] = useState<Phase>(initialPhase);

  // Step 1: list EOA wallets the user can sign with. Only runs when
  // the caller did not pre-select a wallet.
  useEffect(() => {
    if (phase.kind !== "loading-wallets") return;
    let cancelled = false;
    call<any>("account.list").then((r) => {
      if (cancelled) return;
      if (!r.ok) {
        return setPhase({
          kind: "unlock-error",
          message: `account.list failed: ${r.error.message}`,
        });
      }
      const all = (r.result?.accounts ?? []) as any[];
      const eoas: EoaSlot[] = all
        .filter((a) => a.type === "eoa" && typeof a.name === "string" && typeof a.address === "string")
        .map((a) => ({ name: a.name, address: a.address }));
      if (eoas.length === 0) {
        return setPhase({
          kind: "unlock-error",
          message: "no EOA wallets configured — create one first",
        });
      }
      setPhase({ kind: "pick-wallet", eoas });
    });
    return () => {
      cancelled = true;
    };
  }, [phase.kind]);

  if (phase.kind === "loading-wallets") {
    return (
      <Layout title="Sign drafted transaction" subtitle="Loading wallets…">
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>asking the daemon for available EOAs</Text>
        </Text>
      </Layout>
    );
  }

  if (phase.kind === "unlock-error") {
    return (
      <Layout title="Cannot sign" hint="enter / esc — back">
        <Banner kind="err" text={phase.message} />
        <BackOnInput onDone={() => onDone(false)} />
      </Layout>
    );
  }

  if (phase.kind === "pick-wallet") {
    return (
      <Layout
        title="Pick a signing wallet"
        subtitle={`tx → ${shortAddr(tx.to)} · value ${tx.value} · data ${tx.data === "0x" ? "0x (native)" : tx.data.slice(0, 10) + "…"}`}
        hint="↑/↓ move · enter pick · esc cancel"
      >
        <Select
          items={phase.eoas.map((e) => ({
            label: `${e.name.padEnd(16)}  ${shortAddr(e.address)}`,
            value: e.name,
          }))}
          onSelect={(it) => {
            const w = phase.eoas.find((e) => e.name === it.value);
            if (w) setPhase({ kind: "unlock", wallet: w });
          }}
        />
      </Layout>
    );
  }

  if (phase.kind === "unlock") {
    return (
      <UnlockEoaStep
        wallet={phase.wallet}
        subtitle={`address: ${phase.wallet.address}`}
        onUnlocked={() =>
          setPhase({
            kind: "simulate",
            wallet: phase.wallet,
            pin: "",
            tpm: false,
          })
        }
        onCancel={() => onDone(false)}
      />
    );
  }

  if (phase.kind === "pin") {
    const fields: Field[] = [
      {
        name: "pin",
        label: `TPM PIN for ${phase.wallet.name}`,
        secret: true,
        validate: (v) => (v.length < 4 ? "at least 4 characters" : null),
      },
    ];
    return (
      <Layout
        title={`Authorize ${phase.wallet.name} (TPM/R1)`}
        subtitle={`address: ${phase.wallet.address}`}
      >
        <Form
          fields={fields}
          onCancel={() => onDone(false)}
          onSubmit={(v) =>
            setPhase({
              kind: "simulate",
              wallet: phase.wallet,
              pin: v.pin ?? "",
              tpm: true,
            })
          }
        />
      </Layout>
    );
  }

  if (phase.kind === "simulate") {
    return (
      <SimulateOnly
        wallet={phase.wallet}
        tx={tx}
        chainId={chainId}
        onError={(message) => setPhase({ kind: "unlock-error", message })}
        onReady={(decoded, sim, preflight) =>
          setPhase({
            kind: "confirm",
            wallet: phase.wallet,
            pin: phase.pin,
            decoded,
            sim,
            preflight,
            tpm: phase.tpm,
          })
        }
      />
    );
  }

  if (phase.kind === "confirm") {
    return (
      <ConfirmGate
        wallet={phase.wallet}
        tx={tx}
        decoded={phase.decoded}
        sim={phase.sim}
        preflight={phase.preflight}
        tpm={phase.tpm}
        canonical={tx.canonical}
        chainId={chainId}
        onConfirm={() =>
          setPhase({
            kind: "send",
            wallet: phase.wallet,
            pin: phase.pin,
            tpm: phase.tpm,
          })
        }
        onCancel={() => onDone(false)}
      />
    );
  }

  // Phase 6: actually sign + broadcast. EOA → eoa.send (already accepts
  // `data`). TPM/R1 → r1.sendRawSepolia with the captured PIN forwarded
  // so the daemon can pass it to the TPM auth check.
  // The chain badge in the subtitle keeps the destination network
  // visible on the broadcast screen — otherwise users can mis-identify
  // which chain a failure refers to.
  const chainBadge = chainTag(chainId);
  const chainName = chainIdToName(chainId);
  if (phase.tpm) {
    return (
      <RpcRunner
        title={`Sending tx as ${phase.wallet.name} (TPM/R1)`}
        subtitle={`${chainBadge} · to ${tx.to} · TPM PIN will be checked at sign time`}
        method="r1.sendRawSepolia"
        params={{
          name: phase.wallet.name,
          to: tx.to,
          value: hexToBigInt(tx.value),
          data: tx.data,
          pin: phase.pin,
        }}
        renderResult={(r) => <RawResult result={r} />}
        onDone={onDone}
      />
    );
  }
  return (
    <RpcRunner
      title={`Sending tx as ${phase.wallet.name}`}
      subtitle={`${chainBadge} · to ${tx.to} · value ${tx.value}`}
      method="eoa.send"
      params={{
        name: phase.wallet.name,
        chain: chainName,
        to: tx.to,
        value: hexToBigInt(tx.value),
        data: tx.data,
      }}
      renderResult={(r) => <RawResult result={r} />}
      onDone={onDone}
    />
  );
}

/** Human-readable chain identifier — "sepolia (11155111)" beats raw ints
 *  in any failure mode where the wrong-chain hypothesis matters. The
 *  wallet's supported chain set is intentionally narrow: mainnet +
 *  sepolia only. Unknown chainIds render as the bare integer. */
function chainTag(chainId?: number): string {
  if (chainId === undefined || chainId === null) return "chain (unset)";
  const n = chainIdToName(chainId);
  return n ? `${n} (${chainId})` : `chain ${chainId}`;
}

/** chainId (numeric) → canonical name expected by daemon RPCs that gate
 *  on `chain`. The daemon's `endpointForChain` matches on the key in
 *  `cfg.chainEndpoints` — typically the chain's English name. We only
 *  recognise mainnet (1) and sepolia (11155111); other chainIds fall
 *  through and the daemon uses cfg.rpcEndpoint as the default. */
function chainIdToName(chainId?: number): string | undefined {
  if (chainId === undefined || chainId === null) return undefined;
  switch (chainId) {
    case 1:        return "mainnet";
    case 11155111: return "sepolia";
    default:       return undefined;
  }
}

function SimulateOnly({
  wallet,
  tx,
  chainId,
  onError,
  onReady,
}: {
  wallet: EoaSlot;
  tx: Props["tx"];
  chainId?: number;
  onError: (msg: string) => void;
  onReady: (decoded: any, sim: any, preflight: any) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    (async () => {
      // EOA slots are pre-unlocked by `UnlockEoaStep` before we reach
      // this phase; TPM/R1 slots carry the PIN in send params and the
      // TPM authorises at sign time. Either way, no unlock call here.

      // Decode + simulate + preflight context in parallel. preflight is
      // a separate daemon round-trip rather than baked into simulate so
      // we can degrade gracefully (TUI renders whatever subset returns).
      const chainName = chainIdToName(chainId);
      const [d, s, p] = await Promise.all([
        call<any>("tx.decodeIntent", {
          chainId: chainId ?? 1,
          to: tx.to,
          value: tx.value,
          data: tx.data,
          from: wallet.address,
        }),
        call<any>("tx.simulate", {
          chainId: chainId ?? 1,
          chain: chainName,
          to: tx.to,
          value: tx.value,
          data: tx.data,
          from: wallet.address,
          block: "latest",
          trace: true,
        }),
        call<any>("tx.preflightContext", {
          chainId: chainId ?? 1,
          chain: chainName,
          to: tx.to,
          value: tx.value,
          data: tx.data,
          from: wallet.address,
        }),
      ]);
      if (cancelled) return;
      const decoded = d.ok ? d.result?.result ?? d.result : { matched: false };
      const sim = s.ok ? s.result : { ok: false, simRpcError: s.error.message };
      const preflight = p.ok ? p.result : { kind: "error", error: p.error.message };
      onReady(decoded, sim, preflight);
    })();
    return () => {
      cancelled = true;
    };
  }, []);
  return (
    <Layout title="Pre-sign check">
      <Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>unlocking + simulating…</Text>
      </Text>
    </Layout>
  );
}

function ConfirmGate({
  wallet,
  tx,
  decoded,
  sim,
  preflight,
  tpm,
  canonical,
  chainId,
  onConfirm,
  onCancel,
}: {
  wallet: EoaSlot;
  tx: Props["tx"];
  decoded: any;
  sim: any;
  preflight: any;
  tpm: boolean;
  canonical?: string;
  chainId?: number;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  useInput((_, key) => {
    if (key.return) onConfirm();
    if (key.escape) onCancel();
  });
  const okSim = sim?.ok === true;
  return (
    <Layout
      title={`Confirm: sign as ${wallet.name}${tpm ? " (TPM/R1)" : ""} — ${chainTag(chainId)}`}
      subtitle={
        tpm
          ? `address ${shortAddr(wallet.address)} · TPM PIN will be checked at sign time`
          : `address ${shortAddr(wallet.address)}`
      }
      hint="enter — sign & broadcast · esc — cancel"
    >
      {tx.rationale && (
        <Box marginBottom={1}>
          <Text color={theme.dim}>agent: {tx.rationale}</Text>
        </Box>
      )}
      {canonical && (
        <ProvenancePanel
          title="canonical intent"
          tier="local"
          source="rendered by Lean (LeanKohaku/Intent/*) from the structural Intent ADT — no RPC involved"
        >
          {canonical.split("\n").map((line, i) => (
            <Text key={i}>{line}</Text>
          ))}
        </ProvenancePanel>
      )}
      <ProvenancePanel
        title="intent"
        tier="local"
        source={
          decoded?.matched
            ? [
                "ERC-7730 descriptor from bundled registry — bridge/clearsign/registry/*.json",
                "calldata decoded against descriptor ABI in the clearsign sidecar (treated as untrusted; UI-render only)",
                "token decimals/symbol via eth_call(decimals)/eth_call(symbol) — untrusted RPC (cached)",
              ]
            : [
                "no descriptor matched in bridge/clearsign/registry/ — raw calldata only",
                "4byte fallback registry is local, but no entry covered this selector",
              ]
        }
      >
        {decoded?.matched ? (
          <>
            <Text color={theme.primary} bold>
              {decoded.intent ?? decoded.function ?? "(no intent)"}
            </Text>
            {decoded.contractName && (
              <Text color={theme.dim}>
                {decoded.contractName} · {decoded.function}
              </Text>
            )}
            {(decoded.fields ?? []).map((f: any, i: number) => (
              <Text key={i}>
                <Text color={theme.dim}>{f.label.padEnd(14)}</Text>{" "}
                <Text>{f.formatted}</Text>
              </Text>
            ))}
          </>
        ) : (
          <Text color={theme.dim}>(no descriptor matched · raw calldata only)</Text>
        )}
      </ProvenancePanel>
      <PreflightBlock preflight={preflight} />
      <ProvenancePanel
        title="simulation"
        tier="remote"
        source={simulationSourceLines(sim)}
      >
        <Text>
          <Text color={theme.dim}>result: </Text>
          {sim?.simRpcError ? (
            <Text color={theme.warn}>(daemon error)</Text>
          ) : okSim ? (
            <Text color={theme.ok}>✓ would succeed</Text>
          ) : (
            <Text color={theme.err}>✗ would revert</Text>
          )}
        </Text>
        {sim?.gasEstimate && (
          <Text>
            <Text color={theme.dim}>gas: </Text>
            <Text>
              {(() => {
                try {
                  return BigInt(sim.gasEstimate).toString();
                } catch {
                  return sim.gasEstimate;
                }
              })()}{" "}
              units
            </Text>
          </Text>
        )}
        {sim?.revertReason && (
          <Text color={theme.err}>revert: {String(sim.revertReason).slice(0, 200)}</Text>
        )}
        <TransfersBlock sim={sim} />
      </ProvenancePanel>
      {!okSim && !sim?.simRpcError && (
        <Text color={theme.warn}>
          ⚠ Simulation failed. Pressing Enter will still broadcast — only
          do this if you understand why simulation is wrong.
        </Text>
      )}
    </Layout>
  );
}

/** Render the `tx.preflightContext` block — current chain state for the
 *  drafted intent (allowance for approves, balance for transfers, prior
 *  interactions for both). Display-only; the signer never sees this.
 *  Falls back to nothing when the daemon couldn't probe (no `from`,
 *  unknown kind, RPC error). */
function PreflightBlock({ preflight }: { preflight: any }) {
  if (!preflight || typeof preflight !== "object") return null;
  const kind = preflight.kind;
  if (kind !== "approve" && kind !== "transfer" && kind !== "native") return null;

  const rows: Array<{ label: string; value: string; warn?: boolean }> = [];

  if (kind === "approve") {
    const newAmt = preflight.newAmountHuman ?? "—";
    const curr = preflight.currentAllowanceHuman ?? "(unavailable)";
    const delta = preflight.delta ?? "";
    rows.push({ label: "current allowance", value: curr });
    rows.push({
      label: "new allowance",
      value: `${newAmt}${delta ? `  (${delta})` : ""}`,
      warn: delta === "increase" || delta === "first grant",
    });
  } else if (kind === "transfer" || kind === "native") {
    const bal = preflight.senderBalanceHuman ?? "(unavailable)";
    const amt = preflight.amountHuman ?? "—";
    const after = preflight.afterHuman ?? "—";
    rows.push({ label: "sender balance", value: bal });
    rows.push({
      label: "sending",
      value: amt,
      warn: preflight.insufficient === true,
    });
    rows.push({
      label: "balance after",
      value: preflight.insufficient ? "(insufficient funds)" : after,
      warn: preflight.insufficient === true,
    });
  }

  // Prior interactions — soft signal. Rendered as a single line so the
  // block stays compact when there's nothing surprising.
  const prior = preflight.priorInteractions;
  if (prior && prior.available === true) {
    const count = typeof prior.count === "number" ? prior.count : 0;
    const window = `(blocks ${prior.fromBlock}–${prior.toBlock})`;
    rows.push({
      label: "prior interactions",
      value:
        count === 0
          ? `none ${window} — first-time interaction with this address`
          : `${count} ${window}`,
      warn: count === 0,
    });
  } else if (prior && prior.available === false && prior.reason && kind !== "native") {
    rows.push({
      label: "prior interactions",
      value: `(unavailable — ${prior.reason})`,
    });
  }

  return (
    <ProvenancePanel
      title="chain context"
      tier="remote"
      source={preflightSourceLines(kind, preflight)}
    >
      {rows.map((r, i) => (
        <Text key={i}>
          <Text color={theme.dim}>{r.label.padEnd(20)}</Text>{" "}
          <Text color={r.warn ? theme.warn : undefined}>{r.value}</Text>
        </Text>
      ))}
      {preflight.probeError && (
        <Text color={theme.dim}>(probe error: {String(preflight.probeError)})</Text>
      )}
    </ProvenancePanel>
  );
}

/** Build the `source:` footer lines for the simulation panel, accurately
 *  reflecting which RPC primitives the daemon actually used. The trace
 *  line only appears when the daemon attempted `debug_traceCall`. */
function simulationSourceLines(sim: any): string[] {
  const lines: string[] = [
    "eth_call + eth_estimateGas on the configured RPC endpoint (untrusted execution node)",
  ];
  if (sim?.traceUnavailable) {
    lines.push("debug_traceCall not exposed by this RPC — token-flow trace unavailable");
  } else if (sim?.trace) {
    lines.push("debug_traceCall (callTracer + logs) on the same RPC — walked daemon-side to extract ERC-20 Transfer events");
  }
  if (sim?.simRpcError) {
    lines.push("daemon error: " + String(sim.simRpcError).slice(0, 120));
  }
  return lines;
}

/** Build the `source:` footer lines for the chain-context panel, naming
 *  the exact JSON-RPC methods the daemon used for this preflight kind. */
function preflightSourceLines(
  kind: "approve" | "transfer" | "native",
  preflight: any,
): string[] {
  const lines: string[] = [];
  if (kind === "approve") {
    lines.push("eth_call(allowance(owner,spender)) on the token contract — untrusted RPC");
  } else if (kind === "transfer") {
    lines.push("eth_call(balanceOf(owner)) on the token contract — untrusted RPC");
  } else if (kind === "native") {
    lines.push("eth_getBalance — untrusted RPC");
  }
  const prior = preflight?.priorInteractions;
  if (prior && prior.available === true) {
    lines.push("prior interactions: eth_getLogs over a fixed block window — untrusted RPC, best-effort");
  } else if (prior && prior.available === false && prior.reason) {
    lines.push("prior interactions: eth_getLogs not available (" + String(prior.reason).slice(0, 80) + ")");
  }
  return lines;
}

function RawResult({ result }: { result: any }) {
  const txHash = result?.txHash ?? "(no hash)";
  const status = result?.status ?? "(unknown)";
  return (
    <Box flexDirection="column">
      <Text>
        <Text color={theme.dim}>tx:    </Text>
        {txHash}
      </Text>
      <Text>
        <Text color={theme.dim}>status:</Text>{" "}
        <Text color={status === "success" ? theme.ok : theme.err}>{status}</Text>
      </Text>
      <Text color={theme.dim}>
        https://sepolia.etherscan.io/tx/{txHash}
      </Text>
    </Box>
  );
}

function BackOnInput({ onDone }: { onDone: () => void }) {
  useInput((_, key) => {
    if (key.return || key.escape) onDone();
  });
  return null;
}
