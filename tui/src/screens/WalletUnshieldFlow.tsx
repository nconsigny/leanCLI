import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { call } from "../daemon.js";
import { Layout, Banner } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import Select from "../widgets/Select.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { theme } from "../theme.js";
import { Wallet } from "../types.js";
import { formatEth, hexToBigInt } from "../format.js";
import UnlockEoaStep from "./UnlockEoaStep.js";

type Protocol = "pp" | "railgun" | "tornado";
type RecipientSource = "derive" | "book" | "paste";

function protoName(p: Protocol): string {
  return p === "railgun" ? "Railgun" : p === "tornado" ? "Tornado Cash" : "Privacy Pools";
}

/** Tornado runs on mainnet too, but this pane pins Sepolia to match the
 *  rest of the dashboard — mainnet tornado stays on the CLI / chat paths. */
const TORNADO_CHAIN_ID = 11155111;

/** Tornado withdrawals spend exactly one fixed-denomination note per call
 *  (multi-note drains are one denomination per call), or "max" = the
 *  largest spendable note. */
function isTornadoWithdrawAmount(v: string): boolean {
  const t = v.trim().toLowerCase();
  return t === "max" || /^(0\.1|1|10|100)$/.test(t);
}

/** Privacy Pools v1 immutable 7702 delegate contract (Railgun's paymaster
 *  only sponsors UserOps that delegate to this IMPL). Shown in the Railgun
 *  unshield confirm so the user sees what their EOA is delegating to. */
const RAILGUN_7702_IMPL = "0x304a6c5fB6F09f5B79b4F38913dB35d2F40b4b4c";

/** Relayer quote returned by `shielded.quoteUnshield`. Every wei field is a
 *  0x-hex string (the bridge's jsonReplacer); feeBPS/gasPrice are plain
 *  decimal strings from the relayer. */
export type UnshieldQuote = {
  recipient: string;
  requestedWei: string;
  chunkWei: string;
  multiRelay: boolean;
  approvedTotalWei: string;
  feeBPS?: string | null;
  baseFeeBPS?: string | null;
  gasPriceWei?: string | null;
  relayTxCostWei?: string | null;
  relayFeeBps?: string | null;
  relayerId?: string | null;
  estimatedGasFeeWei?: string | null;
  unshieldFeeBps?: number | null;
  /* tornado paymaster quote (shielded.tornado.quoteWithdraw) */
  paymasterFeeWei?: string | null;
  netWei?: string | null;
  denominationWei?: string | null;
  spendableTotalWei?: string | null;
  matchingNoteCount?: number | null;
};

type BookEntry = {
  label: string;
  address: string;
  source: string;
  ensName?: string | null;
  tag?: string | null;
};

type AccountListEntry = { index: number; path: string; address: string; label?: string | null };

type Phase =
  | { kind: "pickProtocol" }
  | { kind: "pickSource"; protocol: Protocol }
  /* paste path */
  | { kind: "paste"; protocol: Protocol }
  /* book path */
  | { kind: "book-loading"; protocol: Protocol }
  | { kind: "book-empty"; protocol: Protocol }
  | { kind: "book-pick"; protocol: Protocol; entries: BookEntry[] }
  /* derive-on-this-wallet path */
  | { kind: "derive-prep"; protocol: Protocol }
  | { kind: "derive-running"; nextIdx: number; protocol: Protocol; label?: string }
  | { kind: "derive-form"; nextIdx: number; protocol: Protocol }
  | { kind: "derive-error"; message: string; protocol: Protocol }
  /* amount entry (post-recipient) */
  | {
      kind: "amount";
      protocol: Protocol;
      recipient: string;
      source: RecipientSource;
    }
  /* Railgun/Tornado: EOA unlock between amount and broadcast (both root
     their note keystores in the wallet seed) */
  | {
      kind: "unlock";
      protocol: "railgun" | "tornado";
      recipient: string;
      source: RecipientSource;
      amountEth: string;
    }
  | {
      kind: "railgun-max";
      recipient: string;
      source: RecipientSource;
    }
  /* Tornado: paymaster fee quote (no proof, no broadcast) before the gate */
  | {
      kind: "tornado-quote";
      recipient: string;
      source: RecipientSource;
      amountEth: string;
    }
  /* PP: fetch a relayer fee quote (no broadcast) before the confirm gate */
  | {
      kind: "quote";
      protocol: "pp";
      recipient: string;
      source: RecipientSource;
      amountEth: string;
      passphrase: string;
    }
  /* pre-broadcast confirm gate (recipient / amount / fee / disclosures) */
  | {
      kind: "confirm";
      protocol: Protocol;
      recipient: string;
      source: RecipientSource;
      amountEth: string;
      passphrase?: string;
      quote?: UnshieldQuote;
    }
  | { kind: "quote-error"; protocol: Protocol; message: string }
  /* dispatch */
  | {
      kind: "running";
      protocol: Protocol;
      recipient: string;
      source: RecipientSource;
      amountEth: string;
      passphrase?: string;
      /* tornado: the confirmed quote's paymasterFeeWei is forwarded as the
         maxFeeWei ceiling so the sidecar aborts on an inflated fee */
      quote?: UnshieldQuote;
    };

