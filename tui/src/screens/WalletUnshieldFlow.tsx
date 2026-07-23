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
import { formatEth, hexToBigInt, bigIntToHex, parseEthToWei } from "../format.js";
import { useSharedWalletData } from "../dashboard/walletdata.js";
import UnlockEoaStep from "./UnlockEoaStep.js";
import SendRawFlow, { SendRawWallet } from "./SendRawFlow.js";

type Protocol = "pp" | "railgun" | "tornado";
type RecipientSource = "derive" | "book" | "paste";

/* ─── unshield → DeFi composite plan ───────────────────────────────────
 *
 * An optional follow-up executed AFTER the unshield settles at a
 * freshly DERIVED recipient. Derive-only on purpose: the wallet controls
 * that sub-account's key, so every leg-2 transaction flows through the
 * canonical pre-sign pipeline (SendRawFlow: decode → simulate →
 * ConfirmGate → eoa.send with the sub-account index) — book/paste
 * recipients are keys we may not hold and get no composite offer.
 * Nothing in the plan is signed up front; each leg is separately
 * decoded, simulated, and user-confirmed when its turn comes. */

type TokenChoice = { symbol: string; decimals: number };

type DefiPlan =
  | { kind: "none" }
  | { kind: "swap"; tokenOut: TokenChoice }
  | { kind: "aave-supply" }
  | { kind: "aave-borrow"; asset: TokenChoice; amountHuman: string };

/** One confirmed-later leg-2 transaction. `value` is 0x-hex. */
type Leg2 = { to: string; value: string; data: string; rationale: string };

/** Fixed leg-2 slippage: 1% — Sepolia pools are thin and the composite
 *  keeps the step count low; the quote review shows the exact minOut. */
const LEG2_SLIPPAGE_BPS = 100;

/** WETH9 `deposit()` selector — wraps msg.value into WETH. Mirrors
 *  LeanCli.Aave.Prepare.encodeWethDeposit. */
const WETH_DEPOSIT_DATA = "0xd0e30db0";

/** Aave V3 Sepolia market WETH (LeanCli/Aave/Prepare.lean token override
 *  list). Only used as the wrap-leg target when aave.prepare returns
 *  `ready` (no approve frame to read the asset address from) — for a
 *  freshly derived recipient the allowance is 0, so the approve frame is
 *  normally present and authoritative. */
const AAVE_SEPOLIA_WETH = "0xc558dbdd856501fcd9aaf1e62eae57a9f0629a3c";

/** Assets offered for the leg-2 Aave borrow. Symbols resolve through
 *  aave.prepare's Sepolia market override list; an unknown/unborrowable
 *  asset fails there with a stable pre-sign error. */
const AAVE_BORROW_ASSETS: TokenChoice[] = [
  { symbol: "USDC", decimals: 6 },
  { symbol: "DAI", decimals: 18 },
  { symbol: "WETH", decimals: 18 },
  { symbol: "LINK", decimals: 18 },
];

/** "1.5" × 10^decimals → base units. Null on malformed/over-precision. */
function parseUnits(s: string, decimals: number): bigint | null {
  const m = s.trim().match(/^([0-9]+)(?:\.([0-9]*))?$/);
  if (!m) return null;
  const frac = (m[2] ?? "").slice(0, decimals);
  if ((m[2] ?? "").length > decimals) return null; // finer than the token
  return (
    BigInt(m[1]!) * 10n ** BigInt(decimals) +
    (frac.length > 0 ? BigInt(frac) * 10n ** BigInt(decimals - frac.length) : 0n)
  );
}

/** Tolerant JSON-value → 0x-hex for tx `value` fields coming back from
 *  daemon frames (aave.prepare emits JSON numbers, swap.uniV3.build too). */
function jsonValueToHex(v: unknown): string {
  if (v === null || v === undefined) return "0x0";
  if (typeof v === "string") {
    if (v.startsWith("0x") || v.startsWith("0X")) return v;
    try {
      return "0x" + BigInt(v).toString(16);
    } catch {
      return "0x0";
    }
  }
  if (typeof v === "number" || typeof v === "bigint") {
    try {
      return "0x" + BigInt(v).toString(16);
    } catch {
      return "0x0";
    }
  }
  return "0x0";
}

/** One-line human summary of the plan for the unshield confirm gate. */
function planSummary(plan: DefiPlan): string | null {
  switch (plan.kind) {
    case "none":
      return null;
    case "swap":
      return `swap the unshielded ETH → ${plan.tokenOut.symbol} (Uniswap V3, Sepolia)`;
    case "aave-supply":
      return "supply the unshielded ETH to Aave V3 (wrap → approve → supply)";
    case "aave-borrow":
      return `borrow ${plan.amountHuman} ${plan.asset.symbol} from Aave V3`;
  }
}

function protoName(p: Protocol): string {
  return p === "railgun" ? "Railgun" : p === "tornado" ? "Tornado Cash" : "Privacy Pools";
}

/** Tornado runs on mainnet too, but this pane pins Sepolia to match the
 *  rest of the dashboard — mainnet tornado stays on the CLI / chat paths. */
const TORNADO_CHAIN_ID = 11155111;

/** Every shielded protocol in this pane is Sepolia-pinned, so composite
 *  leg-2 transactions (swap / Aave) are decoded, simulated, and sent
 *  against Sepolia too. */
const SEPOLIA_CHAIN_ID = 11155111;

/** Alpha.18 can combine fixed-denomination notes in one paymaster UserOp.
 *  ETH pools have a 0.1 ETH minimum, so every explicit amount must be an
 *  exact positive multiple of 0.1. */
