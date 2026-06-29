import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import Select from "../widgets/Select.js";
import { Layout, Banner } from "../widgets/Layout.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";
import { hexToBigInt, shortAddr, verificationSourceLine } from "../format.js";
import { SlotKind } from "../types.js";
import { TransfersBlock } from "../widgets/TransfersBlock.js";
import { ProvenancePanel } from "../widgets/ProvenancePanel.js";
import UnlockEoaStep from "./UnlockEoaStep.js";

/** A pre-selected signing wallet. Threaded in by callers (e.g. SwapFlow)
 *  who already know which wallet is active — skips the EOA picker. */
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
   *  (EOA picker + passphrase) is used. */
  wallet?: SendRawWallet;
  /** Called when the flow ends. `success=true` only fires after the user
   *  dismisses the post-broadcast result screen; in that case `result`
   *  carries the raw RPC payload (`eoa.send` / `sphincs.account.send`)
   *  so callers can extract `txHash` / `status` for chat-side
   *  confirmation rendering. */
  onDone: (success: boolean, result?: unknown) => void;
};

/** What signing path the daemon dispatches to in the final phase.
 *  - eoa     → `eoa.send` (passphrase unlock via UnlockEoaStep)
 *  - sphincs → `sphincs.account.send` (UserOp; daemon handles dual-sign,
 *              no per-slot passphrase prompt here) */
type SignerKind = "eoa" | "sphincs";

type Phase =
  | { kind: "loading-wallets" }
  | { kind: "pick-wallet"; slots: PickSlot[] }
  | { kind: "unlock"; wallet: EoaSlot }
  | { kind: "unlock-error"; message: string }
  | {
      kind: "simulate";
      wallet: EoaSlot;
      signerKind: SignerKind;
    }
  | {
      kind: "confirm";
      wallet: EoaSlot;
      decoded: any;
      sim: any;
      preflight: any;
      signerKind: SignerKind;
    }
  | {
      kind: "send";
      wallet: EoaSlot;
      signerKind: SignerKind;
    };

type EoaSlot = { name: string; address: string };
/** One row in the fallback signing-wallet picker. Carries the signer
 *  kind so a SPHINCS pick routes to the UserOp path (skipping the EOA
 *  unlock) exactly like a pre-selected SPHINCS wallet does. */
type PickSlot = { kind: SignerKind; name: string; address: string };

/** Sign-and-broadcast an arbitrary {to, value, data} payload through an EOA
 *  slot. Reused by LlmDraftFlow when the user accepts a drafted candidate.
 *  Pipeline: pick wallet → passphrase → unlock → simulate → confirm → sign.
 *  ConfirmGate is the load-bearing security step; the rationale from the
 *  caller is shown alongside the simulation result. */