type Props = {
  wallet: Wallet;
  onDone: (success: boolean) => void;
};

const HARDENED_MATCH = /^m\/44'\/60'\/(\d+)'\/\d+\/\d+$/;
function parseHardenedAccount(path: string): number | null {
  const m = path.match(HARDENED_MATCH);
  if (!m || !m[1]) return null;
  return parseInt(m[1], 10);
}
function nextHardenedAccount(paths: string[]): number {
  let max = -1;
  for (const p of paths) {
    const n = parseHardenedAccount(p);
    if (n !== null && n > max) max = n;
  }
  const next = max + 1;
  // Skip m/44'/60'/0'/0/0 — that's the implicit primary.
  return next === 0 ? 1 : next;
}

function weiToEthInput(value: string): string {
  const wei = hexToBigInt(value);
  const scale = 10n ** 18n;
  const whole = wei / scale;
  const fraction = (wei % scale).toString().padStart(18, "0").replace(/0+$/, "");
  return fraction.length > 0 ? `${whole}.${fraction}` : whole.toString();
}

/** Unshield from the wallet action menu. Mirrors ShieldFlow's protocol-
 *  picker shape but for the reverse direction.
 *
 *  Flow:
 *    1. pick protocol  — Privacy Pools v1  /  Railgun  /  Tornado Cash
 *    2. pick recipient source:
 *       a) derive a fresh sub-account on THIS wallet (no 0-link)
 *       b) pick from address book (book.list)
 *       c) type / paste an address
 *       (tornado: the daemon only accepts recipients derived from THIS
 *        wallet — the 7702 authorization comes from the recipient path)
 *    3. enter amount (PP passphrase if protocol=pp; tornado is one fixed
 *       denomination — 0.1/1/10/100 — or "max")
 *    4. for Railgun/Tornado: unlock the EOA (both keystores are rooted in
 *       the wallet seed); PP doesn't need the EOA (relayer broadcasts).
 *       Tornado then quotes the paymaster fee for the gate.
 *    5. dispatch — shielded.unshieldDrain (PP), shielded.railgun.unshield,
 *       or shielded.tornado.executeWithdraw (with the confirmed fee as
 *       the maxFeeWei ceiling). */
