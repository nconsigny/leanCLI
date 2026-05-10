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

type Props = {
  wallet: Wallet;
  colibriEnabled?: boolean;
  onDone: (success: boolean) => void;
};

type Phase =
  | { kind: "form" }
  | { kind: "resolving"; raw: string; amountEth: string; passphrase?: string }
  | {
      kind: "unlocking";
      to: string;
      amountEth: string;
      passphrase: string;
    }
  | {
      kind: "simulating";
      to: string;
      amountEth: string;
      passphrase?: string;
    }
  | {
      kind: "confirm";
      to: string;
      amountEth: string;
      passphrase?: string;
      decoded: any;
      sim: any;
      colibri: any;
    }
  | {
      kind: "run";
      to: string;
      amountEth: string;
      passphrase?: string;
    }
  | { kind: "resolveError"; raw: string; message: string }
  | { kind: "unlockError"; message: string };

const ADDR_RE = /^0x[0-9a-fA-F]{40}$/;

function ethToWei(amountEth: string): bigint {
  const [whole, frac = ""] = amountEth.split(".");
  const fracPadded = (frac + "0".repeat(18)).slice(0, 18);
  return BigInt(whole || "0") * 10n ** 18n + BigInt(fracPadded || "0");
}

/** Send ETH from any wallet. EOA → eoa.send (passphrase prompt). TPM/R1 →
 *  r1.sendEthSepolia (biometric prompt streamed via notifications). */