export default function SendRawFlow({ tx, chainId, wallet, onDone }: Props) {
  // If the caller already knows the wallet, skip the picker entirely:
  //   - EOA    → prompt for the passphrase to unlock the slot
  //   - SPHINCS → skip the unlock. Daemon-side `sphincs.account.send`
  //     handles dual-sign auth via the master keystore and the per-slot
  //     passphrase (optional). We go straight to the sim step so the user
  //     still sees ConfirmGate before any UserOp is submitted.
  const initialPhase: Phase =
    wallet?.kind === "eoa"
      ? { kind: "unlock", wallet: { name: wallet.name, address: wallet.address } }
      : wallet?.kind === "sphincs"
        ? {
            kind: "simulate",
            wallet: { name: wallet.name, address: wallet.address },
            signerKind: "sphincs",
          }
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
      // Offer both signer kinds. A SPHINCS slot is only a valid signing
      // target once its counterfactual address is computed (account.list
      // emits address="" before then), so require a non-empty address for
      // both kinds.
      const slots: PickSlot[] = all
        .filter(
          (a) =>
            (a.type === "eoa" || a.type === "sphincs") &&
            typeof a.name === "string" &&
            typeof a.address === "string" &&
            a.address.length > 0,
        )
        .map((a) => ({ kind: a.type as SignerKind, name: a.name, address: a.address }));
      if (slots.length === 0) {
        return setPhase({
          kind: "unlock-error",
          message: "no signing wallets configured — create one first",
        });
      }
      setPhase({ kind: "pick-wallet", slots });
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
          <Text color={theme.dim}>asking the daemon for available signing wallets</Text>
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
          items={phase.slots.map((s) => ({
            label: `${`[${s.kind}]`.padEnd(9)}${s.name.padEnd(16)}  ${shortAddr(s.address)}`,
            value: s.name,
          }))}
          onSelect={(it) => {
            const w = phase.slots.find((s) => s.name === it.value);
            if (!w) return;
            // EOA → passphrase unlock; SPHINCS → straight to simulate on
            // the UserOp path (daemon dual-signs; no per-slot passphrase),
            // mirroring the pre-selected SPHINCS branch in initialPhase.
            if (w.kind === "sphincs") {
              setPhase({
                kind: "simulate",
                wallet: { name: w.name, address: w.address },
                signerKind: "sphincs",
              });
            } else {
              setPhase({ kind: "unlock", wallet: { name: w.name, address: w.address } });
            }
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
            signerKind: "eoa",
          })
        }
        onCancel={() => onDone(false)}
      />
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
            decoded,
            sim,
            preflight,
            signerKind: phase.signerKind,
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
        signerKind={phase.signerKind}
        canonical={tx.canonical}
        chainId={chainId}
        onConfirm={() =>
          setPhase({
            kind: "send",
            wallet: phase.wallet,
            signerKind: phase.signerKind,
          })
        }
        onCancel={() => onDone(false)}
      />
    );
  }

  // Phase 6: actually sign + broadcast. Branches on signerKind:
  //   eoa     → `eoa.send` (already accepts `data`)
  //   sphincs → `sphincs.account.send` (UserOp via the configured bundler;
  //              daemon performs the dual ECDSA + SPHINCS+ sign internally)
  // The chain badge in the subtitle keeps the destination network
  // visible on the broadcast screen — otherwise users can mis-identify
  // which chain a failure refers to.
  const chainBadge = chainTag(chainId);
  const chainName = chainIdToName(chainId);
  if (phase.signerKind === "sphincs") {
    // `sphincs.account.send` accepts `value` as decimal-wei string or
    // `valueEth` as decimal-ETH; we pass the wei value (parsed from the
    // 0x-hex `tx.value` blob) as a decimal string so the daemon's
    // `String.toNat?` path handles it directly.
    return (
      <RpcRunner
        title={`Submitting UserOp as ${phase.wallet.name} (SPHINCS-)`}
        subtitle={`${chainBadge} · to ${tx.to} · dual-sign via bundler`}
        method="sphincs.account.send"
        params={{
          name: phase.wallet.name,
          to: tx.to,
          value: hexToBigInt(tx.value).toString(),
          data: tx.data,
        }}
        renderResult={(r) => (
          <SphincsUserOpResult result={r} name={phase.wallet.name} chainId={chainId} />
        )}
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
      renderResult={(r) => <RawResult result={r} chainId={chainId} />}
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
      // this phase; sphincs slots authorise dual-sign daemon-side at
      // send time. Either way, no unlock call here.

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
  signerKind,
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
  signerKind: SignerKind;
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
  // eth_call says the logic wouldn't revert, but `from` can't cover gas
  // (e.g. 0 ETH). Folded into the single result line below rather than
  // shown as a second, easily-missed warning.
  const unaffordable =
    sim?.affordability?.checked === true && sim.affordability.affordable === false;
  // Signer-specific labelling threaded through the title + subtitle so the
  // user always knows which key path will sign — and what extra auth
  // happens at sign time (sphincs dual-sign via bundler).
  const titleSuffix =
    signerKind === "sphincs" ? " (SPHINCS-)"
    : "";
  const subtitleSuffix =
    signerKind === "sphincs" ? " · dual-sign UserOp via configured bundler"
    : "";
  return (
    <Layout
      title={`Confirm: sign as ${wallet.name}${titleSuffix} — ${chainTag(chainId)}`}
      subtitle={`address ${shortAddr(wallet.address)}${subtitleSuffix}`}
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
          source="rendered by Lean (LeanCli/Intent/*) from the structural Intent ADT — no RPC involved"
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
            {decoded.tokenInfo && (
              <Text>
                <Text color={theme.dim}>{"Token".padEnd(14)}</Text>{" "}
                <Text>
                  {decoded.tokenInfo.symbol
                    ? `${decoded.tokenInfo.symbol} (${decoded.tokenInfo.address})`
                    : `${decoded.tokenInfo.address} (symbol unresolved)`}
                </Text>
              </Text>
            )}
            {(decoded.fields ?? []).map((f: any, i: number) => (
              <Text key={i}>
                <Text color={theme.dim}>{f.label.padEnd(14)}</Text>{" "}
                <Text>{f.formatted}</Text>
              </Text>
            ))}
            {/* The sidecar matched the descriptor (so we have an intent +
                function signature) but the calldata failed to decode against
                that descriptor's ABI — `decoder.mjs` returns `{partial:true,
                error}` with NO `fields`. Without surfacing it the user sees
                an intent label and a blank argument list and assumes the
                decode succeeded. Make the failure loud: the args you're
                signing were NOT decoded. A descriptor↔calldata ABI mismatch
                (e.g. SwapRouter01's deadline field vs SwapRouter02's struct)
                is the usual cause. */}
            {(decoded.error || decoded.partial) && (
              <Text color={theme.err}>
                ⚠ argument decode failed — values NOT shown
                {decoded.error ? `: ${decoded.error}` : ""}
              </Text>
            )}
            {decoded.warning && (
              <Text color={theme.warn}>⚠ {decoded.warning}</Text>
            )}
            {!decoded.error && !decoded.partial && (decoded.fields ?? []).length === 0 && (
              <Text color={theme.dim}>(descriptor matched but declared no argument fields)</Text>
            )}
          </>
        ) : (
          <Text color={theme.dim}>
            (no descriptor matched · raw calldata only
            {decoded?.reason ? ` — ${decoded.reason}` : ""})
          </Text>
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
          ) : !okSim ? (
            <Text color={theme.err}>✗ would revert</Text>
          ) : unaffordable ? (
            <Text color={theme.err}>logic ok, but ETH balance too low for gas</Text>
          ) : (
            <Text color={theme.ok}>✓ would succeed</Text>
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
        {sim?.affordability?.checked === true && sim.affordability.affordable === true && (
          <Text color={theme.dim}>
            fee ≈ {String(sim.affordability.feeHuman)} · balance{" "}
            {String(sim.affordability.senderBalanceHuman)}
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
  const lines: string[] = [verificationSourceLine(sim)];
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

/** Block-explorer base for a chain. Defaults to Sepolia — the dev
 *  network — for unknown/unset chainIds so links stay clickable rather
 *  than pointing at the wrong network for mainnet sends. */
function explorerBase(chainId?: number): string {
  switch (chainId) {
    case 1:  return "https://etherscan.io";
    default: return "https://sepolia.etherscan.io";
  }
}

/** EOA result: `eoa.send` waits for the receipt daemon-side, so `txHash`
 *  and `status` are both present here. (SPHINCS UserOps return only a
 *  `userOpHash` and are rendered by `SphincsUserOpResult`, which polls.) */
function RawResult({ result, chainId }: { result: any; chainId?: number }) {
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
        {explorerBase(chainId)}/tx/{txHash}
      </Text>
    </Box>
  );
}

/** Extract the L1 inclusion tx hash from a `sphincs.account.getUserOp`
 *  result. Mirrors the daemon's own parse (SphincsRpc.lean): the ERC-4337
 *  receipt nests the L1 receipt under `receipt.receipt`; some bundlers
 *  (Candide) surface the hash earlier via `eth_getUserOperationByHash`
 *  (the `info` field). Either source is authoritative for "look it up". */
function inclusionTxFromUserOp(r: any): string | undefined {
  return (
    r?.receipt?.receipt?.transactionHash ??
    r?.info?.transactionHash ??
    undefined
  );
}

/** SPHINCS UserOp result. `sphincs.account.send` returns immediately with
 *  the bundler's `userOpHash` (a 4337-level id, NOT an L1 tx hash and not
 *  lookupable on etherscan). We show it right away so the submission is
 *  never invisible, then poll `sphincs.account.getUserOp` — the existing
 *  read-through to `eth_getUserOperationReceipt` — until the bundler
 *  reports inclusion, at which point we surface the real L1 tx hash +
 *  on-chain status. The poll RPC also journals the inclusion as a side
 *  effect, so the HistoryPanel later shows the L1 hash. */
function SphincsUserOpResult({
  result,
  name,
  chainId,
}: {
  result: any;
  name: string;
  chainId?: number;
}) {
  const userOpHash: string | undefined = result?.userOpHash;
  type Poll =
    | { kind: "pending"; elapsedSec: number }
    | { kind: "included"; txHash?: string; success?: boolean }
    | { kind: "timeout" };
  const [poll, setPoll] = useState<Poll>({ kind: "pending", elapsedSec: 0 });

  useEffect(() => {
    if (!userOpHash) return;
    let cancelled = false;
    const start = Date.now();
    // Poll budget: ~5 min. Candide on Sepolia usually includes within a
    // minute, but congested periods run longer; we keep the userOpHash
    // visible the whole time so the user can look it up out-of-band.
    const DEADLINE_MS = 300_000;
    const INTERVAL_MS = 4_000;

    const tick = async () => {
      if (cancelled) return;
      const r = await call<any>("sphincs.account.getUserOp", {
        userOpHash,
        name,
      });
      if (cancelled) return;
      if (r.ok && r.result?.included) {
        const txHash = inclusionTxFromUserOp(r.result);
        // `included` can flip true (userOp in the bundler's view) before
        // the L1 tx hash is populated; only treat it as terminal once we
        // actually have a hash to show.
        if (txHash) {
          const success =
            typeof r.result?.receipt?.success === "boolean"
              ? r.result.receipt.success
              : undefined;
          setPoll({ kind: "included", txHash, success });
          return;
        }
      }
      const elapsed = Date.now() - start;
      if (elapsed >= DEADLINE_MS) {
        setPoll({ kind: "timeout" });
        return;
      }
      setPoll({ kind: "pending", elapsedSec: Math.round(elapsed / 1000) });
      setTimeout(tick, INTERVAL_MS);
    };
    void tick();
    return () => {
      cancelled = true;
    };
  }, [userOpHash, name]);

  return (
    <Box flexDirection="column">
      <Text>
        <Text color={theme.dim}>userOpHash: </Text>
        {userOpHash ?? "(no hash returned)"}
      </Text>
      {poll.kind === "pending" && (
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>
            waiting for bundler inclusion… ({poll.elapsedSec}s)
          </Text>
        </Text>
      )}
      {poll.kind === "included" && (
        <>
          <Text>
            <Text color={theme.dim}>tx:        </Text>
            {poll.txHash}
          </Text>
          <Text>
            <Text color={theme.dim}>status:    </Text>{" "}
            {poll.success === undefined ? (
              <Text color={theme.dim}>included (receipt pending)</Text>
            ) : (
              <Text color={poll.success ? theme.ok : theme.err}>
                {poll.success ? "success" : "revert"}
              </Text>
            )}
          </Text>
          <Text color={theme.dim}>
            {explorerBase(chainId)}/tx/{poll.txHash}
          </Text>
        </>
      )}
      {poll.kind === "timeout" && (
        <Text color={theme.warn}>
          not yet included after 5min — still in the bundler queue. Look it
          up later from the account's history; the userOpHash above is the
          identifier.
        </Text>
      )}
    </Box>
  );
}

function BackOnInput({ onDone }: { onDone: () => void }) {
  useInput((_, key) => {
    if (key.return || key.escape) onDone();
  });
  return null;
}