export default function WalletUnshieldFlow({ wallet, onDone }: Props) {
  const [phase, setPhase] = useState<Phase>({ kind: "pickProtocol" });

  /* book-loading → book.list once */
  useEffect(() => {
    if (phase.kind !== "book-loading") return;
    let cancelled = false;
    (async () => {
      const r = await call<{ entries: BookEntry[] }>("book.list");
      if (cancelled) return;
      if (!r.ok) {
        setPhase({ kind: "book-empty", protocol: phase.protocol });
        return;
      }
      const entries = r.result?.entries ?? [];
      if (entries.length === 0) {
        setPhase({ kind: "book-empty", protocol: phase.protocol });
      } else {
        setPhase({ kind: "book-pick", protocol: phase.protocol, entries });
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind]);

  /* derive-prep → fetch existing accounts so we know the next index */
  useEffect(() => {
    if (phase.kind !== "derive-prep") return;
    let cancelled = false;
    (async () => {
      const r = await call<{ accounts: AccountListEntry[] }>(
        "eoa.account.list",
        { name: wallet.name },
      );
      if (cancelled) return;
      const existing = r.ok ? r.result?.accounts ?? [] : [];
      const nextIdx = nextHardenedAccount(existing.map((a) => a.path ?? ""));
      // The form just collects an optional label; the path is derived
      // from `nextIdx`. Carry the protocol forward from derive-prep so
      // the eventual unshield dispatch hits the right RPC.
      setPhase((prev) =>
        prev.kind === "derive-prep"
          ? { kind: "derive-form", nextIdx, protocol: prev.protocol }
          : prev,
      );
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind, wallet.name]);

  if (wallet.kind !== "eoa") {
    return (
      <Layout title="Unshield" hint="enter / esc — back">
        <Banner kind="err" text="Unshield only supports EOA wallets today (the delegating signer for Railgun's 4337 UserOp is an EOA private key)." />
      </Layout>
    );
  }

  /* ─── pickProtocol ─── */
  if (phase.kind === "pickProtocol") {
    return (
      <Layout
        title={`Unshield from ${wallet.name}`}
        subtitle="pick the source pool"
        hint="↑/↓ move · enter select · esc back"
      >
        <Select
          items={[
            { label: "Privacy Pools v1 — Sepolia · relayer-broadcast", value: "pp" as Protocol },
            { label: "Railgun — Sepolia · 4337 + 7702 broadcast", value: "railgun" as Protocol },
            { label: "Tornado Cash — Sepolia · 4337 paymaster · one note per call", value: "tornado" as Protocol },
          ]}
          arrowNav
          onBack={() => onDone(false)}
          onSelect={(it) => setPhase({ kind: "pickSource", protocol: it.value })}
        />
      </Layout>
    );
  }

  /* ─── pickSource ─── */
  if (phase.kind === "pickSource") {
    const protocol = phase.protocol;
    return (
      <Layout
        title={`Unshield → recipient`}
        subtitle={`protocol: ${protoName(protocol)}`}
        hint="↑/↓ move · enter select · esc back"
      >
        <Select
          items={[
            {
              label: "Derive a fresh sub-account on this wallet (recommended — no on-chain link)",
              value: "derive" as RecipientSource,
            },
            {
              label: "Pick from address book",
              value: "book" as RecipientSource,
            },
            {
              label: "Type / paste an address",
              value: "paste" as RecipientSource,
            },
          ]}
          arrowNav
          onBack={() => setPhase({ kind: "pickProtocol" })}
          onSelect={(it) => {
            if (it.value === "derive") setPhase({ kind: "derive-prep", protocol });
            else if (it.value === "book") setPhase({ kind: "book-loading", protocol });
            else setPhase({ kind: "paste", protocol });
          }}
        />
        <Box marginTop={1}>
          <Text color={theme.dim}>
            {protocol === "pp"
              ? "Privacy Pools relayer broadcasts; no EOA unlock needed here."
              : protocol === "tornado"
                ? "Tornado's 7702 authorization is derived from the recipient's wallet path — the recipient MUST be an address derived from this wallet (the daemon rejects anything else)."
                : "Railgun broadcast is signed by this wallet's EOA via EIP-7702 — you'll be asked to unlock it before sending."}
          </Text>
        </Box>
      </Layout>
    );
  }

  /* ─── paste ─── */
  if (phase.kind === "paste") {
    const protocol = phase.protocol;
    return (
      <Layout title="Unshield → paste recipient">
        <Form
          fields={[
            {
              name: "recipient",
              label: "Recipient address (0x…)",
              validate: (v) =>
                v.startsWith("0x") && v.length === 42 ? null : "expected 0x… 20-byte address",
            },
          ]}
          onCancel={() => setPhase({ kind: "pickSource", protocol })}
          onSubmit={(v) =>
            setPhase({
              kind: "amount",
              protocol,
              recipient: v.recipient ?? "",
              source: "paste",
            })
          }
        />
      </Layout>
    );
  }

  /* ─── book ─── */
  if (phase.kind === "book-loading") {
    return (
      <Layout title="Unshield → loading address book">
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>fetching saved entries…</Text>
        </Text>
      </Layout>
    );
  }
  if (phase.kind === "book-empty") {
    return (
      <Layout
        title="Unshield → address book"
        subtitle="no saved entries"
        hint="esc — back"
      >
        <Banner
          kind="warn"
          text="address book is empty — add entries via `leancli book add <label> <addr>` first."
        />
        <Box marginTop={1}>
          <Select
            items={[{ label: "← Back", value: "back" }]}
            onSelect={() => setPhase({ kind: "pickSource", protocol: phase.protocol })}
          />
        </Box>
      </Layout>
    );
  }
  if (phase.kind === "book-pick") {
    const protocol = phase.protocol;
    return (
      <Layout
        title="Unshield → pick from address book"
        hint="↑/↓ pick · enter confirm · esc back"
      >
        <Select
          items={phase.entries.map((e) => {
            const tag = e.tag ? `  [${e.tag}]` : "";
            const ens = e.ensName ? `  (${e.ensName})` : "";
            return {
              label: `${e.label.padEnd(18)} ${e.address}${ens}${tag}`,
              value: e.address,
            };
          })}
          arrowNav
          onBack={() => setPhase({ kind: "pickSource", protocol })}
          onSelect={(it) =>
            setPhase({
              kind: "amount",
              protocol,
              recipient: it.value,
              source: "book",
            })
          }
        />
      </Layout>
    );
  }

  /* ─── derive (prep → form → run) ─── */
  if (phase.kind === "derive-prep") {
    return (
      <Layout title={`Unshield → derive on ${wallet.name}`}>
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>scanning sub-accounts for next free index…</Text>
        </Text>
      </Layout>
    );
  }
  if (phase.kind === "derive-form") {
    const path = `m/44'/60'/${phase.nextIdx}'/0/0`;
    const protocol = phase.protocol;
    const fields: Field[] = [
      {
        name: "label",
        label: "Label (optional)",
        placeholder: "unshield-1, fresh-a, …",
      },
    ];
    return (
      <Layout
        title={`Unshield → derive on ${wallet.name}`}
        subtitle={`derivation: ${path}  (BIP-32 hardened)`}
        hint="enter — derive · esc — back"
      >
        <Form
          fields={fields}
          onCancel={() => setPhase({ kind: "pickSource", protocol })}
          onSubmit={(v) => {
            const label = (v.label ?? "").trim();
            setPhase({
              kind: "derive-running",
              nextIdx: phase.nextIdx,
              protocol,
              label: label.length > 0 ? label : undefined,
            });
          }}
        />
      </Layout>
    );
  }
  if (phase.kind === "derive-running") {
    return (
      <DeriveAndAdvance
        walletName={wallet.name}
        nextIdx={phase.nextIdx}
        label={phase.label}
        onSuccess={(addr) =>
          setPhase({
            kind: "amount",
            protocol: phase.protocol,
            recipient: addr,
            source: "derive",
          })
        }
        onError={(message) =>
          setPhase({ kind: "derive-error", message, protocol: phase.protocol })
        }
      />
    );
  }
  if (phase.kind === "derive-error") {
    return (
      <Layout title="Unshield → derive failed" hint="esc — back">
        <Banner kind="err" text={phase.message} />
        <Box marginTop={1}>
          <Select
            items={[{ label: "← Back", value: "back" }]}
            onSelect={() => setPhase({ kind: "pickSource", protocol: phase.protocol })}
          />
        </Box>
      </Layout>
    );
  }

  /* ─── amount ─── */
  if (phase.kind === "amount") {
    const isPp = phase.protocol === "pp";
    const isTornado = phase.protocol === "tornado";
    const fields: Field[] = [
      {
        name: "amountEth",
        label: "Amount (ETH)",
        placeholder: isTornado ? "0.1 / 1 / 10 / 100 or max" : "0.005 or max",
        validate: (v) =>
          isTornado
            ? isTornadoWithdrawAmount(v)
              ? null
              : "tornado withdraws one note per call — 0.1, 1, 10, 100 or 'max'"
            : v.trim().toLowerCase() === "max" || /^[0-9]+(\.[0-9]+)?$/.test(v)
              ? null
              : "expected a decimal ETH amount or 'max'",
      },
      ...(isPp
        ? [
            {
              name: "passphrase",
              label: "Privacy Pool passphrase",
              secret: true,
              validate: (v: string) => (v.length === 0 ? "required" : null),
            } satisfies Field,
          ]
        : []),
    ];
    return (
      <Layout
        title={`Unshield → ${protoName(phase.protocol)}`}
        subtitle={`recipient: ${phase.recipient}  (source: ${phase.source})`}
      >
        <Form
          fields={fields}
          onCancel={() => setPhase({ kind: "pickSource", protocol: phase.protocol })}
          onSubmit={(v) => {
            const amountEth = v.amountEth ?? "0";
            if (phase.protocol === "railgun" || phase.protocol === "tornado") {
              setPhase({
                kind: "unlock",
                protocol: phase.protocol,
                recipient: phase.recipient,
                source: phase.source,
                amountEth,
              });
            } else {
              // PP: fetch a relayer fee quote, then gate on it. The actual
              // relay (shielded.unshieldDrain) only fires after confirm.
              setPhase({
                kind: "quote",
                protocol: "pp",
                recipient: phase.recipient,
                source: phase.source,
                amountEth,
                passphrase: v.passphrase ?? "",
              });
            }
          }}
        />
      </Layout>
    );
  }

  /* ─── Railgun/Tornado unlock step ─── */
  if (phase.kind === "unlock") {
    return (
      <UnlockEoaStep
        wallet={wallet}
        onUnlocked={() =>
          setPhase(
            phase.protocol === "tornado"
              ? // Tornado always quotes first (paymaster fee + net for the
                // gate); "max" resolves to the largest spendable note there.
                {
                  kind: "tornado-quote",
                  recipient: phase.recipient,
                  source: phase.source,
                  amountEth: phase.amountEth,
                }
              : phase.amountEth.toLowerCase() === "max"
                ? { kind: "railgun-max", recipient: phase.recipient, source: phase.source }
                : {
                    kind: "confirm",
                    protocol: "railgun",
                    recipient: phase.recipient,
                    source: phase.source,
                    amountEth: phase.amountEth,
                  },
          )
        }
        onCancel={() => onDone(false)}
      />
    );
  }

  /* ─── Tornado quote (paymaster fee terms; no proof, no broadcast) ─── */
  if (phase.kind === "tornado-quote") {
    return (
      <TornadoQuoteStep
        walletName={wallet.name}
        recipient={phase.recipient}
        amountEth={phase.amountEth}
        onReady={(quote, resolvedAmountEth) =>
          setPhase({
            kind: "confirm",
            protocol: "tornado",
            recipient: phase.recipient,
            source: phase.source,
            amountEth: resolvedAmountEth,
            quote,
          })
        }
        onError={(message) =>
          setPhase({ kind: "quote-error", protocol: "tornado", message })
        }
      />
    );
  }

  if (phase.kind === "railgun-max") {
    return (
      <RailgunMaxStep
        walletName={wallet.name}
        onReady={(amountEth, quote) =>
          setPhase({
            kind: "confirm",
            protocol: "railgun",
            recipient: phase.recipient,
            source: phase.source,
            amountEth,
            quote,
          })
        }
        onError={(message) =>
          setPhase({ kind: "quote-error", protocol: "railgun", message })
        }
      />
    );
  }

  /* ─── PP quote (no broadcast) ─── */
  if (phase.kind === "quote") {
    return (
      <QuoteUnshieldStep
        recipient={phase.recipient}
        amountEth={phase.amountEth}
        passphrase={phase.passphrase}
        onReady={(quote, resolvedAmountEth) =>
          setPhase({
            kind: "confirm",
            protocol: "pp",
            recipient: phase.recipient,
            source: phase.source,
            amountEth: resolvedAmountEth,
            passphrase: phase.passphrase,
            quote,
          })
        }
        onError={(message) =>
          setPhase({ kind: "quote-error", protocol: "pp", message })
        }
      />
    );
  }

  if (phase.kind === "quote-error") {
    return (
      <Layout title="Unshield — could not quote" hint="enter / esc — back">
        <Banner kind="err" text={phase.message} />
        <BackOnInput onDone={() => onDone(false)} />
      </Layout>
    );
  }

  /* ─── confirm gate (the pre-broadcast trust anchor) ─── */
  if (phase.kind === "confirm") {
    return (
      <UnshieldConfirmGate
        protocol={phase.protocol}
        recipient={phase.recipient}
        amountEth={phase.amountEth}
        quote={phase.quote}
        onConfirm={() =>
          setPhase({
            kind: "running",
            protocol: phase.protocol,
            recipient: phase.recipient,
            source: phase.source,
            amountEth: phase.amountEth,
            passphrase: phase.passphrase,
            quote: phase.quote,
          })
        }
        onCancel={() => onDone(false)}
      />
    );
  }

  /* ─── running ─── */
  if (phase.kind === "running") {
    const method =
      phase.protocol === "railgun"
        ? "shielded.railgun.unshield"
        : phase.protocol === "tornado"
          ? "shielded.tornado.executeWithdraw"
          : "shielded.unshieldDrain";
    const params: Record<string, unknown> = {
      recipient: phase.recipient,
      amountEth: phase.amountEth,
    };
    if (phase.protocol === "railgun") {
      // Railgun's daemon-side handler reads the named wallet's slot
      // for the delegating EOA + the BIP-39 seed (Railgun keystore is
      // rooted at the EOA's seed since the seed-keystore change).
      params.name = wallet.name;
    } else if (phase.protocol === "tornado") {
      params.name = wallet.name;
      params.chainId = TORNADO_CHAIN_ID;
      params.mode = "paymaster";
      // Fee ceiling: the user confirmed the quoted paymasterFeeWei — the
      // sidecar must abort rather than pay more out of the payout.
      if (phase.quote?.paymasterFeeWei) params.maxFeeWei = phase.quote.paymasterFeeWei;
    } else if (phase.passphrase) {
      params.passphrase = phase.passphrase;
    }
    const subtitle =
      phase.protocol === "railgun"
        ? "Railgun · Sepolia · 4337+7702"
        : phase.protocol === "tornado"
          ? "Tornado Cash · Sepolia · 4337 paymaster"
          : "Privacy Pools v1 · Sepolia · relayer-broadcast";
    return (
      <RpcRunner
        title={`Unshielding ${phase.amountEth} ETH → ${phase.recipient}`}
        subtitle={subtitle}
        method={method}
        params={params}
        timeoutMs={20 * 60 * 1000}
        renderResult={(r: any) => <Text>{JSON.stringify(r, null, 2)}</Text>}
        onDone={onDone}
      />
    );
  }

  return null;
}

/** Fire `eoa.account.add` and surface the new address inline. */
function DeriveAndAdvance({
  walletName,
  nextIdx,
  label,
  onSuccess,
  onError,
}: {
  walletName: string;
  nextIdx: number;
  label?: string;
  onSuccess: (address: string) => void;
  onError: (message: string) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const path = `m/44'/60'/${nextIdx}'/0/0`;
      const params: Record<string, unknown> = { name: walletName, path };
      if (label) params.label = label;
      const r = await call<{ address?: string }>("eoa.account.add", params);
      if (cancelled) return;
      if (!r.ok) {
        onError(`daemon error ${r.error.code}: ${r.error.message}`);
        return;
      }
      const addr = r.result?.address;
      if (!addr) {
        onError("daemon returned no address");
        return;
      }
      onSuccess(addr);
    })();
    return () => {
      cancelled = true;
    };
  }, []);
  return (
    <Layout
      title={`Deriving fresh sub-account on ${walletName}…`}
      subtitle={`derivation: m/44'/60'/${nextIdx}'/0/0`}
    >
      <Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>asking the daemon to derive the new branch…</Text>
      </Text>
    </Layout>
  );
}

/** Fetch a relayer fee quote for a PP unshield WITHOUT broadcasting. The
 *  daemon's `shielded.quoteUnshield` builds the proof, reads the relayer's
 *  quote, and discards it — nothing is relayed until the confirm gate. */
export function QuoteUnshieldStep({
  recipient,
  amountEth,
  passphrase,
  onReady,
  onError,
}: {
  recipient: string;
  amountEth: string;
  passphrase: string;
  onReady: (quote: UnshieldQuote, resolvedAmountEth: string) => void;
  onError: (message: string) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const resp = await call<UnshieldQuote>(
        "shielded.quoteUnshield",
        { recipient, amountEth, passphrase },
        // Proof generation + relayer round-trip; first run also syncs pool
        // state. Same generous budget as the broadcast path.
        { timeoutMs: 20 * 60 * 1000 },
      );
      if (cancelled) return;
      if (!resp.ok) {
        onError(`quote failed: ${resp.error.message}`);
        return;
      }
      const resolvedAmountEth = amountEth.trim().toLowerCase() === "max"
        ? weiToEthInput(resp.result.requestedWei)
        : amountEth;
      onReady(resp.result, resolvedAmountEth);
    })();
    return () => {
      cancelled = true;
    };
  }, []);
  return (
    <Layout title="Unshield — quoting relayer fee" subtitle="Privacy Pools v1 · Sepolia">
      <Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>
          building withdrawal proof + fetching relayer quote (no broadcast
          yet; first run syncs pool state)…
        </Text>
      </Text>
    </Layout>
  );
}

