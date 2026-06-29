import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { Layout, Banner } from "../widgets/Layout.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";
import { shortAddr } from "../format.js";
import type { SendRawWallet } from "./SendRawFlow.js";

/** One action in a batch. `value` is wei — decimal or 0x-hex string (the
 *  daemon's `parseBatchLegs` accepts either); `data` is 0x-hex calldata.
 *  `label` is an optional caller-supplied human summary (e.g. "approve
 *  USDC") shown in ConfirmGate above the decoded intent. */
export type BatchLeg = {
  to: string;
  value: string;
  data: string;
  label?: string;
};

type Props = {
  /** The smart-account wallet to sign with. MUST be a `sphincs` slot —
   *  only smart accounts expose `executeBatch`. */
  wallet: SendRawWallet;
  /** The actions to execute atomically in one UserOperation. */
  legs: BatchLeg[];
  /** Optional chain id; defaults to whatever the daemon is configured for. */
  chainId?: number;
  /** Optional agent rationale shown at the top of ConfirmGate. */
  rationale?: string;
  /** Fires after the user dismisses the post-broadcast result screen. */
  onDone: (success: boolean, result?: unknown) => void;
};

/** One leg, enriched with its decoded intent for the confirm screen. */
type DecodedLeg = BatchLeg & { decoded: any };

type Phase =
  | { kind: "encode" }
  | { kind: "error"; message: string }
  | { kind: "confirm"; batchTo: string; batchData: string; legs: DecodedLeg[]; sim: any }
  | { kind: "send" };

/** Sign + broadcast a list of actions as ONE ERC-4337 `executeBatch`
 *  UserOperation from a SPHINCS- smart account. This is the batched
 *  sibling of `SendRawFlow`: it routes every leg through the same
 *  decode → simulate → ConfirmGate discipline before a single dual-signed
 *  UserOp is submitted via `sphincs.account.sendBatch`.
 *
 *  Pipeline: encode (daemon builds the executeBatch calldata, keeping ABI
 *  encoding in verified Lean) → per-leg decodeIntent + aggregate simulate
 *  (the whole executeBatch, `from = entryPoint`) → ConfirmGate → send. */