function isTornadoWithdrawAmount(v: string): boolean {
  const t = v.trim().toLowerCase();
  if (t === "max") return true;
  if (!/^[0-9]+(?:\.[0-9]+)?$/.test(t)) return false;
  const [whole, fraction = ""] = t.split(".");
  return (
    fraction.length <= 1 &&
    (BigInt(whole!) > 0n || /^[1-9]$/.test(fraction))
  );
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
  amountWei?: string | null;
  denominationWei?: string | null;
  spendableTotalWei?: string | null;
  matchingNoteCount?: number | null;
  withdrawalCount?: number | null;
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
    }
  /* composite: pick what happens after the unshield (derive-only) */
  | {
      kind: "then-pick";
      protocol: Protocol;
      recipient: string;
      source: RecipientSource;
      amountEth: string;
      passphrase?: string;
    }
  | {
      kind: "then-swap-token";
      protocol: Protocol;
      recipient: string;
      source: RecipientSource;
      amountEth: string;
      passphrase?: string;
    }
  | {
      kind: "then-borrow-asset";
      protocol: Protocol;
      recipient: string;
      source: RecipientSource;
      amountEth: string;
      passphrase?: string;
    }
  | {
      kind: "then-borrow-amount";
      protocol: Protocol;
      recipient: string;
      source: RecipientSource;
      amountEth: string;
      passphrase?: string;
      asset: TokenChoice;
    }
  /* composite leg 2 — runs only after the unshield RPC reported success */
  | { kind: "settle"; recipient: string }
  | {
      kind: "leg2-amount";
      recipient: string;
      receivedWei: bigint;
      balanceWei: bigint;
    }
  | { kind: "leg2-swap-quote"; recipient: string; amountWei: bigint }
  | {
      kind: "leg2-swap-review";
      recipient: string;
      amountWei: bigint;
      amountOut: bigint;
      fee: number;
    }
  | {
      kind: "leg2-swap-build";
      recipient: string;
      amountWei: bigint;
      minOut: bigint;
      fee: number;
    }
  | { kind: "leg2-aave-prepare"; recipient: string; amountWei?: bigint }
  | {
      kind: "leg2-gate";
      recipient: string;
      legs: Leg2[];
      idx: number;
      summary: string;
    }
  | { kind: "leg2-abort"; recipient: string; message: string }
  | { kind: "composite-done"; summary: string };

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
  // Composite state, kept OUTSIDE the phase machine so the existing
  // protocol phases don't have to thread it through every transition.
  const [plan, setPlan] = useState<DefiPlan>({ kind: "none" });
  // Hardened sub-account index of a derived recipient — the leg-2 signer
  // (eoa.send `account` param). Null for book/paste recipients.
  const [recipientIndex, setRecipientIndex] = useState<number | null>(null);
  // Recipient balance BEFORE the unshield broadcast; the settle step
  // waits for balance > baseline. Freshly derived accounts are 0, so the
  // optimistic null→0n fallback is correct even if the probe is slow.
  const [baselineWei, setBaselineWei] = useState<bigint | null>(null);
  // Dashboard's shielded-balance cache (display-only) — lets the protocol
  // picker show what the user actually holds without a 30-60s sidecar
  // spawn. Null when the dashboard poller isn't mounted.
  const shared = useSharedWalletData();

  /** Display-only baseline probe; fire-and-forget on plan selection. */
  const captureBaseline = (recipient: string) => {
    setBaselineWei(null);
    void call<{ balance: string }>(
      "chain.balance",
      { address: recipient, chain: "sepolia" },
      { timeoutMs: 180_000 },
    ).then((r) => {
      setBaselineWei(r.ok ? hexToBigInt(r.result?.balance) : 0n);
    });
  };

  /** Resume the per-protocol path exactly where the pre-composite flow
   *  would have gone from the amount form. */
  const continueAfterPlan = (p: {
    protocol: Protocol;
    recipient: string;
    source: RecipientSource;
    amountEth: string;
    passphrase?: string;
  }) => {
    if (p.protocol === "railgun" || p.protocol === "tornado") {
      setPhase({
        kind: "unlock",
        protocol: p.protocol,
        recipient: p.recipient,
        source: p.source,
        amountEth: p.amountEth,
      });
    } else {
      setPhase({
        kind: "quote",
        protocol: "pp",
        recipient: p.recipient,
        source: p.source,
        amountEth: p.amountEth,
        passphrase: p.passphrase ?? "",
      });
    }
  };

  /** Route into the planned leg-2 once funds are (or are declared) in. */
  const advanceToLeg2 = (
    recipient: string,
    receivedWei: bigint,
    balanceWei: bigint,
  ) => {
    if (plan.kind === "aave-borrow") {
      setPhase({ kind: "leg2-aave-prepare", recipient });
    } else {
      setPhase({ kind: "leg2-amount", recipient, receivedWei, balanceWei });
    }
  };

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
    // Display-only annotation from the dashboard's on-demand shielded
    // sync ('s' on the wallet pane) — helps pick the pool by what is
    // actually held, without spawning the slow privacy sidecar here.
    const shieldedLine =
      shared && shared.shielded.kind === "done"
        ? (() => {
            const { railgun, pp } = shared.shielded;
            const rg = "err" in railgun ? "error" : `${railgun.count} note(s)`;
            const p =
              "err" in pp
                ? "error"
                : `${pp.count} ${pp.count === 1 ? "entry" : "entries"}`;
            return `⛊ last sync — railgun: ${rg} · privacy pools: ${p}`;
          })()
        : null;
    return (
      <Layout
        title={`Unshield from ${wallet.name}`}
        subtitle="pick the source pool"
        hint="↑/↓ move · enter select · esc back"
      >
        <Select
          items={[
            { label: "Privacy Pools v1 — Sepolia · relayer-broadcast", value: "pp" as Protocol },
            { label: "Railgun — Sepolia · 4337 + 7702 · unshield needs daemon opt-in", value: "railgun" as Protocol },
            { label: "Tornado Cash — Sepolia · multi-note 4337 paymaster", value: "tornado" as Protocol },
          ]}
          arrowNav
          onBack={() => onDone(false)}
          onSelect={(it) => setPhase({ kind: "pickSource", protocol: it.value })}
        />
        {shieldedLine !== null && (
          <Box marginTop={1}>
            <Text color={theme.dim}>{shieldedLine}</Text>
          </Box>
        )}
        <Box marginTop={shieldedLine !== null ? 0 : 1}>
          <Text color={theme.dim}>
            Railgun unshield signs inside the sidecar and is refused unless
            the daemon runs with LEANCLI_ALLOW_RAILGUN_INSIDECAR_SIGNING=1.
          </Text>
        </Box>
      </Layout>
    );
  }

  /* ─── pickSource ─── */
  if (phase.kind === "pickSource") {
    const protocol = phase.protocol;
    // Tornado's daemon hard-rejects recipients not derived from the
    // selected wallet (-32602), so book/paste would only dead-end at the
    // quote step — offer the derive path alone.
    const sourceItems = [
      {
        label: "Derive a fresh sub-account on this wallet (recommended — no on-chain link)",
        value: "derive" as RecipientSource,
      },
      ...(protocol === "tornado"
        ? []
        : [
            {
              label: "Pick from address book",
              value: "book" as RecipientSource,
            },
            {
              label: "Type / paste an address",
              value: "paste" as RecipientSource,
            },
          ]),
    ];
    return (
      <Layout
        title={`Unshield → recipient`}
        subtitle={`protocol: ${protoName(protocol)}`}
        hint="↑/↓ move · enter select · esc back"
      >
        <Select
          items={sourceItems}
          arrowNav
          onBack={() => setPhase({ kind: "pickProtocol" })}
          onSelect={(it) => {
            // Entering a fresh recipient path resets any stale composite
            // plan from an earlier pass through this wizard.
            setPlan({ kind: "none" });
            setRecipientIndex(null);
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
        onSuccess={(addr) => {
          // Remember the sub-account index: it is the leg-2 signer
          // (eoa.send `account`) if the user picks a composite plan.
          setRecipientIndex(phase.nextIdx);
          setPhase({
            kind: "amount",
            protocol: phase.protocol,
            recipient: addr,
            source: "derive",
          });
        }}
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
        placeholder: isTornado ? "0.1 multiple or max" : "0.005 or max",
        validate: (v) =>
          isTornado
            ? isTornadoWithdrawAmount(v)
              ? null
              : "expected a positive exact 0.1 ETH multiple or 'max'"
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
            // Derived recipients are keys this wallet controls, so they can
            // chain a DeFi follow-up (each leg separately gated). Everyone
            // else continues straight down the classic path.
            if (phase.source === "derive") {
              setPhase({
                kind: "then-pick",
                protocol: phase.protocol,
                recipient: phase.recipient,
                source: phase.source,
                amountEth,
                passphrase: v.passphrase,
              });
              return;
            }
            continueAfterPlan({
              protocol: phase.protocol,
              recipient: phase.recipient,
              source: phase.source,
              amountEth,
              passphrase: v.passphrase,
            });
          }}
        />
      </Layout>
    );
  }

  /* ─── composite: what happens after the unshield? ─── */
  if (phase.kind === "then-pick") {
    const back = () =>
      setPhase({
        kind: "amount",
        protocol: phase.protocol,
        recipient: phase.recipient,
        source: phase.source,
      });
    return (
      <Layout
        title="After the unshield…"
        subtitle={`recipient ${phase.recipient} · every follow-up tx is separately simulated and confirmed`}
        hint="↑/↓ move · enter select · esc back"
      >
        <Select
          items={[
            { label: "Just unshield — stop once the funds land", value: "none" },
            { label: "Then swap ETH → token (Uniswap V3 · Sepolia)", value: "swap" },
            { label: "Then supply to Aave V3 (wrap ETH → WETH → supply)", value: "aave-supply" },
            { label: "Then borrow from Aave V3 (requires existing collateral)", value: "aave-borrow" },
          ]}
          arrowNav
          onBack={back}
          onSelect={(it) => {
            if (it.value === "none") {
              setPlan({ kind: "none" });
              continueAfterPlan(phase);
            } else if (it.value === "swap") {
              setPhase({ ...phase, kind: "then-swap-token" });
            } else if (it.value === "aave-supply") {
              setPlan({ kind: "aave-supply" });
              captureBaseline(phase.recipient);
              continueAfterPlan(phase);
            } else {
              setPhase({ ...phase, kind: "then-borrow-asset" });
            }
          }}
        />
        <Box marginTop={1}>
          <Text color={theme.dim}>
            Privacy note: acting immediately from the fresh address links the
            withdrawal and the DeFi step by timing on-chain. Waiting between
            the legs improves the anonymity set.
          </Text>
        </Box>
      </Layout>
    );
  }

  if (phase.kind === "then-swap-token") {
    return (
      <SwapTokenPickStep
        onBack={() => setPhase({ ...phase, kind: "then-pick" })}
        onPick={(tokenOut) => {
          setPlan({ kind: "swap", tokenOut });
          captureBaseline(phase.recipient);
          continueAfterPlan(phase);
        }}
      />
    );
  }

  if (phase.kind === "then-borrow-asset") {
    return (
      <Layout
        title="Borrow from Aave V3 — pick the asset"
        subtitle="Sepolia · variable rate · borrowed against the recipient's existing collateral"
        hint="↑/↓ move · enter select · esc back"
      >
        <Select
          items={AAVE_BORROW_ASSETS.map((a) => ({
            label: `${a.symbol.padEnd(6)} (${a.decimals} decimals)`,
            value: a.symbol,
          }))}
          arrowNav
          onBack={() => setPhase({ ...phase, kind: "then-pick" })}
          onSelect={(it) => {
            const asset = AAVE_BORROW_ASSETS.find((a) => a.symbol === it.value)!;
            setPhase({ ...phase, kind: "then-borrow-amount", asset });
          }}
        />
        <Box marginTop={1}>
          <Text color={theme.warn}>
            ⚠ borrowing needs collateral already supplied FOR THE RECIPIENT
            address — a freshly derived account has none until you supply
            first. The pre-sign simulation will catch an impossible borrow.
          </Text>
        </Box>
      </Layout>
    );
  }

  if (phase.kind === "then-borrow-amount") {
    return (
      <Layout
        title={`Borrow ${phase.asset.symbol} from Aave V3`}
        subtitle="amount is prepared after the unshield settles; simulation + confirm gate follow"
      >
        <Form
          fields={[
            {
              name: "amount",
              label: `Amount (${phase.asset.symbol})`,
              placeholder: phase.asset.symbol === "USDC" ? "25" : "0.5",
              validate: (v) =>
                parseUnits(v, phase.asset.decimals) !== null &&
                parseUnits(v, phase.asset.decimals)! > 0n
                  ? null
                  : `expected a positive decimal ${phase.asset.symbol} amount (≤ ${phase.asset.decimals} decimals)`,
            },
          ]}
          onCancel={() => setPhase({ ...phase, kind: "then-borrow-asset" })}
          onSubmit={(v) => {
            setPlan({
              kind: "aave-borrow",
              asset: phase.asset,
              amountHuman: (v.amount ?? "0").trim(),
            });
            captureBaseline(phase.recipient);
            continueAfterPlan(phase);
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
                // gate); "max" resolves to the total spendable balance there.
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
        planLine={phase.source === "derive" ? planSummary(plan) : null}
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
        onDone={(success) => {
          // Composite continuation: only when the unshield RPC reported
          // success AND a plan was armed on a derived recipient. Everyone
          // else keeps the historic exit.
          if (!success || plan.kind === "none" || phase.source !== "derive") {
            onDone(success);
            return;
          }
          setPhase({ kind: "settle", recipient: phase.recipient });
        }}
      />
    );
  }

  /* ─── composite leg 2 ─── */
  if (phase.kind === "settle") {
    return (
      <SettleStep
        recipient={phase.recipient}
        baseline={baselineWei}
        planLine={planSummary(plan) ?? "(no follow-up)"}
        onFunds={(received, balance) =>
          advanceToLeg2(phase.recipient, received, balance)
        }
        onProceed={(current) => {
          const base = baselineWei ?? 0n;
          const received = current !== null && current > base ? current - base : 0n;
          advanceToLeg2(phase.recipient, received, current ?? 0n);
        }}
        onSkip={() => onDone(true)}
      />
    );
  }

  if (phase.kind === "leg2-amount") {
    // Gas headroom left at the recipient: leg-2 gas is paid from the
    // unshielded ETH itself (the relayer/paymaster funded nothing else).
    // Supply reserves more — it is a 2-3 tx chain (wrap → approve → supply).
    const headroom = plan.kind === "aave-supply" ? 6_000_000_000_000_000n : 5_000_000_000_000_000n;
    const suggestWei =
      phase.receivedWei > headroom ? phase.receivedWei - headroom : 0n;
    const suggest = weiToEthInput(bigIntToHex(suggestWei));
    const verb = plan.kind === "swap" ? "swap" : "supply";
    return (
      <Layout
        title={plan.kind === "swap" ? "Swap unshielded ETH" : "Supply unshielded ETH to Aave V3"}
        subtitle={`received ${formatEth(phase.receivedWei)} ETH at ${phase.recipient} · leave some ETH for gas`}
      >
        <Form
          fields={[
            {
              name: "amountEth",
              label: `ETH to ${verb}`,
              placeholder: `${suggest} (enter = use this; keeps gas headroom)`,
              validate: (v) => {
                if (v.trim() === "") return suggestWei > 0n ? null : "received amount too small — type an amount";
                const wei = parseEthToWei(v);
                if (wei === null || wei <= 0n) return "expected a positive decimal ETH amount";
                if (wei > phase.balanceWei) return `exceeds the recipient balance (${formatEth(phase.balanceWei)} ETH)`;
                return null;
              },
            },
          ]}
          onCancel={() => onDone(true)}
          onSubmit={(v) => {
            const raw = (v.amountEth ?? "").trim();
            const amountWei = raw === "" ? suggestWei : parseEthToWei(raw)!;
            if (plan.kind === "swap") {
              setPhase({ kind: "leg2-swap-quote", recipient: phase.recipient, amountWei });
            } else {
              setPhase({ kind: "leg2-aave-prepare", recipient: phase.recipient, amountWei });
            }
          }}
        />
        <Box marginTop={1}>
          <Text color={theme.dim}>esc — keep the funds as plain ETH (no follow-up)</Text>
        </Box>
      </Layout>
    );
  }

  if (phase.kind === "leg2-swap-quote" && plan.kind === "swap") {
    return (
      <Leg2SwapQuoteStep
        tokenOut={plan.tokenOut}
        amountWei={phase.amountWei}
        onReady={(amountOut, fee) =>
          setPhase({
            kind: "leg2-swap-review",
            recipient: phase.recipient,
            amountWei: phase.amountWei,
            amountOut,
            fee,
          })
        }
        onError={(message) =>
          setPhase({ kind: "leg2-abort", recipient: phase.recipient, message })
        }
      />
    );
  }

  if (phase.kind === "leg2-swap-review" && plan.kind === "swap") {
    const minOut =
      (phase.amountOut * BigInt(10000 - LEG2_SLIPPAGE_BPS)) / 10000n;
    return (
      <Leg2SwapReview
        tokenOut={plan.tokenOut}
        amountWei={phase.amountWei}
        amountOut={phase.amountOut}
        minOut={minOut}
        fee={phase.fee}
        onConfirm={() =>
          setPhase({
            kind: "leg2-swap-build",
            recipient: phase.recipient,
            amountWei: phase.amountWei,
            minOut,
            fee: phase.fee,
          })
        }
        onCancel={() =>
          setPhase({
            kind: "leg2-abort",
            recipient: phase.recipient,
            message: "swap cancelled — unshielded funds remain as ETH at the recipient",
          })
        }
      />
    );
  }

  if (phase.kind === "leg2-swap-build" && plan.kind === "swap") {
    return (
      <Leg2SwapBuildStep
        recipient={phase.recipient}
        tokenOut={plan.tokenOut}
        amountWei={phase.amountWei}
        minOut={phase.minOut}
        fee={phase.fee}
        onReady={(legs, summary) =>
          setPhase({ kind: "leg2-gate", recipient: phase.recipient, legs, idx: 0, summary })
        }
        onError={(message) =>
          setPhase({ kind: "leg2-abort", recipient: phase.recipient, message })
        }
      />
    );
  }

  if (phase.kind === "leg2-aave-prepare") {
    return (
      <Leg2AavePrepareStep
        recipient={phase.recipient}
        plan={plan}
        amountWei={phase.amountWei}
        onReady={(legs, summary) =>
          setPhase({ kind: "leg2-gate", recipient: phase.recipient, legs, idx: 0, summary })
        }
        onError={(message) =>
          setPhase({ kind: "leg2-abort", recipient: phase.recipient, message })
        }
      />
    );
  }

  if (phase.kind === "leg2-gate") {
    const leg = phase.legs[phase.idx]!;
    const signer: SendRawWallet = {
      kind: "eoa",
      name: wallet.name,
      address: phase.recipient,
      accountIndex: recipientIndex ?? undefined,
    };
    // Each leg runs the canonical pre-sign pipeline (decode → simulate →
    // ConfirmGate → eoa.send). The signer is the derived sub-account —
    // eoa.send waits for the receipt daemon-side, so leg N mines before
    // leg N+1 simulates. A fresh `key` per leg resets SendRawFlow state.
    return (
      <SendRawFlow
        key={`leg2-${phase.idx}`}
        tx={{
          to: leg.to,
          value: leg.value,
          data: leg.data,
          rationale: leg.rationale,
        }}
        chainId={SEPOLIA_CHAIN_ID}
        wallet={signer}
        onDone={(success) => {
          if (!success) {
            setPhase({
              kind: "leg2-abort",
              recipient: phase.recipient,
              message:
                "follow-up step cancelled — the unshield itself already completed; funds remain at the recipient",
            });
            return;
          }
          if (phase.idx + 1 < phase.legs.length) {
            setPhase({ ...phase, idx: phase.idx + 1 });
          } else {
            setPhase({ kind: "composite-done", summary: phase.summary });
          }
        }}
      />
    );
  }

  if (phase.kind === "leg2-abort") {
    return (
      <Layout
        title="Unshield done — follow-up stopped"
        subtitle={`funds are at ${phase.recipient}`}
        hint="enter / esc — back"
      >
        <Banner kind="warn" text={phase.message} />
        <Text color={theme.dim}>
          You can run the swap / Aave step later from the Wallets hub — the
          derived sub-account is a normal account of this wallet.
        </Text>
        <BackOnInput onDone={() => onDone(true)} />
      </Layout>
    );
  }

  if (phase.kind === "composite-done") {
    return (
      <Layout title="Unshield + follow-up complete" hint="enter / esc — back">
        <Banner kind="ok" text={phase.summary} />
        <BackOnInput onDone={() => onDone(true)} />
      </Layout>
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

/** Quote a tornado withdrawal WITHOUT broadcasting: the daemon prepares and
 *  discards the proof so the confirm gate is bound to the SDK-refined fee.
 *  "max" resolves to the total spendable note balance here. */
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
      // Pin the exact total the quote priced (also resolves "max") so execute
      // withdraws precisely what the user confirmed.
      const quotedAmountWei = q?.amountWei ?? q?.denominationWei;
      const resolvedAmountEth = quotedAmountWei
        ? weiToEthInput(quotedAmountWei)
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
  planLine,
  onConfirm,
  onCancel,
}: {
  protocol: Protocol;
  recipient: string;
  amountEth: string;
  quote?: UnshieldQuote;
  /** Composite follow-up summary (unshield→DeFi). Display-only: the
   *  follow-up legs are separately simulated and confirmed later. */
  planLine?: string | null;
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
        {planLine && (
          <Text>
            <Text color={theme.dim}>{"after unshield".padEnd(18)}</Text>{" "}
            <Text color={theme.koiCream}>{planLine}</Text>
            <Text color={theme.dim}> — each step separately simulated + confirmed</Text>
          </Text>
        )}
      </Box>

      {isTornado && quote && (
        <Box flexDirection="column" marginBottom={1}>
          <Text>
            <Text color={theme.dim}>{"withdraw total".padEnd(18)}</Text>{" "}
            {ethStr(quote.amountWei ?? quote.denominationWei)}
            {quote.withdrawalCount != null
              ? `  (${quote.withdrawalCount} note${quote.withdrawalCount === 1 ? "" : "s"}, one UserOp)`
              : ""}
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

/* ─── composite leg-2 helper steps ──────────────────────────────────── */

/** Wait for the unshielded funds to land at the recipient. The relayer /
 *  paymaster tx is broadcast by the time the unshield RPC returns, but
 *  inclusion is not guaranteed — poll a verified `chain.balance` read
 *  every 5s until it rises above the pre-unshield baseline. Display-only
 *  sequencing: the follow-up legs are still simulated + confirmed. */
function SettleStep({
  recipient,
  baseline,
  planLine,
  onFunds,
  onProceed,
  onSkip,
}: {
  recipient: string;
  baseline: bigint | null;
  planLine: string;
  onFunds: (receivedWei: bigint, balanceWei: bigint) => void;
  onProceed: (currentWei: bigint | null) => void;
  onSkip: () => void;
}) {
  const [current, setCurrent] = useState<bigint | null>(null);
  const [polls, setPolls] = useState(0);
  // Refs so the poll loop always sees the latest values without
  // re-arming the effect (which would double-poll).
  const doneRef = React.useRef(false);
  // The baseline probe is fired minutes before this mounts (at plan
  // selection) but can in principle resolve late — read it through a
  // ref refreshed on every render so the poll loop never compares
  // against a stale null.
  const baselineRef = React.useRef(baseline);
  baselineRef.current = baseline;

  useEffect(() => {
    let cancelled = false;
    const tick = async () => {
      if (cancelled || doneRef.current) return;
      const r = await call<{ balance: string }>(
        "chain.balance",
        { address: recipient, chain: "sepolia" },
        { timeoutMs: 60_000 },
      );
      if (cancelled || doneRef.current) return;
      if (r.ok) {
        const wei = hexToBigInt(r.result?.balance);
        setCurrent(wei);
        const base = baselineRef.current ?? 0n;
        if (wei > base) {
          doneRef.current = true;
          onFunds(wei - base, wei);
          return;
        }
      }
      setPolls((p) => p + 1);
      setTimeout(() => void tick(), 5_000);
    };
    void tick();
    return () => {
      cancelled = true;
    };
    // recipient never changes within one flow instance.
  }, [recipient]);

  useInput((_, key) => {
    if (key.return) {
      doneRef.current = true;
      onProceed(current);
    }
    if (key.escape) {
      doneRef.current = true;
      onSkip();
    }
  });

  const base = baseline ?? 0n;
  return (
    <Layout
      title="Unshield broadcast — waiting for funds to land"
      subtitle={`recipient ${recipient}`}
      hint="enter — proceed to the follow-up now · esc — stop here (keep as ETH)"
    >
      <Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>
          polling verified balance every 5s ({polls} check{polls === 1 ? "" : "s"} so far)…
        </Text>
      </Text>
      <Box marginTop={1} flexDirection="column">
        <Text>
          <Text color={theme.dim}>{"planned next".padEnd(16)}</Text> {planLine}
        </Text>
        <Text>
          <Text color={theme.dim}>{"baseline".padEnd(16)}</Text>{" "}
          {baseline === null ? "…" : `${formatEth(base)} ETH`}
        </Text>
        <Text>
          <Text color={theme.dim}>{"current".padEnd(16)}</Text>{" "}
          {current === null ? "…" : `${formatEth(current)} ETH`}
        </Text>
      </Box>
      <Box marginTop={1}>
        <Text color={theme.dim}>
          First verified read after a daemon restart can take ~30s (light
          client sync); relayed withdrawals typically land within a couple
          of minutes.
        </Text>
      </Box>
    </Layout>
  );
}

/** Pick the swap output token from the Sepolia registry (ERC-20 rows
 *  only — the input side is always the unshielded native ETH). */
function SwapTokenPickStep({
  onPick,
  onBack,
}: {
  onPick: (token: TokenChoice) => void;
  onBack: () => void;
}) {
  const [state, setState] = useState<
    | { kind: "loading" }
    | { kind: "err"; message: string }
    | { kind: "ok"; tokens: TokenChoice[] }
  >({ kind: "loading" });

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const r = await call<{
        tokens: Array<{ symbol: string; decimals: number }>;
      }>("swap.tokens.list", { chainId: "sepolia" });
      if (cancelled) return;
      if (!r.ok) {
        setState({ kind: "err", message: r.error.message });
        return;
      }
      const tokens = (r.result?.tokens ?? [])
        .filter((t) => t && typeof t.symbol === "string")
        .map((t) => ({ symbol: t.symbol, decimals: t.decimals ?? 18 }));
      if (tokens.length === 0) {
        setState({ kind: "err", message: "no Sepolia tokens in the swap registry" });
        return;
      }
      setState({ kind: "ok", tokens });
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  if (state.kind === "loading") {
    return (
      <Layout title="Swap — pick the output token" subtitle="Uniswap V3 · Sepolia">
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>loading the Sepolia token registry…</Text>
        </Text>
      </Layout>
    );
  }
  if (state.kind === "err") {
    return (
      <Layout title="Swap — registry unavailable" hint="esc — back">
        <Banner kind="err" text={state.message} />
        <Box marginTop={1}>
          <Select items={[{ label: "← Back", value: "back" }]} onSelect={onBack} />
        </Box>
      </Layout>
    );
  }
  return (
    <Layout
      title="Swap — pick the output token"
      subtitle="the unshielded ETH is the input · ETH-in swaps need no approval"
      hint="↑/↓ move · enter select · esc back"
    >
      <Select
        items={state.tokens.map((t) => ({
          label: `${t.symbol.padEnd(8)} (${t.decimals} decimals)`,
          value: t.symbol,
        }))}
        arrowNav
        onBack={onBack}
        onSelect={(it) => {
          const t = state.tokens.find((x) => x.symbol === it.value);
          if (t) onPick(t);
        }}
      />
    </Layout>
  );
}

/** Quote ETH → tokenOut on Uniswap V3 Sepolia (no broadcast). */
function Leg2SwapQuoteStep({
  tokenOut,
  amountWei,
  onReady,
  onError,
}: {
  tokenOut: TokenChoice;
  amountWei: bigint;
  onReady: (amountOut: bigint, fee: number) => void;
  onError: (message: string) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const r = await call<{ amountOut: number | string; fee: number }>(
        "swap.uniV3.quote",
        {
          // chainId is a NAME string daemon-side (ChainId.fromString?);
          // a number silently falls back to mainnet.
          chainId: "sepolia",
          tokenIn: "ETH",
          tokenOut: tokenOut.symbol,
          amountIn: amountWei,
        },
      );
      if (cancelled) return;
      if (!r.ok) return onError(`quote failed: ${r.error.message}`);
      try {
        const amountOut = BigInt(r.result?.amountOut as any);
        if (amountOut === 0n)
          return onError("quoter returned 0 — no liquidity for this pair on Sepolia");
        onReady(amountOut, Number(r.result?.fee));
      } catch (e) {
        onError(`malformed quote response: ${String(e)}`);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);
  return (
    <Layout title="Quoting swap…" subtitle={`ETH → ${tokenOut.symbol} · Uniswap V3 · Sepolia`}>
      <Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>probing fee tiers via the QuoterV2…</Text>
      </Text>
    </Layout>
  );
}

/** Review the leg-2 swap quote before building calldata. Display-only —
 *  the built calldata still goes through SendRawFlow's full gate. */
function Leg2SwapReview({
  tokenOut,
  amountWei,
  amountOut,
  minOut,
  fee,
  onConfirm,
  onCancel,
}: {
  tokenOut: TokenChoice;
  amountWei: bigint;
  amountOut: bigint;
  minOut: bigint;
  fee: number;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  useInput((_, key) => {
    if (key.return) onConfirm();
    if (key.escape) onCancel();
  });
  const fmt = (v: bigint) => {
    const base = 10n ** BigInt(tokenOut.decimals);
    const whole = v / base;
    const frac = ((v % base) * 10000n) / base;
    return frac === 0n
      ? whole.toString()
      : `${whole}.${frac.toString().padStart(4, "0").replace(/0+$/, "")}`;
  };
  return (
    <Layout
      title={`Swap quote — ETH → ${tokenOut.symbol}`}
      subtitle={`Uniswap V3 · Sepolia · fee tier ${(fee / 10000).toFixed(2)}%`}
      hint="enter — build & confirm · esc — skip the swap"
    >
      <Text>
        <Text color={theme.dim}>{"amount in".padEnd(16)}</Text> {formatEth(amountWei)} ETH
      </Text>
      <Text>
        <Text color={theme.dim}>{"amount out".padEnd(16)}</Text> {fmt(amountOut)} {tokenOut.symbol}
      </Text>
      <Text>
        <Text color={theme.dim}>{"min received".padEnd(16)}</Text> {fmt(minOut)}{" "}
        {tokenOut.symbol}{" "}
        <Text color={theme.dim}>(slippage {LEG2_SLIPPAGE_BPS / 100}%)</Text>
      </Text>
      <Box marginTop={1}>
        <Text color={theme.dim}>
          The exact calldata is decoded and simulated on the next screen —
          nothing is signed here.
        </Text>
      </Box>
    </Layout>
  );
}

/** Build the leg-2 swap calldata. ETH-in swaps carry the value in the tx
 *  and never need an approval leg; a non-null approval (unexpected here)
 *  is still honored as an extra gated leg rather than dropped. */
function Leg2SwapBuildStep({
  recipient,
  tokenOut,
  amountWei,
  minOut,
  fee,
  onReady,
  onError,
}: {
  recipient: string;
  tokenOut: TokenChoice;
  amountWei: bigint;
  minOut: bigint;
  fee: number;
  onReady: (legs: Leg2[], summary: string) => void;
  onError: (message: string) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const r = await call<any>("swap.uniV3.build", {
        chainId: "sepolia",
        fromAddress: recipient,
        tokenIn: "ETH",
        tokenOut: tokenOut.symbol,
        amountIn: amountWei,
        amountOutMin: minOut,
        fee,
        recipient,
      });
      if (cancelled) return;
      if (!r.ok) return onError(`build failed: ${r.error.message}`);
      const txField = r.result?.tx;
      if (!txField || typeof txField.to !== "string") {
        return onError("daemon returned no swap tx");
      }
      const legs: Leg2[] = [];
      const a = r.result?.approval;
      if (a && typeof a === "object" && typeof a.to === "string") {
        legs.push({
          to: a.to,
          value: jsonValueToHex(a.value),
          data: typeof a.data === "string" ? a.data : "0x",
          rationale: `Unshield follow-up · approve Uniswap V3 router (leg ${legs.length + 1})`,
        });
      }
      legs.push({
        to: txField.to,
        // ETH-in swaps carry msg.value = amountIn. Use OUR exact bigint
        // rather than the daemon's echoed value: the response rides plain
        // JSON.parse, which rounds integers above 2^53 (~0.009 ETH in wei)
        // to the nearest double — the calldata's embedded amountIn is
        // exact (encoded daemon-side from the BigInt request), so a
        // rounded-down msg.value would revert the swap.
        value: bigIntToHex(amountWei),
        data: typeof txField.data === "string" ? txField.data : "0x",
        rationale: `Unshield follow-up · swap ${formatEth(amountWei)} ETH → ${tokenOut.symbol} (min out enforced on-chain)`,
      });
      onReady(legs, `unshielded ETH swapped → ${tokenOut.symbol} (Uniswap V3, Sepolia)`);
    })();
    return () => {
      cancelled = true;
    };
  }, []);
  return (
    <Layout title="Building swap calldata…" subtitle="swap.uniV3.build">
      <Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>encoding exactInputSingle…</Text>
      </Text>
    </Layout>
  );
}

/** Prepare the leg-2 Aave frames via the daemon's aave.prepare.
 *  - supply (amountWei set): native ETH must be wrapped first for an EOA,
 *    so the legs are wrap (WETH.deposit carrying the value) → approve
 *    (from the daemon frame) → supply. The wrap target comes from the
 *    daemon's approve frame (authoritative for the Aave market's WETH);
 *    the constant fallback covers the allowance-already-granted case.
 *  - borrow: a single no-approval frame.
 *  Every frame still flows through SendRawFlow's decode → simulate →
 *  ConfirmGate → eoa.send. */
function Leg2AavePrepareStep({
  recipient,
  plan,
  amountWei,
  onReady,
  onError,
}: {
  recipient: string;
  plan: DefiPlan;
  amountWei?: bigint;
  onReady: (legs: Leg2[], summary: string) => void;
  onError: (message: string) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const isSupply = plan.kind === "aave-supply";
      if (!isSupply && plan.kind !== "aave-borrow") {
        return onError("no Aave plan armed (internal state error)");
      }
      let amount: bigint;
      let params: Record<string, unknown>;
      if (isSupply) {
        if (amountWei === undefined || amountWei <= 0n) {
          return onError("no supply amount available");
        }
        amount = amountWei;
        params = {
          action: "supply",
          sender: recipient,
          asset: "WETH",
          amount,
          chainId: SEPOLIA_CHAIN_ID,
          accountKind: "eoa",
        };
      } else {
        const p = plan as Extract<DefiPlan, { kind: "aave-borrow" }>;
        const base = parseUnits(p.amountHuman, p.asset.decimals);
        if (base === null || base <= 0n) {
          return onError(`malformed borrow amount: ${p.amountHuman}`);
        }
        amount = base;
        params = {
          action: "borrow",
          sender: recipient,
          asset: p.asset.symbol,
          amount,
          chainId: SEPOLIA_CHAIN_ID,
          accountKind: "eoa",
          rateMode: "variable",
        };
      }
      const r = await call<any>("aave.prepare", params, { timeoutMs: 120_000 });
      if (cancelled) return;
      if (!r.ok) return onError(`aave.prepare failed: ${r.error.message}`);
      const res = r.result ?? {};
      if (res.status === "error") {
        return onError(`aave.prepare: ${res.kind ?? "error"} — ${res.error ?? "(no detail)"}`);
      }
      const frameToLeg = (f: any, rationale: string): Leg2 | null =>
        f && typeof f.to === "string"
          ? {
              to: f.to,
              value: jsonValueToHex(f.value),
              data: typeof f.data === "string" ? f.data : "0x",
              rationale,
            }
          : null;
      const legs: Leg2[] = [];
      if (isSupply) {
        // The approve frame's `to` IS the Aave market's WETH — the wrap
        // must target the same contract the Pool reserve uses.
        const approveLeg = frameToLeg(
          res.approve,
          "Unshield follow-up · approve Aave V3 Pool to pull WETH",
        );
        const wethAddr =
          approveLeg?.to ?? (SEPOLIA_CHAIN_ID === 11155111 ? AAVE_SEPOLIA_WETH : null);
        if (!wethAddr) {
          return onError("could not resolve the Aave WETH address for the wrap leg");
        }
        legs.push({
          to: wethAddr,
          value: bigIntToHex(amount),
          data: WETH_DEPOSIT_DATA,
          rationale: `Unshield follow-up · wrap ${formatEth(amount)} ETH → WETH (WETH9.deposit)`,
        });
        if (approveLeg) legs.push(approveLeg);
        const actionLeg = frameToLeg(
          res.action,
          `Unshield follow-up · Aave V3 supply ${formatEth(amount)} WETH${res.summaryForConfirm ? ` — ${res.summaryForConfirm}` : ""}`,
        );
        if (!actionLeg) return onError("aave.prepare returned no supply frame");
        legs.push(actionLeg);
        onReady(legs, "unshielded ETH supplied to Aave V3 as WETH (Sepolia)");
      } else {
        const p = plan as Extract<DefiPlan, { kind: "aave-borrow" }>;
        const approveLeg = frameToLeg(
          res.approve,
          "Unshield follow-up · ERC-20 approval required by Aave",
        );
        if (approveLeg) legs.push(approveLeg);
        const actionLeg = frameToLeg(
          res.action,
          `Unshield follow-up · Aave V3 borrow ${p.amountHuman} ${p.asset.symbol} (variable rate)${res.summaryForConfirm ? ` — ${res.summaryForConfirm}` : ""}`,
        );
        if (!actionLeg) return onError("aave.prepare returned no borrow frame");
        legs.push(actionLeg);
        onReady(legs, `borrowed ${p.amountHuman} ${p.asset.symbol} from Aave V3 (Sepolia)`);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);
  return (
    <Layout
      title="Preparing Aave V3 frames…"
      subtitle="aave.prepare — reserve check + allowance read, no signature"
    >
      <Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>resolving the reserve and building calldata…</Text>
      </Text>
    </Layout>
  );
}