/** Quote a tornado withdrawal WITHOUT broadcasting: the daemon returns the
 *  paymaster fee + net payout for the confirm gate. No proof is built — the
 *  fee is a deterministic function of the bundler gas price, so the quote is
 *  cheap (first run still syncs pool state). "max" resolves to the largest
 *  spendable note here. */
function TornadoQuoteStep({
  walletName,
  recipient,
  amountEth,
  onReady,
  onError,
}: {
  walletName: string;
  recipient: string;
  amountEth: string;
  onReady: (quote: UnshieldQuote, resolvedAmountEth: string) => void;
  onError: (message: string) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const resp = await call<UnshieldQuote>(
        "shielded.tornado.quoteWithdraw",
        {
          name: walletName,
          chainId: TORNADO_CHAIN_ID,
          recipient,
          amountEth,
          mode: "paymaster",
        },
        { timeoutMs: 20 * 60 * 1000 },
      );
      if (cancelled) return;
      if (!resp.ok) {
        onError(`quote failed: ${resp.error.message}`);
        return;
      }
      const q = resp.result;
      // Pin the exact note denomination the quote priced (also resolves
      // "max") so execute withdraws precisely what the user confirmed.
      const resolvedAmountEth = q?.denominationWei
        ? weiToEthInput(q.denominationWei)
        : amountEth;
      onReady(q, resolvedAmountEth);
    })().catch((error) => {
      if (!cancelled) onError(error instanceof Error ? error.message : String(error));
    });
    return () => {
      cancelled = true;
    };
  }, []);
  return (
    <Layout title="Unshield — quoting paymaster fee" subtitle="Tornado Cash · Sepolia">
      <Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>
          syncing notes + pricing the 4337 paymaster fee (no broadcast yet)…
        </Text>
      </Text>
    </Layout>
  );
}