export default function SendBatchFlow({ wallet, legs, chainId, rationale, onDone }: Props) {
  const [phase, setPhase] = useState<Phase>({ kind: "encode" });

  useEffect(() => {
    if (phase.kind !== "encode") return;
    let cancelled = false;
    (async () => {
      if (wallet.kind !== "sphincs") {
        return setPhase({
          kind: "error",
          message: `batch send requires a smart account; ${wallet.name} is an ${wallet.kind} wallet`,
        });
      }
      if (legs.length === 0) {
        return setPhase({ kind: "error", message: "batch has no actions" });
      }
      // 1) Daemon builds the executeBatch calldata (encoder lives in Lean).
      const enc = await call<any>("sphincs.account.encodeBatch", { name: wallet.name, legs });
      if (cancelled) return;
      if (!enc.ok) {
        return setPhase({ kind: "error", message: `encodeBatch failed: ${enc.error.message}` });
      }
      const batchTo = enc.result?.to as string;
      const batchData = enc.result?.data as string;
      const entryPoint = enc.result?.entryPoint as string | undefined;
      if (!batchTo || !batchData) {
        return setPhase({ kind: "error", message: "encodeBatch returned no calldata" });
      }
      // 2) Decode each leg (human-readable list) + simulate the AGGREGATE
      //    executeBatch from the EntryPoint (so the account's
      //    `_requireForExecute` gate passes and the sim reflects all legs
      //    together, including inter-leg effects like approve-then-swap).
      const decodePromises = legs.map((leg) =>
        call<any>("tx.decodeIntent", {
          chainId: chainId ?? 1,
          to: leg.to,
          value: leg.value,
          data: leg.data,
          from: wallet.address,
        }),
      );
      const simPromise = call<any>("tx.simulate", {
        chainId: chainId ?? 1,
        to: batchTo,
        value: "0x0",
        data: batchData,
        from: entryPoint ?? batchTo,
        block: "latest",
        trace: true,
      });
      const [simRes, ...decodeRes] = await Promise.all([simPromise, ...decodePromises]);
      if (cancelled) return;
      const decodedLegs: DecodedLeg[] = legs.map((leg, i) => {
        const d = decodeRes[i];
        const decoded = d?.ok ? d.result?.result ?? d.result : { matched: false };
        return { ...leg, decoded };
      });
      const sim = simRes.ok ? simRes.result : { ok: false, simRpcError: simRes.error.message };
      setPhase({ kind: "confirm", batchTo, batchData, legs: decodedLegs, sim });
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind]);

  if (phase.kind === "encode") {
    return (
      <Layout title="Batch pre-sign check" subtitle={`${legs.length} actions · ${wallet.name}`}>
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>encoding executeBatch + simulating…</Text>
        </Text>
      </Layout>
    );
  }

  if (phase.kind === "error") {
    return (
      <Layout title="Cannot batch" hint="enter / esc — back">
        <Banner kind="err" text={phase.message} />
        <BackOnInput onDone={() => onDone(false)} />
      </Layout>
    );
  }

  if (phase.kind === "confirm") {
    return (
      <BatchConfirmGate
        wallet={wallet}
        legs={phase.legs}
        sim={phase.sim}
        rationale={rationale}
        chainId={chainId}
        onConfirm={() => setPhase({ kind: "send" })}
        onCancel={() => onDone(false)}
      />
    );
  }

  // Broadcast: ONE UserOp whose callData is executeBatch(legs). The daemon
  // dual-signs (ECDSA + SPHINCS+) and submits via the configured bundler.
  return (
    <RpcRunner
      title={`Submitting batch UserOp as ${wallet.name} (SPHINCS-)`}
      subtitle={`${chainTag(chainId)} · ${legs.length} actions · one nonce · dual-sign via bundler`}
      method="sphincs.account.sendBatch"
      params={{ name: wallet.name, legs }}
      renderResult={(r) => <BatchResult result={r} />}
      onDone={onDone}
    />
  );
}

function BatchConfirmGate({
  wallet,
  legs,
  sim,
  rationale,
  chainId,
  onConfirm,
  onCancel,
}: {
  wallet: SendRawWallet;
  legs: DecodedLeg[];
  sim: any;
  rationale?: string;
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
      title={`Confirm batch: sign as ${wallet.name} (SPHINCS-) — ${chainTag(chainId)}`}
      subtitle={`address ${shortAddr(wallet.address)} · ${legs.length} actions in ONE UserOp (atomic · one nonce)`}
      hint="enter — sign & broadcast · esc — cancel"
    >
      {rationale && (
        <Box marginBottom={1}>
          <Text color={theme.dim}>agent: {rationale}</Text>
        </Box>
      )}
      {legs.map((leg, i) => (
        <Box key={i} flexDirection="column" marginBottom={1}>
          <Text color={theme.primary} bold>
            {`#${i + 1}`} {leg.label ?? leg.decoded?.intent ?? leg.decoded?.function ?? "action"}
          </Text>
          <Text color={theme.dim}>
            {"  to ".padEnd(6)}
            {shortAddr(leg.to)}
            {leg.decoded?.contractName ? ` · ${leg.decoded.contractName}` : ""}
            {leg.decoded?.function ? ` · ${leg.decoded.function}` : ""}
          </Text>
          {(leg.decoded?.fields ?? []).map((f: any, j: number) => (
            <Text key={j}>
              {"  "}
              <Text color={theme.dim}>{String(f.label).padEnd(14)}</Text> <Text>{f.formatted}</Text>
            </Text>
          ))}
          {!leg.decoded?.matched && (
            <Text color={theme.dim}>{"  "}(no descriptor matched · raw calldata only)</Text>
          )}
        </Box>
      ))}
      <Box marginTop={1}>
        <Text>
          <Text color={theme.dim}>aggregate simulation: </Text>
          {sim?.simRpcError ? (
            <Text color={theme.warn}>(daemon error)</Text>
          ) : !okSim ? (
            <Text color={theme.err}>✗ would revert</Text>
          ) : (
            <Text color={theme.ok}>✓ would succeed</Text>
          )}
        </Text>
      </Box>
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
      <Box marginTop={1}>
        <Text color={theme.dim}>
          simulation runs the whole executeBatch from the EntryPoint, so
          inter-leg effects (e.g. approve→swap) are reflected. It is
          informational — your confirmation here is the trust anchor.
        </Text>
      </Box>
      {!okSim && !sim?.simRpcError && (
        <Text color={theme.warn}>
          ⚠ Simulation failed. Pressing Enter still broadcasts — only do
          this if you understand why simulation is wrong.
        </Text>
      )}
    </Layout>
  );
}

/** numeric chainId → "sepolia (11155111)"-style badge. */
function chainTag(chainId?: number): string {
  if (chainId === undefined || chainId === null) return "chain (unset)";
  switch (chainId) {
    case 1:
      return "mainnet (1)";
    case 11155111:
      return "sepolia (11155111)";
    default:
      return `chain ${chainId}`;
  }
}

function BatchResult({ result }: { result: any }) {
  const userOpHash = result?.userOpHash ?? "(no hash)";
  const legs = result?.legs;
  return (
    <Box flexDirection="column">
      <Text>
        <Text color={theme.dim}>userOp: </Text>
        {userOpHash}
      </Text>
      {typeof legs === "number" && (
        <Text>
          <Text color={theme.dim}>legs: </Text>
          {legs} actions in one transaction
        </Text>
      )}
      {result?.bundler && (
        <Text>
          <Text color={theme.dim}>bundler: </Text>
          {String(result.bundler)}
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
