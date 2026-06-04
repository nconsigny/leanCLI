import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { Wallet } from "../types.js";
import { Layout, Banner } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";
import { formatEth, hexToBigInt, shortAddr } from "../format.js";
import { TransfersBlock } from "../widgets/TransfersBlock.js";
import { ProvenancePanel } from "../widgets/ProvenancePanel.js";
import UnlockEoaStep from "./UnlockEoaStep.js";

type Props = {
  wallet: Wallet;
  /** The chain the user picked in WalletsHub (mainnet/sepolia for
   *  EOAs, sepolia for TPM). Forwarded to eoa.send / r1.send* so the
   *  daemon's per-chain endpoint override kicks in. Without this the
   *  daemon falls back to cfg.rpcEndpoint (the configured default),
   *  which silently misroutes sepolia testing through the mainnet
   *  endpoint and shows "insufficient funds" because the wallet has
   *  zero balance on whatever the default is. */
  chain?: string;
  /** When set, SendFlow runs as an ERC-20 transfer for this token
   *  instead of a native ETH send. The amount field uses the token's
   *  decimals, calldata is `transfer(to,amount)` encoded by the
   *  daemon via `tx.encodeIntent`, and the broadcast targets
   *  `token.address` with `value = 0`. Native ETH path is unchanged
   *  when this is undefined. */
  token?: { symbol: string; address: string; decimals: number };
  colibriEnabled?: boolean;
  onDone: (success: boolean) => void;
};

/** Encoded calldata for an ERC-20 leg of the flow. Populated by the
 *  simulating step (via `tx.encodeIntent`) and threaded through confirm
 *  + run so the run-time RpcRunner doesn't have to re-encode. */
type EncodedTx = { to: string; value: string; data: string };

type Phase =
  | { kind: "form" }
  | { kind: "resolving"; raw: string; amount: string; pin?: string }
  | {
      kind: "unlocking";
      to: string;
      amount: string;
    }
  | {
      kind: "simulating";
      to: string;
      amount: string;
      pin?: string;
    }
  | {
      kind: "confirm";
      to: string;
      amount: string;
      pin?: string;
      decoded: any;
      sim: any;
      colibri: any;
      /** When set, the run phase broadcasts `encoded` instead of building
       *  a native-ETH `{to, value}` from `amount`. This is how ERC-20
       *  transfers reach `eoa.send` / `r1.sendRawSepolia`. */
      encoded?: EncodedTx;
    }
  | {
      kind: "run";
      to: string;
      amount: string;
      pin?: string;
      encoded?: EncodedTx;
    }
  | { kind: "resolveError"; raw: string; message: string }
  | { kind: "encodeError"; message: string }
  | { kind: "unlockError"; message: string };

const ADDR_RE = /^0x[0-9a-fA-F]{40}$/;

/** Decimal string → base-units bigint. Generalizes the old `ethToWei`
 *  (which hardcoded 18 decimals) so the same conversion serves USDC
 *  (6 decimals), WBTC (8), and the rest of the swap-registry tokens. */
function toBaseUnits(amount: string, decimals: number): bigint {
  const [whole, frac = ""] = amount.split(".");
  const fracPadded = (frac + "0".repeat(decimals)).slice(0, decimals);
  return BigInt(whole || "0") * 10n ** BigInt(decimals) + BigInt(fracPadded || "0");
}

/** Send ETH or an ERC-20 from any wallet. EOA → eoa.send (passphrase
 *  prompt). TPM/R1 → r1.sendEthSepolia for native ETH, r1.sendRawSepolia
 *  for ERC-20 (PIN entered in form; verified by the TPM at sign time).
 *  When `token` is set, calldata is built daemon-side via
 *  `tx.encodeIntent action=erc20Transfer` so amount/decimals are
 *  validated by Lean before any signing path runs. */