function RailgunMaxStep({
  walletName,
  onReady,
  onError,
}: {
  walletName: string;
  onReady: (amountEth: string, quote: UnshieldQuote) => void;
  onError: (message: string) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const response = await call<{ amountWei?: string }>(
        "shielded.railgun.maxUnshield",
        { name: walletName, strict: true },
        { timeoutMs: 20 * 60 * 1000 },
      );
      if (cancelled) return;
      if (!response.ok) {
        onError(`max quote failed: ${response.error.message}`);
        return;
      }
      const amountWei = response.result?.amountWei ?? "0x0";
      if (hexToBigInt(amountWei) <= 0n) {
        onError("no Railgun balance remains after treasury and bundler fees");
        return;
      }
      onReady(weiToEthInput(amountWei), response.result as UnshieldQuote);
    })().catch((error) => {
      if (!cancelled) onError(error instanceof Error ? error.message : String(error));
    });
    return () => { cancelled = true; };
  }, [walletName]);

  return (
    <Layout title="Resolving Railgun maximum">
      <Text>
        <Text color={theme.primary}><Spinner type="dots" /></Text>{" "}
        <Text color={theme.dim}>syncing balance and pricing 4337 gas…</Text>
      </Text>
    </Layout>
  );
}

/** wei (0x-hex) → "0.01 ETH"; tolerant of null/garbage. */
function ethStr(weiHex?: string | null): string {
  if (!weiHex) return "—";
  try {
    return `${formatEth(hexToBigInt(weiHex))} ETH`;
  } catch {
    return "—";
  }
}