export default function SendFlow({ wallet, colibriEnabled, onDone }: Props) {
  // Default off; can be overridden via app-level toggle (MainMenu) or the
  // KOHAKU_COLIBRI env seed at startup.
  const useColibri = colibriEnabled ?? false;
  const [phase, setPhase] = useState<Phase>({ kind: "form" });

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
        name: "amountEth",
        label: "Amount (ETH)",
        placeholder: "0.01",
        validate: (v) =>
          /^[0-9]+(\.[0-9]+)?$/.test(v) ? null : "expected a decimal ETH amount",
      },
      ...(wallet.kind === "eoa"
        ? [
            {
              name: "passphrase",
              label: `Passphrase for ${wallet.name}`,
              secret: true,
              validate: (v: string) => (v.length === 0 ? "required" : null),
            } as Field,
          ]
        : []),
    ];
    return (
      <Layout
        title={`Send from ${wallet.name}`}
        subtitle={`${shortAddr(wallet.address)} · ${
          wallet.balanceWei !== undefined ? formatEth(wallet.balanceWei) : "…"
        }`}
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
                    amountEth: v.amountEth ?? "",
                    passphrase: v.passphrase ?? "",
                  } as Phase)
                : ({
                    kind: "simulating",
                    to,
                    amountEth: v.amountEth ?? "",
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
                amountEth: v.amountEth ?? "",
                passphrase: v.passphrase,
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
                  amountEth: phase.amountEth,
                  passphrase: phase.passphrase ?? "",
                }
              : {
                  kind: "simulating",
                  to: addr,
                  amountEth: phase.amountEth,
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

  // EOA-only: unlock the slot before simulating. R1/TPM skip this step —
  // biometric is gated by the daemon at signing time.
  if (phase.kind === "unlocking") {
    return (
      <UnlockStep
        wallet={wallet}
        passphrase={phase.passphrase}
        onUnlocked={() =>
          setPhase({
            kind: "simulating",
            to: phase.to,
            amountEth: phase.amountEth,
            passphrase: phase.passphrase,
          })
        }
        onError={(msg) => setPhase({ kind: "unlockError", message: msg })}
      />
    );
  }

  // Pre-sign clear-signing gate. Runs for BOTH EOA and R1/TPM — every
  // signed tx flows through this gate (ERC-7730 phase 2). For native ETH
  // transfers calldata is "0x" so the descriptor returns no match (correct);
  // the simulator still tells us would-revert / gas / transfers.
  if (phase.kind === "simulating") {
    return (
      <SimulateStep
        from={wallet.address}
        to={phase.to}
        amountEth={phase.amountEth}
        useColibri={useColibri}
        onResult={(decoded, sim, colibri) =>
          setPhase({
            kind: "confirm",
            to: phase.to,
            amountEth: phase.amountEth,
            passphrase: phase.passphrase,
            decoded,
            sim,
            colibri,
          })
        }
      />
    );
  }

  if (phase.kind === "confirm") {
    return (
      <ConfirmGate
        title={`Confirm: send ${phase.amountEth} ETH from ${wallet.name}${
          wallet.kind === "eoa" ? "" : " (TPM/R1)"
        }`}
        subtitle={
          wallet.kind === "eoa"
            ? `to ${phase.to}`
            : `to ${phase.to} · biometric verification will be requested`
        }
        decoded={phase.decoded}
        sim={phase.sim}
        colibri={phase.colibri}
        onConfirm={() =>
          setPhase({
            kind: "run",
            to: phase.to,
            amountEth: phase.amountEth,
            passphrase: phase.passphrase,
          })
        }
        onCancel={() => onDone(false)}
      />
    );
  }

  // phase.kind === "run" — actually broadcast. The slot is already unlocked
  // (EOA) or about to prompt the user for biometric (R1/TPM).
  if (wallet.kind === "eoa") {
    const wei = ethToWei(phase.amountEth);
    // Pass the sub-account index when the picker handed us a derived
    // wallet — the daemon's `resolveAccount` then signs from that branch
    // instead of the slot's primary. Primaries (index 0 or undefined)
    // intentionally omit the field for backward compatibility.
    const subAcct = (wallet.accountIndex ?? 0) > 0 ? wallet.accountIndex : undefined;
    const titleSuffix =
      subAcct !== undefined
        ? ` · account #${subAcct}${wallet.accountLabel ? ` (${wallet.accountLabel})` : ""}`
        : "";
    return (
      <RpcRunner
        title={`Sending ${phase.amountEth} ETH from ${wallet.name}${titleSuffix}`}
        subtitle={`to ${phase.to}`}
        method="eoa.send"
        params={{
          name: wallet.name,
          to: phase.to,
          value: wei,
          ...(subAcct !== undefined ? { account: subAcct } : {}),
        }}
        renderResult={(r) => <SendResult result={r} />}
        onDone={onDone}
      />
    );
  }
  return (
    <RpcRunner
      title={`Sending ${phase.amountEth} ETH from ${wallet.name} (TPM/R1)`}
      subtitle={`to ${phase.to} · biometric verification will be requested`}
      method="r1.sendEthSepolia"
      params={{
        name: wallet.name,
        to: phase.to,
        amountEth: phase.amountEth,
      }}
      renderResult={(r) => <SendResult result={r} />}
      onDone={onDone}
    />
  );
}

function UnlockStep({
  wallet,
  passphrase,
  onUnlocked,
  onError,
}: {
  wallet: Wallet;
  passphrase: string;
  onUnlocked: () => void;
  onError: (msg: string) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    call("eoa.unlock", { name: wallet.name, passphrase }).then((r) => {
      if (cancelled) return;
      if (!r.ok) return onError(`${r.error.message} (code ${r.error.code})`);
      onUnlocked();
    });
    return () => {
      cancelled = true;
    };
  }, []);
  return (
    <Layout title={`Unlocking ${wallet.name}…`}>
      <Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>verifying passphrase</Text>
      </Text>
    </Layout>
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
  amountEth,
  useColibri,
  onResult,
}: {
  from: string;
  to: string;
  amountEth: string;
  useColibri: boolean;
  onResult: (decoded: any, sim: any, colibri: any) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    const wei = ethToWei(amountEth);
    const valueHex = "0x" + wei.toString(16);
    const tx = {
      chainId: 11155111,
      to,
      value: valueHex,
      data: "0x",
      from,
    };
    Promise.all([
      call<any>("tx.decodeIntent", tx),
      call<any>("tx.simulate", { ...tx, block: "latest", trace: true }),
      useColibri
        ? call<any>("tx.simulateColibri", { ...tx, block: "latest" })
        : Promise.resolve({ ok: true, result: null } as any),
    ]).then(([d, s, c]) => {
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
      onResult(decoded, sim, colibri);
    });
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
          simulating transaction against the RPC node
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
      <Box flexDirection="column" marginBottom={1}>
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
          <Box flexDirection="column">
            <Text color={theme.err}>revert: {String(sim.revertReason).slice(0, 200)}</Text>
          </Box>
        )}
        {sim?.simRpcError && (
          <Text color={theme.dim}>{sim.simRpcError}</Text>
        )}
        <TransfersBlock sim={sim} />
      </Box>
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
      <Box flexDirection="column" marginBottom={1}>
        <Text color={theme.dim}>
          colibri (verified): <Text color={theme.warn}>unavailable</Text>{" "}
          <Text color={theme.dim}>· {String(colibri.error).slice(0, 120)}</Text>
        </Text>
      </Box>
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
    <Box flexDirection="column" marginBottom={1}>
      <Text>
        <Text color={theme.dim}>colibri (verified): </Text>
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
    </Box>
  );
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

function SendResult({ result }: { result: any }) {
  // Note: every row is its own <Text> wrapped in a <Box flexDirection="column">
  // so React fragments don't collapse multiple lines onto one row.
  const txHash = result?.txHash ?? "(no hash)";
  const status = result?.status ?? "(unknown)";
  const blockN = hexToBigInt(result?.blockNumber);
  const gasUsed = hexToBigInt(result?.gasUsed);
  const effPrice = hexToBigInt(result?.effectiveGasPrice);
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