export default function SendFlow({ wallet, chain, token, colibriEnabled, onDone }: Props) {
  // Default off; can be overridden via app-level toggle (MainMenu) or the
  // LEANCLI_COLIBRI env seed at startup.
  const useColibri = colibriEnabled ?? false;
  const [phase, setPhase] = useState<Phase>({ kind: "form" });
  const assetLabel = token ? token.symbol : "ETH";

  if (phase.kind === "form") {
    const fields: Field[] = [
      {
        name: "to",
        label: "Recipient (0x… or ENS)",
        placeholder: "0xAa65… or vitalik.eth",
        kind: "recipient",
        excludeAddress: wallet.address,
        validate: (v) =>
          v.length === 0
            ? "required"
            : v.startsWith("0x") && v.length !== 42
              ? "0x address must be 42 chars"
              : null,
      },
      {
        name: "amount",
        label: `Amount (${assetLabel})`,
        placeholder: token ? "10" : "0.01",
        validate: (v) =>
          /^[0-9]+(\.[0-9]+)?$/.test(v)
            ? null
            : `expected a decimal ${assetLabel} amount`,
      },
      // EOA: passphrase no longer captured in this form — the
      // UnlockEoaStep below picks the right path (already-unlocked,
      // master auto-unlock, per-slot passphrase). TPM/R1: PIN still
      // gathered here because the daemon needs it at sign time.
      ...(wallet.kind === "eoa"
        ? []
        : [
            {
              name: "pin",
              label: `TPM PIN for ${wallet.name}`,
              secret: true,
              validate: (v: string) =>
                v.length < 4 ? "at least 4 characters" : null,
            } as Field,
          ]),
    ];
    return (
      <Layout
        title={`Send ${assetLabel} from ${wallet.name}`}
        subtitle={`${shortAddr(wallet.address)} · ${
          wallet.balanceWei !== undefined ? formatEth(wallet.balanceWei) : "…"
        }${token ? ` · token ${token.address}` : ""}`}
      >
        <Form
          fields={fields}
          onCancel={() => onDone(false)}
          onSubmit={(v) => {
            const raw = (v.to ?? "").trim();
            const next = (to: string) =>
              wallet.kind === "eoa"
                ? ({
                    kind: "unlocking",
                    to,
                    amount: v.amount ?? "",
                  } as Phase)
                : ({
                    kind: "simulating",
                    to,
                    amount: v.amount ?? "",
                    pin: v.pin,
                  } as Phase);
            // If the user typed a 0x address, skip ENS resolution. Otherwise
            // resolve before dispatch — the daemon's send paths expect a
            // canonical 20-byte address and reject ENS literals.
            if (ADDR_RE.test(raw)) {
              setPhase(next(raw));
            } else {
              setPhase({
                kind: "resolving",
                raw,
                amount: v.amount ?? "",
                pin: v.pin,
              });
            }
          }}
        />
      </Layout>
    );
  }

  if (phase.kind === "resolving") {
    return (
      <ResolveStep
        raw={phase.raw}
        onResolved={(addr) =>
          setPhase(
            wallet.kind === "eoa"
              ? {
                  kind: "unlocking",
                  to: addr,
                  amount: phase.amount,
                }
              : {
                  kind: "simulating",
                  to: addr,
                  amount: phase.amount,
                  pin: phase.pin,
                },
          )
        }
        onError={(msg) =>
          setPhase({ kind: "resolveError", raw: phase.raw, message: msg })
        }
      />
    );
  }

  if (phase.kind === "resolveError") {
    return (
      <Layout
        title={`Could not resolve ${phase.raw}`}
        hint="esc • back"
      >
        <Banner kind="err" text={phase.message} />
        <BackOnEsc onDone={() => onDone(false)} />
      </Layout>
    );
  }

  if (phase.kind === "unlockError") {
    return (
      <Layout title="Unlock failed" hint="esc • back">
        <Banner kind="err" text={phase.message} />
        <BackOnEsc onDone={() => onDone(false)} />
      </Layout>
    );
  }

  if (phase.kind === "encodeError") {
    return (
      <Layout title="Could not encode ERC-20 transfer" hint="esc • back">
        <Banner kind="err" text={phase.message} />
        <BackOnEsc onDone={() => onDone(false)} />
      </Layout>
    );
  }

  // EOA-only: unlock the slot before simulating. R1/TPM skip this step —
  // the TPM PIN is captured in the form and checked at sign time.
  // UnlockEoaStep handles the four cases (already unlocked, master
  // auto-unlock, per-slot passphrase, master-locked-and-enrolled).
  if (phase.kind === "unlocking") {
    return (
      <UnlockEoaStep
        wallet={wallet}
        onUnlocked={() =>
          setPhase({
            kind: "simulating",
            to: phase.to,
            amount: phase.amount,
          })
        }
        onCancel={() => onDone(false)}
      />
    );
  }

  // Pre-sign clear-signing gate. Runs for BOTH EOA and R1/TPM — every
  // signed tx flows through this gate (ERC-7730 phase 2). For native ETH
  // transfers calldata is "0x" so the descriptor returns no match (correct);
  // for ERC-20 transfers the descriptor will match (ERC-20 transfer is in
  // the registry); the simulator runs against the encoded calldata so the
  // user sees the actual token movement that would happen on chain.
  if (phase.kind === "simulating") {
    return (
      <SimulateStep
        from={wallet.address}
        to={phase.to}
        amount={phase.amount}
        chain={chain}
        token={token}
        useColibri={useColibri}
        onResult={(decoded, sim, colibri, encoded) =>
          setPhase({
            kind: "confirm",
            to: phase.to,
            amount: phase.amount,
            pin: phase.pin,
            decoded,
            sim,
            colibri,
            encoded,
          })
        }
        onEncodeError={(msg) =>
          setPhase({ kind: "encodeError", message: msg })
        }
      />
    );
  }

  if (phase.kind === "confirm") {
    return (
      <ConfirmGate
        title={`Confirm: send ${phase.amount} ${assetLabel} from ${wallet.name}${
          wallet.kind === "eoa" ? "" : " (TPM/R1)"
        }`}
        subtitle={
          wallet.kind === "eoa"
            ? `to ${phase.to}`
            : `to ${phase.to} · PIN will be checked by the TPM`
        }
        decoded={phase.decoded}
        sim={phase.sim}
        colibri={phase.colibri}
        onConfirm={() =>
          setPhase({
            kind: "run",
            to: phase.to,
            amount: phase.amount,
            pin: phase.pin,
            encoded: phase.encoded,
          })
        }
        onCancel={() => onDone(false)}
      />
    );
  }

  // phase.kind === "run" — actually broadcast. The slot is already unlocked
  // (EOA) or the PIN is captured in `phase.pin` (R1/TPM) for the daemon
  // to forward to the TPM auth check.
  if (wallet.kind === "eoa") {
    // Pass the sub-account index when the picker handed us a derived
    // wallet — the daemon's `resolveAccount` then signs from that branch
    // instead of the slot's primary. Primaries (index 0 or undefined)
    // intentionally omit the field for backward compatibility.
    const subAcct = (wallet.accountIndex ?? 0) > 0 ? wallet.accountIndex : undefined;
    const titleSuffix =
      subAcct !== undefined
        ? ` · account #${subAcct}${wallet.accountLabel ? ` (${wallet.accountLabel})` : ""}`
        : "";
    // ERC-20 path: broadcast the encoded `transfer(to,amount)` calldata
    // through eoa.send with `to = token.address`, `value = 0`. The encoder
    // ran daemon-side via tx.encodeIntent so amount/decimals are already
    // validated by Lean. Native ETH path: value = wei, data = 0x (handled
    // by eoa.send's default).
    const params: Record<string, unknown> = phase.encoded
      ? {
          name: wallet.name,
          to: phase.encoded.to,
          value: 0,
          data: phase.encoded.data,
        }
      : {
          name: wallet.name,
          to: phase.to,
          value: toBaseUnits(phase.amount, 18),
        };
    if (chain) params.chain = chain;
    if (subAcct !== undefined) params.account = subAcct;
    return (
      <RpcRunner
        title={`Sending ${phase.amount} ${assetLabel} from ${wallet.name}${titleSuffix}`}
        subtitle={`${chain ? `${chain} · ` : ""}to ${phase.to}`}
        method="eoa.send"
        params={params}
        renderResult={(r) => <SendResult result={r} assetLabel={assetLabel} />}
        onDone={onDone}
      />
    );
  }
  // TPM/R1: native ETH → r1.sendEthSepolia (the ergonomic wrapper that
  // accepts a decimal ETH amount string). ERC-20 → r1.sendRawSepolia
  // with the encoded calldata, since the dedicated ETH wrapper has no
  // data slot.
  if (phase.encoded) {
    return (
      <RpcRunner
        title={`Sending ${phase.amount} ${assetLabel} from ${wallet.name} (TPM/R1)`}
        subtitle={`${chain ? `${chain} · ` : ""}to ${phase.to} · TPM PIN will be checked at sign time`}
        method="r1.sendRawSepolia"
        params={{
          name: wallet.name,
          to: phase.encoded.to,
          value: "0x0",
          data: phase.encoded.data,
          pin: phase.pin ?? "",
        }}
        renderResult={(r) => <SendResult result={r} assetLabel={assetLabel} />}
        onDone={onDone}
      />
    );
  }
  return (
    <RpcRunner
      title={`Sending ${phase.amount} ETH from ${wallet.name} (TPM/R1)`}
      subtitle={`${chain ? `${chain} · ` : ""}to ${phase.to} · TPM PIN will be checked at sign time`}
      method="r1.sendEthSepolia"
      params={{
        name: wallet.name,
        to: phase.to,
        amountEth: phase.amount,
        pin: phase.pin ?? "",
      }}
      renderResult={(r) => <SendResult result={r} assetLabel={assetLabel} />}
      onDone={onDone}
    />
  );
}