/** Pre-broadcast confirm gate for an unshield. This IS the trust anchor:
 *  for PP there is no EOA signature (the relayer submits the proof), so the
 *  user confirming the recipient/amount/fee here is what authorises the
 *  relay. For Railgun the broadcast is signed inside the sidecar (the WASM
 *  signer cannot expose an unsigned UserOp — see the disclosure), so this
 *  gate is the strongest in-repo check before that signature happens. */
export function UnshieldConfirmGate({
  protocol,
  recipient,
  amountEth,
  quote,
  onConfirm,
  onCancel,
}: {
  protocol: Protocol;
  recipient: string;
  amountEth: string;
  quote?: UnshieldQuote;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  useInput((_, key) => {
    if (key.return) onConfirm();
    if (key.escape) onCancel();
  });
  const isRailgun = protocol === "railgun";
  const isTornado = protocol === "tornado";
  const feePct =
    quote?.feeBPS != null && quote.feeBPS !== ""
      ? `${(Number(quote.feeBPS) / 100).toFixed(2)}%`
      : "—";
  return (
    <Layout
      title={`Confirm unshield — ${protocol === "pp" ? "Privacy Pools v1" : protoName(protocol)} · Sepolia`}
      subtitle={`recipient ${recipient}`}
      hint="enter — broadcast · esc — cancel"
    >
      <Box flexDirection="column" marginBottom={1}>
        <Text>
          <Text color={theme.dim}>{"amount".padEnd(18)}</Text> {amountEth} ETH
        </Text>
        <Text>
          <Text color={theme.dim}>{"recipient".padEnd(18)}</Text> {recipient}
        </Text>
      </Box>

      {isTornado && quote && (
        <Box flexDirection="column" marginBottom={1}>
          <Text>
            <Text color={theme.dim}>{"note denomination".padEnd(18)}</Text>{" "}
            {ethStr(quote.denominationWei)}
          </Text>
          <Text>
            <Text color={theme.dim}>{"paymaster fee".padEnd(18)}</Text>{" "}
            {ethStr(quote.paymasterFeeWei)}  (confirmed as the fee ceiling)
          </Text>
          <Text>
            <Text color={theme.dim}>{"net to recipient".padEnd(18)}</Text>{" "}
            {ethStr(quote.netWei)}
          </Text>
          {quote.spendableTotalWei && (
            <Text>
              <Text color={theme.dim}>{"spendable total".padEnd(18)}</Text>{" "}
              {ethStr(quote.spendableTotalWei)}
              {quote.matchingNoteCount != null ? `  (${quote.matchingNoteCount} matching note${quote.matchingNoteCount === 1 ? "" : "s"})` : ""}
            </Text>
          )}
        </Box>
      )}

      {protocol === "pp" && quote && (
        <Box flexDirection="column" marginBottom={1}>
          <Text>
            <Text color={theme.dim}>{"relayer fee".padEnd(18)}</Text> {feePct}
            {quote.relayTxCostWei ? ` + ~${ethStr(quote.relayTxCostWei)} gas` : ""}
          </Text>
          {quote.relayerId && (
            <Text>
              <Text color={theme.dim}>{"relayer".padEnd(18)}</Text> {quote.relayerId}
            </Text>
          )}
          <Text>
            <Text color={theme.dim}>{"approved balance".padEnd(18)}</Text>{" "}
            {ethStr(quote.approvedTotalWei)}
          </Text>
          {quote.multiRelay && (
            <Text color={theme.warn}>
              ⚠ amount spans multiple notes — it will be drained over several
              relays, each charged its own fee. First relay ≈ {ethStr(quote.chunkWei)}.
            </Text>
          )}
        </Box>
      )}

      {isRailgun && quote?.estimatedGasFeeWei && (
        <Box flexDirection="column" marginBottom={1}>
          <Text>
            <Text color={theme.dim}>{"bundler reserve".padEnd(18)}</Text>{" "}
            ~{ethStr(quote.estimatedGasFeeWei)}
          </Text>
          <Text>
            <Text color={theme.dim}>{"treasury fee".padEnd(18)}</Text>{" "}
            {((quote.unshieldFeeBps ?? 0) / 100).toFixed(2)}%
          </Text>
        </Box>
      )}

      {isRailgun ? (
        <Box flexDirection="column">
          <Text color={theme.dim}>
            Railgun broadcasts a 4337 UserOp via EIP-7702; fees are sponsored
            by the Railgun paymaster (no relayer fee from your balance).
          </Text>
          <Text color={theme.dim}>
            7702 delegate (IMPL): {RAILGUN_7702_IMPL}
          </Text>
          <Text color={theme.warn}>
            ⚠ The delegating EOA private key is passed to the Railgun sidecar
            to sign the UserOp — the WASM signer cannot expose an unsigned
            UserOp for daemon-local signing (upstream SDK limitation). This
            confirm is the strongest in-repo gate before that signature.
          </Text>
        </Box>
      ) : isTornado ? (
        <Box flexDirection="column">
          <Text color={theme.dim}>
            Tornado broadcasts a 4337 UserOp; the paymaster fee above is
            deducted from the note and forwarded as a hard ceiling — the
            sidecar aborts rather than pay more. A groth16 proof authorizes
            the note spend; the 7702 authorization is derived from the
            recipient's wallet path at execute time.
          </Text>
          <Text color={theme.dim}>
            Confirming these terms is what authorises the withdrawal.
          </Text>
        </Box>
      ) : (
        <Text color={theme.dim}>
          A Privacy Pools withdrawal reveals the recipient + amount to the
          relayer, which submits the proof on-chain (no signature from your
          EOA). Confirming here authorises the relay.
        </Text>
      )}
    </Layout>
  );
}

function BackOnInput({ onDone }: { onDone: () => void }) {
  useInput((_, key) => {
    if (key.return || key.escape) onDone();
  });
  return null;
}
