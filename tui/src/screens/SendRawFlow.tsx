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
import { TransfersBlock } from "../widgets/TransfersBlock.js";

/** A pre-selected signing wallet. Threaded in by callers (e.g. SwapFlow)
 *  who already know which wallet is active — skips the EOA picker and
 *  routes TPM/R1 wallets to the TPM-PIN path. */
export type SendRawWallet = {
  kind: "eoa" | "tpm";
  name: string;
  address: string;
};

type Props = {
  /** The unsigned tx the caller (e.g. LlmDraftFlow) wants signed. */
  tx: { to: string; value: string; data: string; rationale?: string };
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
  | { kind: "passphrase"; wallet: EoaSlot }
  | { kind: "pin"; wallet: EoaSlot }
  | { kind: "unlock-error"; message: string }
  | {
      kind: "simulate";
      wallet: EoaSlot;
      passphrase: string;
      pin: string;
      tpm: boolean;
    }
  | {
      kind: "confirm";
      wallet: EoaSlot;
      passphrase: string;
      pin: string;
      decoded: any;
      sim: any;
      tpm: boolean;
    }
  | {
      kind: "send";
      wallet: EoaSlot;
      passphrase: string;
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
        ? { kind: "passphrase", wallet: { name: wallet.name, address: wallet.address } }
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
            if (w) setPhase({ kind: "passphrase", wallet: w });
          }}
        />
      </Layout>
    );
  }

  if (phase.kind === "passphrase") {
    const fields: Field[] = [
      {
        name: "passphrase",
        label: `Passphrase for ${phase.wallet.name}`,
        secret: true,
        validate: (v) => (v.length === 0 ? "required" : null),
      },
    ];
    return (
      <Layout
        title={`Unlock ${phase.wallet.name}`}
        subtitle={`address: ${phase.wallet.address}`}
      >
        <Form
          fields={fields}
          onCancel={() => onDone(false)}
          onSubmit={(v) =>
            setPhase({
              kind: "simulate",
              wallet: phase.wallet,
              passphrase: v.passphrase ?? "",
              pin: "",
              tpm: false,
            })
          }
        />
      </Layout>
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
              passphrase: "",
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
      <UnlockAndSimulate
        wallet={phase.wallet}
        passphrase={phase.passphrase}
        tpm={phase.tpm}
        tx={tx}
        chainId={chainId}
        onError={(message) => setPhase({ kind: "unlock-error", message })}
        onReady={(decoded, sim) =>
          setPhase({
            kind: "confirm",
            wallet: phase.wallet,
            passphrase: phase.passphrase,
            pin: phase.pin,
            decoded,
            sim,
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
        tpm={phase.tpm}
        onConfirm={() =>
          setPhase({
            kind: "send",
            wallet: phase.wallet,
            passphrase: phase.passphrase,
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
  if (phase.tpm) {
    return (
      <RpcRunner
        title={`Sending tx as ${phase.wallet.name} (TPM/R1)`}
        subtitle={`to ${tx.to} · TPM PIN will be checked at sign time`}
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
      subtitle={`to ${tx.to} · value ${tx.value}`}
      method="eoa.send"
      params={{
        name: phase.wallet.name,
        to: tx.to,
        value: hexToBigInt(tx.value),
        data: tx.data,
      }}
      renderResult={(r) => <RawResult result={r} />}
      onDone={onDone}
    />
  );
}

function UnlockAndSimulate({
  wallet,
  passphrase,
  tpm,
  tx,
  chainId,
  onError,
  onReady,
}: {
  wallet: EoaSlot;
  passphrase: string;
  tpm: boolean;
  tx: Props["tx"];
  chainId?: number;
  onError: (msg: string) => void;
  onReady: (decoded: any, sim: any) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    (async () => {
      // Unlock first (EOA only); if it fails, no point in simulating.
      // TPM/R1 wallets carry the PIN in params and authorize at sign time.
      if (!tpm) {
        const u = await call<any>("eoa.unlock", { name: wallet.name, passphrase });
        if (cancelled) return;
        if (!u.ok) return onError(`unlock: ${u.error.message}`);
      }

      // Decode + simulate in parallel, exactly like the manual decode
      // screen does.
      const [d, s] = await Promise.all([
        call<any>("tx.decodeIntent", {
          chainId: chainId ?? 1,
          to: tx.to,
          value: tx.value,
          data: tx.data,
          from: wallet.address,
        }),
        call<any>("tx.simulate", {
          chainId: chainId ?? 1,
          to: tx.to,
          value: tx.value,
          data: tx.data,
          from: wallet.address,
          block: "latest",
          trace: true,
        }),
      ]);
      if (cancelled) return;
      const decoded = d.ok ? d.result?.result ?? d.result : { matched: false };
      const sim = s.ok ? s.result : { ok: false, simRpcError: s.error.message };
      onReady(decoded, sim);
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
  tpm,
  onConfirm,
  onCancel,
}: {
  wallet: EoaSlot;
  tx: Props["tx"];
  decoded: any;
  sim: any;
  tpm: boolean;
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
      title={`Confirm: sign as ${wallet.name}${tpm ? " (TPM/R1)" : ""}`}
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
      <Box flexDirection="column" marginBottom={1}>
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
      </Box>
      <Box flexDirection="column" marginBottom={1}>
        <Text>
          <Text color={theme.dim}>simulation: </Text>
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
      </Box>
      {!okSim && !sim?.simRpcError && (
        <Text color={theme.warn}>
          ⚠ Simulation failed. Pressing Enter will still broadcast — only
          do this if you understand why simulation is wrong.
        </Text>
      )}
    </Layout>
  );
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