// Colibri stateless simulation is opt-in (cold-start can take several
// seconds for the sync committee bootstrap). When `useColibri` is true,
// `tx.simulateColibri` runs in parallel with the existing untrusted-RPC
// path. The Colibri output is a second, consensus-verified witness
// rendered alongside (not replacing) the existing simulation panel.
function SimulateStep({
  from,
  to,
  amount,
  chain,
  token,
  useColibri,
  onResult,
  onEncodeError,
}: {
  from: string;
  to: string;
  amount: string;
  /** Chain name ("sepolia" / "mainnet" / …). Drives BOTH `chainId`
   *  (the integer the decoder + tx-meta consumer expects) and `chain`
   *  (the name string the daemon looks up in cfg.chainEndpoints).
   *  Passing only chainId leaves endpoint.chainId=none on the daemon
   *  side → policy denies as "chainId=unknown". */
  chain?: string;
  token?: { symbol: string; address: string; decimals: number };
  useColibri: boolean;
  onResult: (decoded: any, sim: any, colibri: any, encoded?: EncodedTx) => void;
  onEncodeError: (msg: string) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    // Supported chains: mainnet + sepolia only. Anything else
    // historically defaulted to sepolia (the previous hardcode).
    const chainIdNum =
      chain === "mainnet" ? 1 :
      chain === "sepolia" ? 11155111 :
      11155111;
    void (async () => {
      // ERC-20 path: encode `transfer(to,amount)` via tx.encodeIntent
      // before running the simulator. This way both tx.decodeIntent and
      // tx.simulate see the real calldata that will be signed — not
      // `data: "0x"` — so the descriptor matches and the simulator
      // catches insufficient-balance / non-existent-token / fee-on-
      // transfer cases pre-sign. amountBase is computed token-side here
      // (TUI input is a decimal string); the daemon's parser re-validates.
      let txTo = to;
      let txValueHex = "0x0";
      let txData = "0x";
      let encoded: EncodedTx | undefined;
      if (token) {
        const amountBase = toBaseUnits(amount, token.decimals);
        const enc = await call<{ to: string; value: number; data: string }>(
          "tx.encodeIntent",
          {
            action: "erc20Transfer",
            chainId: chainIdNum,
            token: token.address,
            decimals: token.decimals,
            to,
            // Daemon's IntentJson.parseIntent accepts a numeric string for
            // the base-units amount — bigint values lose precision through
            // JSON.stringify, so we always send a decimal string.
            amount: amountBase.toString(),
          },
        );
        if (cancelled) return;
        if (!enc.ok) {
          onEncodeError(`tx.encodeIntent failed: ${enc.error.message}`);
          return;
        }
        const r = enc.result;
        if (!r || typeof r.to !== "string" || typeof r.data !== "string") {
          onEncodeError("tx.encodeIntent returned an unexpected shape");
          return;
        }
        encoded = { to: r.to, value: "0x0", data: r.data };
        txTo = r.to;
        txValueHex = "0x0";
        txData = r.data;
      } else {
        // Native ETH: 18-decimal conversion, no data.
        const wei = toBaseUnits(amount, 18);
        txValueHex = "0x" + wei.toString(16);
      }
      const tx = {
        chainId: chainIdNum,
        // Pass `chain` too so the daemon picks the right per-chain
        // endpoint instead of cfg.rpcEndpoint (which has chainId=none).
        ...(chain ? { chain } : {}),
        to: txTo,
        value: txValueHex,
        data: txData,
        from,
      };
      const [d, s, c] = await Promise.all([
        call<any>("tx.decodeIntent", tx),
        call<any>("tx.simulate", { ...tx, block: "latest", trace: true }),
        useColibri
          ? call<any>("tx.simulateColibri", { ...tx, block: "latest" })
          : Promise.resolve({ ok: true, result: null } as any),
      ]);
      if (cancelled) return;
      const decoded = d.ok ? (d.result?.result ?? d.result) : { matched: false };
      const sim = s.ok ? s.result : { ok: false, simRpcError: s.error.message };
      // Colibri response is wrapped: { ok: true, result: <SimResult> }
      // (matches the responseToJson shape from the bridge module).
      const colibri = !useColibri
        ? null
        : c.ok && c.result?.ok
          ? c.result.result
          : c.ok
            ? { error: c.result?.error?.message ?? "colibri unavailable" }
            : { error: c.error.message };
      onResult(decoded, sim, colibri, encoded);
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
        <Text color={theme.dim}>
          {token
            ? `encoding ERC-20 transfer + simulating against the RPC node`
            : "simulating transaction against the RPC node"}
          {useColibri ? " + Colibri stateless light client" : ""}…
        </Text>
      </Text>
    </Layout>
  );
}

/** Pre-sign confirmation. Renders the decoded intent + simulated effect
 *  together; Enter advances to signing, Esc cancels. The user is looking at
 *  ground truth (RPC simulation) rather than the form they typed. */
function ConfirmGate({
  title,
  subtitle,
  decoded,
  sim,
  colibri,
  onConfirm,
  onCancel,
}: {
  title: string;
  subtitle: string;
  decoded: any;
  sim: any;
  colibri?: any;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  useInput((_, key) => {
    if (key.return) onConfirm();
    if (key.escape) onCancel();
  });
  const okSim = sim?.ok === true;
  const matched = decoded?.matched === true;
  return (
    <Layout
      title={title}
      subtitle={subtitle}
      hint="enter — sign & broadcast · esc — cancel"
    >
      <ProvenancePanel
        title="intent"
        tier="local"
        source={
          matched
            ? [
                "ERC-7730 descriptor from bundled registry — bridge/clearsign/registry/*.json",
                "calldata decoded against descriptor ABI in the clearsign sidecar (untrusted; UI-render only)",
                "token decimals/symbol via eth_call(decimals)/eth_call(symbol) — untrusted RPC (cached)",
              ]
            : ["native ETH transfer · data = 0x · no descriptor needed (resolved locally)"]
        }
      >
        {matched ? (
          <>
            <Text>
              <Text color={theme.primary} bold>
                {decoded.intent ?? "(no intent)"}
              </Text>
            </Text>
            <Text color={theme.dim}>
              {decoded.contractName ?? "(contract)"} · {decoded.function}
            </Text>
            {(decoded.fields ?? []).map((f: any, i: number) => (
              <Text key={i}>
                <Text color={theme.dim}>{f.label.padEnd(14)}</Text>{" "}
                <Text>{f.formatted}</Text>
              </Text>
            ))}
          </>
        ) : (
          <Text color={theme.dim}>
            no descriptor matched · native ETH transfer (data = 0x)
          </Text>
        )}
      </ProvenancePanel>
      <ProvenancePanel
        title="simulation"
        tier="remote"
        source={sendFlowSimSourceLines(sim)}
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
          <Box flexDirection="column">
            <Text color={theme.err}>revert: {String(sim.revertReason).slice(0, 200)}</Text>
          </Box>
        )}
        {sim?.simRpcError && (
          <Text color={theme.dim}>{sim.simRpcError}</Text>
        )}
        <TransfersBlock sim={sim} />
      </ProvenancePanel>
      {colibri && <ColibriBlock colibri={colibri} />}
      {!okSim && !sim?.simRpcError && (
        <Text color={theme.warn}>
          ⚠ Simulation failed. Pressing Enter will still broadcast — only
          do this if you understand why simulation is wrong.
        </Text>
      )}
    </Layout>
  );
}

/** Colibri stateless verification panel. Rendered alongside (not in
 *  place of) the untrusted-RPC simulation block — two independent
 *  witnesses. status === "0x1" means the EVM run by Colibri's WASM
 *  succeeded; logs come pre-decoded with ABI from Colibri. */
function ColibriBlock({ colibri }: { colibri: any }) {
  if (!colibri) return null;
  if (colibri.error) {
    return (
      <ProvenancePanel
        title="colibri stateless verification"
        tier="verified"
        source="LeanCli/Colibri/Bridge.lean — stateless light-client EVM (consensus-verified state)"
      >
        <Text color={theme.dim}>
          <Text color={theme.warn}>unavailable</Text>{" "}
          <Text color={theme.dim}>· {String(colibri.error).slice(0, 120)}</Text>
        </Text>
      </ProvenancePanel>
    );
  }
  const ok = colibri.status === "0x1";
  const gas = (() => {
    try {
      return BigInt(colibri.gasUsed ?? "0x0").toString();
    } catch {
      return String(colibri.gasUsed ?? "");
    }
  })();
  const logs: any[] = Array.isArray(colibri.logs) ? colibri.logs : [];
  return (
    <ProvenancePanel
      title="colibri stateless verification"
      tier="verified"
      source={[
        "LeanCli/Colibri/Bridge.lean — stateless light-client EVM",
        "execution re-run locally under WASM EVM against sync-committee-verified state — independent of the untrusted RPC",
        "logs pre-decoded with ABIs shipped by the colibri sidecar",
      ]}
    >
      <Text>
        <Text color={theme.dim}>result: </Text>
        {ok ? (
          <Text color={theme.ok}>✓ would succeed</Text>
        ) : (
          <Text color={theme.err}>✗ would revert</Text>
        )}
        <Text color={theme.dim}> · gas {gas}</Text>
      </Text>
      {logs.length > 0 && (
        <Box flexDirection="column" marginLeft={2}>
          {logs.slice(0, 6).map((log, i) => (
            <Text key={i}>
              <Text color={theme.dim}>log {i}: </Text>
              <Text>{log.name ?? "(unknown)"}</Text>
              <Text color={theme.dim}>
                {log.inputs && log.inputs.length > 0
                  ? "(" +
                    log.inputs
                      .map((inp: any) => `${inp.name}=${inp.value}`)
                      .join(", ")
                      .slice(0, 100) +
                    ")"
                  : ""}
              </Text>
            </Text>
          ))}
          {logs.length > 6 && (
            <Text color={theme.dim}>… {logs.length - 6} more logs</Text>
          )}
        </Box>
      )}
    </ProvenancePanel>
  );
}

/** Build the `source:` footer lines for the simulation panel in SendFlow.
 *  Same shape as the SendRawFlow helper but kept local to avoid a
 *  circular dependency between the two screens. */
function sendFlowSimSourceLines(sim: any): string[] {
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

function ResolveStep({
  raw,
  onResolved,
  onError,
}: {
  raw: string;
  onResolved: (addr: string) => void;
  onError: (msg: string) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    call<{ address?: string }>("chain.resolveName", { name: raw }).then((r) => {
      if (cancelled) return;
      if (!r.ok) return onError(`ENS resolve failed: ${r.error.message}`);
      const addr = r.result?.address;
      if (!addr || !ADDR_RE.test(addr)) {
        return onError(`ENS '${raw}' did not resolve to a 0x address`);
      }
      onResolved(addr);
    });
    return () => {
      cancelled = true;
    };
  }, []);
  return (
    <Layout title={`Resolving ${raw}…`}>
      <Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>asking the daemon to resolve ENS</Text>
      </Text>
    </Layout>
  );
}

function BackOnEsc({ onDone }: { onDone: () => void }) {
  useInput((_, key) => {
    if (key.return || key.escape) onDone();
  });
  return null;
}

function SendResult({ result, assetLabel }: { result: any; assetLabel?: string }) {
  // Note: every row is its own <Text> wrapped in a <Box flexDirection="column">
  // so React fragments don't collapse multiple lines onto one row.
  const txHash = result?.txHash ?? "(no hash)";
  const status = result?.status ?? "(unknown)";
  const blockN = hexToBigInt(result?.blockNumber);
  const gasUsed = hexToBigInt(result?.gasUsed);
  const effPrice = hexToBigInt(result?.effectiveGasPrice);
  // `valueWei` is the *native* ETH carried by the tx — zero for ERC-20
  // transfers (the token amount lives in `data`). Showing the formatted
  // ETH amount only when value > 0 keeps the ERC-20 result clean; the
  // ConfirmGate already showed the asset+amount the user signed for.
  const valueWei =
    typeof result?.valueWei === "string"
      ? (() => {
          try {
            return BigInt(result.valueWei);
          } catch {
            return 0n;
          }
        })()
      : 0n;
  const isErc20 = assetLabel !== undefined && assetLabel !== "ETH";
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
      {isErc20 && (
        <Text>
          <Text color={theme.dim}>asset: </Text>
          {assetLabel}
        </Text>
      )}
      {valueWei > 0n && (
        <Text>
          <Text color={theme.dim}>value: </Text>
          {formatEth(valueWei)}
        </Text>
      )}
      {blockN > 0n && (
        <Text>
          <Text color={theme.dim}>block: </Text>
          {blockN.toString()}
        </Text>
      )}
      {gasUsed > 0n && (
        <Text>
          <Text color={theme.dim}>gas:   </Text>
          {gasUsed.toString()}{" "}
          <Text color={theme.dim}>
            ({Number(effPrice) / 1e9} gwei)
          </Text>
        </Text>
      )}
      <Text color={theme.dim}>
        https://sepolia.etherscan.io/tx/{txHash}
      </Text>
    </Box>
  );
}
