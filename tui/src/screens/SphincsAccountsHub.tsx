import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { Layout, Banner } from "../widgets/Layout.js";
import Select from "../widgets/Select.js";
import Form, { Field } from "../widgets/Form.js";
import RpcRunner from "../widgets/RpcRunner.js";
import SendRawFlow from "./SendRawFlow.js";
import SwapFlow from "./SwapFlow.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";
import { EoaListEntry, ChainBalance } from "../types.js";
import { formatEth, hexToBigInt, shortAddr } from "../format.js";

/** Local TxJournal entry as returned by `chain.history`. Shape mirrors
 *  ManageWalletScreen's plus the SPHINCS+-specific timing fields the
 *  daemon's `executeSphincsUserOp` now appends (signMs/paramSet) so the
 *  history panel can surface how heavy each post-quantum sign was. */
type JournalEntry = {
  timestamp: number;
  txHash: string;
  from: string;
  to: string;
  valueWei: string;
  kind: string;
  status?: string;
  blockNumber?: string;
  /** Wall-clock duration of the SPHINCS+ shim call ("the grind"). Only
   *  present on kind = "sphincs.userOp" entries. */
  signMs?: number;
  /** SPHINCS+ parameter set ("C9", "JARDIN-Keccak-128-24", ...). Same
   *  scope as `signMs`. */
  paramSet?: string;
  /** Bundler-returned userOpHash. Same scope; lets users `getUserOp`
   *  this entry without parsing txHash semantics. */
  userOpHash?: string;
  /** L1 transaction hash that bundled this userOp. Set by the daemon's
   *  inclusion-status overlay once `sphincs.account.getUserOp` returns
   *  a receipt with `receipt.transactionHash`. Distinct from
   *  `userOpHash` (which is the 4337-level identifier, not lookupable
   *  on Etherscan as a normal tx). */
  inclusionTxHash?: string;
};

type HistoryCell =
  | { state: "loading" }
  | { state: "ok"; entries: JournalEntry[] }
  | { state: "err"; message: string };

/** Right-panel cap. The dedicated HistoryScreen behind the `h`
 *  shortcut shows the full list. */
const HISTORY_PANEL_LIMIT = 8;

type Account = {
  name: string;
  paramSet: string;
  chainId: number;
  ownerAddress: string;
  ecdsaAttachment:
    | { kind: "existing"; walletName: string; accountIndex: number }
    | { kind: "derived"; walletName: string; path: string };
  pkSeed: string;
  pkRoot: string;
  masterEnrolled: boolean;
  smartAccountAddress: string | null;
  customPassphrase: boolean;
  createdAt: number;
};

/** Sub-account ("cousin") within an EOA wallet, as returned by
 *  `eoa.account.list`. Mirrors `LeanKohaku.Wallet.EoaStore.Account.toJson`. */
type EoaAccount = {
  index: number;
  path: string;
  address: string;
  label?: string;
};

/** A built {to,value,data} blob coming out of `swap.uniV3.build`,
 *  normalized to the shape SendRawFlow expects (value as 0x-prefixed
 *  hex). The daemon emits `value` as either a JSON number or a string;
 *  `normalizeValueHex` handles the conversion. */
type SwapTxBlob = { to: string; value: string; data: string };

type State =
  | { kind: "loading" }
  | { kind: "list"; rows: Account[] }
  | { kind: "detail"; row: Account }
  | { kind: "compute-addr"; row: Account }
  | { kind: "deploy-pick-eoa"; row: Account; eoas: EoaListEntry[] }
  | { kind: "deploy-pick-account"; row: Account; eoa: EoaListEntry; accounts: EoaAccount[] }
  | { kind: "deploy-run"; row: Account; params: Record<string, unknown> }
  | { kind: "send-form"; row: Account }
  // Intermediate ENS-resolve step between send-form and send-run. We
  // hit `chain.resolveName` once and then advance to send-run with the
  // raw form values overridden by the resolved 0x address. Same
  // pattern (form → resolve → run) for rotateOwner.
  | { kind: "resolve-target"; row: Account; raw: string; nextKind: "send-run" | "rotate-owner-run"; pendingParams: Record<string, unknown>; field: "to" | "newOwner" }
  | { kind: "send-run"; row: Account; params: Record<string, unknown> }
  // `pendingCommit` is set when the rotation's newOwner is a locally-
  // derivable key (we proved it via `eoa.account.findByAddress`); once
  // the rotateOwner userOp lands successfully on-chain, the poll
  // screen auto-runs `sphincs.account.commitRotation` with these
  // values so the user never has to manually re-point the slot.
  | { kind: "poll-run"; row: Account; userOpHash: string; tick?: number;
      pendingCommit?: { newOwner: string; newWalletName: string; newAccountIndex: number };
      autoCommitted?: boolean }
  | { kind: "rotate-owner-form"; row: Account }
  | { kind: "rotate-owner-run"; row: Account; params: Record<string, unknown>;
      pendingCommit?: { newOwner: string; newWalletName: string; newAccountIndex: number } }
  | { kind: "commit-rotation-form"; row: Account }
  | { kind: "commit-rotation-run"; row: Account; params: Record<string, unknown> }
  | { kind: "factory-deploy-pick-eoa"; row: Account; eoas: EoaListEntry[] }
  | { kind: "factory-deploy-pick-account"; row: Account; eoa: EoaListEntry; accounts: EoaAccount[] }
  | { kind: "factory-deploy-run"; row: Account; params: Record<string, unknown> }
  // Swap pipeline: form → prepare (quote+build) → approve (SendRawFlow,
  // when needed) → exec (SendRawFlow) → done. Each leg is handed to
  // SendRawFlow with the SPHINCS wallet so we reuse its eth_call sim +
  // ConfirmGate UX; SendRawFlow's signer-kind switch routes the final
  // dispatch through `sphincs.account.send`.
  // The swap pipeline is now delegated to SwapFlow: it owns the chain /
  // token / amount / recipient pickers and the approve→swap two-step
  // (each leg through SendRawFlow). The previous bespoke
  // swap-form/swap-prepare/swap-approve/swap-exec/swap-done states were
  // replaced because they duplicated SwapFlow's UX with a less polished
  // text-input form and no recipient field.
  | { kind: "swap-flow"; row: Account }
  | { kind: "err"; message: string };

type Props = {
  onBack: () => void;
  /** When set, SphincsAccountsHub deep-links past the list/detail screens
   *  and lands directly on the named slot's send-form (`"send"`) or
   *  swap-form (`"swap"`). Used by the WalletsHub SEND/SWAP routing so
   *  SPHINCS picks skip the admin action menu. */
  initialAction?: "send" | "swap";
  initialName?: string;
};

const ADDR_RE = /^0x[0-9a-fA-F]{40}$/;
const HEX_RE  = /^(0x)?[0-9a-fA-F]*$/;

/** List + detail screen for SPHINCS- hybrid ERC-4337 accounts.
 *  Detail view exposes Compute-address / Deploy / Send actions, each
 *  routed through an RpcRunner so error surfaces match the rest of the
 *  TUI. Read-only fields and write actions share one record state. */
export default function SphincsAccountsHub({
  onBack,
  initialAction,
  initialName,
}: Props) {
  const [state, setState] = useState<State>({ kind: "loading" });
  // Track whether we entered via a deep-link from WalletsHub (SEND/SWAP
  // for a SPHINCS wallet). When true, esc on send-form/swap-form bubbles
  // straight to `onBack` instead of bouncing through the detail screen —
  // the detail screen wasn't part of this navigation chain.
  const deeplinkMode = !!(initialAction && initialName);
  // Lazily-populated per-slot deploy status, keyed by slot name. Probed
  // on entering the detail view (one eth_getCode per visit) so we can
  // grey out the "Deploy smart account" action when the contract is
  // already on chain. `undefined` = not probed yet; `null` = probe in
  // flight; concrete value = ready.
  const [deployStatus, setDeployStatus] = useState<Record<string, boolean | null | undefined>>({});
  // Per-slot active bundler URL (resolved via `sphincs.bundler.show`).
  // Same lifecycle as `deployStatus`: lazy-loaded on entry, cached per session.
  const [bundlerUrls, setBundlerUrls] = useState<Record<string, string | null | undefined>>({});
  // Per-slot smart-account balances. Keyed by slot name so re-entering
  // the detail view reuses the previous read instead of refetching on
  // every render. Two parallel probes:
  //   ethBalances[name]  — native ETH (bigint wei) or null while in flight
  //   tokenBalances[name] — non-zero ERC-20 rows from `swap.balances`
  // `undefined` = not probed; `null` = probe in flight; concrete value = ready.
  const [ethBalances, setEthBalances] =
    useState<Record<string, bigint | null | undefined>>({});
  const [tokenBalances, setTokenBalances] = useState<
    Record<
      string,
      | undefined
      | null
      | { symbol: string; address: string; decimals: number; balanceWei: bigint }[]
    >
  >({});
  // Per-slot recent-actions cache. Same lazy pattern as the balance probes
  // above — fired once on entering the detail view, refreshed only when
  // the user leaves and re-enters.
  const [historyCells, setHistoryCells] = useState<Record<string, HistoryCell>>({});

  const reload = async () => {
    setState({ kind: "loading" });
    const r = await call<{ accounts: Account[] }>("sphincs.account.list", {});
    if (!r.ok) {
      setState({ kind: "err", message: r.error?.message ?? "unknown error" });
      return;
    }
    const rows = r.result?.accounts ?? [];
    // Deep-link from WalletsHub: jump past the list/detail screens onto
    // the named slot's send-form / swap-form. If the slot vanished
    // between WalletsHub's enumeration and now (e.g. archived in another
    // process), gracefully fall back to the list view.
    if (initialAction && initialName) {
      const match = rows.find((row) => row.name === initialName);
      if (match) {
        if (initialAction === "send") {
          setState({ kind: "send-form", row: match });
          return;
        }
        if (initialAction === "swap") {
          setState({ kind: "swap-flow", row: match });
          return;
        }
      }
    }
    setState({ kind: "list", rows });
  };

  useEffect(() => { void reload(); }, []);

  // On entering the detail view for a slot, fire a single deployStatus
  // probe. Cached in `deployStatus[name]` so re-entering the same slot
  // doesn't re-hit the RPC unless the user explicitly triggers a
  // refresh (via re-entering from the list, which calls reload above).
  useEffect(() => {
    if (state.kind !== "detail") return;
    const name = state.row.name;
    if (deployStatus[name] !== undefined) return;
    setDeployStatus((prev) => ({ ...prev, [name]: null }));
    void (async () => {
      const r = await call<{ deployed?: boolean }>("sphincs.account.deployStatus", { name });
      setDeployStatus((prev) => ({
        ...prev,
        [name]: r.ok ? (r.result?.deployed === true) : false,
      }));
    })();
  }, [state.kind === "detail" ? state.row.name : null]);

  // Bundler URL probe. Same caching pattern as deployStatus.
  useEffect(() => {
    if (state.kind !== "detail") return;
    const name = state.row.name;
    if (bundlerUrls[name] !== undefined) return;
    setBundlerUrls((prev) => ({ ...prev, [name]: null }));
    void (async () => {
      const r = await call<{ bundler?: string | null }>("sphincs.bundler.show", { name });
      setBundlerUrls((prev) => ({
        ...prev,
        [name]: r.ok ? (r.result?.bundler ?? null) : null,
      }));
    })();
  }, [state.kind === "detail" ? state.row.name : null]);

  // Smart-account ETH + ERC-20 balance probe. Skips when the
  // counterfactual hasn't been computed yet (smartAccountAddress is
  // null) — there's no contract to balance-query, and the user is
  // already prompted to run "Compute counterfactual address". Runs once
  // per slot per session; "Send" / "Deploy" don't invalidate the cache,
  // so balances refresh by leaving the detail view and re-entering.
  useEffect(() => {
    if (state.kind !== "detail") return;
    const { name, smartAccountAddress, chainId } = state.row;
    if (!smartAccountAddress) return;
    if (ethBalances[name] !== undefined) return;
    setEthBalances((prev) => ({ ...prev, [name]: null }));
    setTokenBalances((prev) => ({ ...prev, [name]: null }));
    const chainParam =
      chainId === 1 ? "mainnet" : chainId === 11155111 ? "sepolia" : String(chainId);
    void (async () => {
      const eth = await call<ChainBalance>("chain.balance", {
        address: smartAccountAddress,
        chain: chainParam,
      });
      setEthBalances((prev) => ({
        ...prev,
        [name]: eth.ok ? hexToBigInt(eth.result?.balance) : 0n,
      }));
    })();
    void (async () => {
      const b = await call<{
        balances: Array<{
          symbol: string;
          address: string | null;
          decimals: number;
          balance: string;
        }>;
      }>("swap.balances", { chainId: String(chainId), address: smartAccountAddress });
      if (!b.ok) {
        setTokenBalances((prev) => ({ ...prev, [name]: [] }));
        return;
      }
      const rows = (b.result?.balances ?? [])
        .map((e) => ({
          symbol: String(e.symbol ?? "").toUpperCase(),
          address: typeof e.address === "string" ? e.address : null,
          decimals: typeof e.decimals === "number" ? e.decimals : 18,
          balanceWei: hexToBigInt(e.balance),
        }))
        .filter((t): t is { symbol: string; address: string; decimals: number; balanceWei: bigint } =>
          t.address !== null && t.balanceWei > 0n,
        )
        .sort((a, b) => (a.balanceWei > b.balanceWei ? -1 : a.balanceWei < b.balanceWei ? 1 : 0));
      setTokenBalances((prev) => ({ ...prev, [name]: rows }));
    })();
  }, [state.kind === "detail" ? state.row.name : null]);

  // Recent-actions probe. Mirrors ManageWalletScreen's TxJournal fan-out:
  // slot-scoped so any UserOp sent through this SPHINCS slot (send,
  // rotateOwner, deploy) shows up. Newest-last on disk → reverse for
  // display so the freshest is on top.
  useEffect(() => {
    if (state.kind !== "detail") return;
    const name = state.row.name;
    if (historyCells[name] !== undefined) return;
    setHistoryCells((prev) => ({ ...prev, [name]: { state: "loading" } }));
    void (async () => {
      const r = await call<JournalEntry[]>("chain.history", {
        name,
        limit: HISTORY_PANEL_LIMIT,
      });
      if (!r.ok) {
        setHistoryCells((prev) => ({
          ...prev,
          [name]: { state: "err", message: r.error.message },
        }));
        return;
      }
      const arr = Array.isArray(r.result) ? r.result : [];
      setHistoryCells((prev) => ({
        ...prev,
        [name]: { state: "ok", entries: [...arr].reverse() },
      }));
      // Backfill inclusion records for historical sphincs.userOp
      // entries that pre-date the inclusion-overlay pipeline. Each
      // unresolved entry triggers a single `sphincs.account.getUserOp`
      // (which writes a sphincs.inclusion record as a side effect when
      // the bundler returns a receipt). After all probes settle, we
      // reload chain.history once so the overlay picks up the new
      // records and the panel renders L1 tx hashes instead of
      // userOpHashes. Runs at most once per slot per session because
      // the outer effect's dependency array gates on slot name.
      const unresolved = arr.filter(
        (e) => e.kind === "sphincs.userOp" && e.userOpHash && !e.inclusionTxHash
      );
      if (unresolved.length === 0) return;
      await Promise.all(
        unresolved.map((e) =>
          call("sphincs.account.getUserOp", { userOpHash: e.userOpHash, name })
        )
      );
      const r2 = await call<JournalEntry[]>("chain.history", {
        name,
        limit: HISTORY_PANEL_LIMIT,
      });
      if (r2.ok && Array.isArray(r2.result)) {
        setHistoryCells((prev) => ({
          ...prev,
          [name]: { state: "ok", entries: [...r2.result].reverse() },
        }));
      }
    })();
  }, [state.kind === "detail" ? state.row.name : null]);

  // Owner-drift resync. On every detail-panel entry, fire the
  // `sphincs.account.resyncOwner` daemon RPC: it reads on-chain
  // `owner()`, compares to the slot's stored `ownerAddress`, and (when
  // the new owner is locally derivable + master KEK loaded) rewraps
  // the SPHINCS sk under the new AAD atomically. Replaces the old
  // TUI-side auto-commit that only fired when the user happened to be
  // on the poll-run screen at the moment the bundler reported
  // inclusion — if a rotateOwner UserOp landed while the user was
  // anywhere else (or the bundler's receipt query was slow), the
  // local slot stayed out of sync. With the daemon-side reconciler the
  // next visit to detail picks it up.
  //
  // Deliberately uncached: a single eth_call + file read is cheap, and
  // a stale cache would defeat the point. Status `resynced` triggers
  // a slot-list refetch so the panel shows the new owner / attachment
  // without bouncing the user back to the list.
  useEffect(() => {
    if (state.kind !== "detail") return;
    const name = state.row.name;
    void (async () => {
      const r = await call<{
        status?: string;
        newOwner?: string;
        newWalletName?: string;
        newAccountIndex?: number;
      }>("sphincs.account.resyncOwner", { name });
      if (!r.ok) return;
      if (r.result?.status !== "resynced") return;
      const list = await call<{ accounts: Account[] }>("sphincs.account.list", {});
      if (!list.ok || !Array.isArray(list.result?.accounts)) return;
      const updated = list.result.accounts.find((a) => a.name === name);
      if (updated) {
        // Re-fetch the row to pick up the new ownerAddress + attachment.
        // Stay on detail; the useEffects keyed on state.row.name see the
        // same name so they don't re-fire (we'd lose deployStatus /
        // bundler / balance / history caches otherwise).
        setState((prev) =>
          prev.kind === "detail" && prev.row.name === name
            ? { kind: "detail", row: updated }
            : prev,
        );
      }
    })();
  }, [state.kind === "detail" ? state.row.name : null]);

  useInput((input, key) => {
    if (key.escape || input === "q") {
      // Any sub-state → detail; detail or list → back/exit. When we
      // deep-linked into send-form/swap-form (no list/detail history),
      // esc bubbles to onBack so the user lands back on WalletsHub
      // instead of getting bounced into the admin menu they explicitly
      // skipped.
      if (state.kind === "detail" || state.kind === "list") onBack();
      else if (
        deeplinkMode &&
        (state.kind === "send-form" || state.kind === "swap-flow")
      ) {
        onBack();
      } else if ("row" in state) setState({ kind: "detail", row: state.row });
    }
  });

  if (state.kind === "loading") {
    return (
      <Layout title="SPHINCS- hybrid accounts" subtitle="loading…">
        <Text>
          <Text color={theme.primary}><Spinner type="dots" /></Text>{" "}
          <Text color={theme.dim}>sphincs.account.list</Text>
        </Text>
      </Layout>
    );
  }
  if (state.kind === "err") {
    return (
      <Layout title="SPHINCS- hybrid accounts" subtitle="error">
        <Text color={theme.err}>✗ {state.message}</Text>
        <Text color={theme.dim}>Press q to return.</Text>
      </Layout>
    );
  }

  if (state.kind === "compute-addr") {
    return (
      <RpcRunner
        title="Computing counterfactual smart-account address…"
        subtitle={`slot: ${state.row.name}`}
        method="sphincs.account.computeAddress"
        params={{ name: state.row.name }}
        renderResult={(r: any) => (
          <Box flexDirection="column">
            <Text color={theme.ok}>✓ address computed</Text>
            <Text color={theme.dim}>smartAccountAddress: <Text color={theme.primary}>{r?.smartAccountAddress}</Text></Text>
            <Text color={theme.dim}>factory: {r?.factory}</Text>
          </Box>
        )}
        onDone={() => void reload()}
      />
    );
  }

  if (state.kind === "deploy-pick-eoa") {
    if (state.eoas.length === 0) {
      return (
        <Layout title="Deploy SPHINCS- account" subtitle="no EOAs">
          <Text color={theme.warn}>No EOA wallet to fund the deploy. Create one first.</Text>
          <Text color={theme.dim}>esc / q back</Text>
        </Layout>
      );
    }
    const items = state.eoas.map((e) => ({
      label: `${e.name} — ${e.address}`,
      value: e,
    }));
    return (
      <Layout
        title="Deploy SPHINCS- account"
        subtitle={`Pick the EOA wallet that funds the factory.createAccount tx (slot: ${state.row.name})`}
        hint="↑/↓ move · → / enter select · esc back"
      >
        <Select
          items={items}
          arrowNav
          onBack={() => setState({ kind: "detail", row: state.row })}
          onSelect={async (it) => {
            const r = await call<{ accounts: EoaAccount[] }>("eoa.account.list", { name: it.value.name });
            const accounts = r.ok && r.result?.accounts ? r.result.accounts : [];
            if (accounts.length <= 1) {
              const idx = accounts[0]?.index ?? 0;
              setState({
                kind: "deploy-run",
                row: state.row,
                params: { name: state.row.name, deployerWallet: it.value.name, deployerAccountIndex: idx },
              });
            } else {
              setState({ kind: "deploy-pick-account", row: state.row, eoa: it.value, accounts });
            }
          }}
        />
      </Layout>
    );
  }

  if (state.kind === "deploy-pick-account") {
    const items = state.accounts.map((a) => ({
      label: `#${a.index}${a.label ? ` ${a.label}` : ""}  ${a.path}  ${a.address}`,
      value: a,
    }));
    return (
      <Layout
        title="Deploy SPHINCS- account"
        subtitle={`Pick the funding account inside ${state.eoa.name} (slot: ${state.row.name})`}
        hint="↑/↓ move · → / enter select · esc back"
      >
        <Select
          items={items}
          arrowNav
          onBack={() => setState({ kind: "deploy-pick-eoa", row: state.row, eoas: [state.eoa] })}
          onSelect={(it) => setState({
            kind: "deploy-run",
            row: state.row,
            params: {
              name: state.row.name,
              deployerWallet: state.eoa.name,
              deployerAccountIndex: it.value.index,
            },
          })}
        />
      </Layout>
    );
  }

  if (state.kind === "deploy-run") {
    return (
      <RpcRunner
        title="Deploying hybrid smart account…"
        subtitle={`slot: ${state.row.name} · funded by: ${(state.params as any).deployerWallet}#${(state.params as any).deployerAccountIndex ?? 0}`}
        method="sphincs.account.deploy"
        params={state.params}
        renderResult={(r: any) => (
          <Box flexDirection="column">
            <Text color={theme.ok}>✓ deploy tx broadcast</Text>
            <Text color={theme.dim}>smartAccountAddress: <Text color={theme.primary}>{r?.smartAccountAddress ?? "(check after tx mines)"}</Text></Text>
            <Text color={theme.dim}>txHash: {r?.tx?.txHash ?? "(unknown)"}</Text>
            <Text color={theme.dim}>factory: {r?.factory}</Text>
          </Box>
        )}
        onDone={() => void reload()}
      />
    );
  }

  if (state.kind === "send-form") {
    // The `to` field uses `kind: "recipient"` so the user can cycle
    // through their own wallets with ↑/↓ and the RecipientInput widget
    // tags self-matches. `excludeAddress` is the smart-account address
    // (the sender of every UserOp from this slot); falls back to the
    // ECDSA owner when the counterfactual hasn't been computed yet.
    // Validation is intentionally loose — any non-empty string is
    // accepted at form-submit time; ENS names like "vitalik.eth" get
    // resolved via `chain.resolveName` in the interstitial
    // `resolve-target` stage before the send RPC fires.
    const senderAddr = state.row.smartAccountAddress ?? state.row.ownerAddress;
    const fields: Field[] = [
      { name: "to", label: "Target (address, ENS name, or pick your own)",
        kind: "recipient", excludeAddress: senderAddr,
        validate: (v) => v.trim().length > 0 ? null : "required" },
      { name: "valueEth", label: "Value in ETH (decimal, e.g. 0.001)",
        initial: "0",
        // Loose validation — the daemon's LeanKohaku.Util.Units.parseUnits
        // is the source of truth for "is this a valid decimal-ETH amount".
        // We just reject the obvious garbage.
        validate: (v) => /^[0-9]+(\.[0-9]+)?$/.test(v.trim()) ? null : "decimal number expected (e.g. 0 or 0.001)" },
      { name: "data", label: "Calldata hex (optional, blank = pure ETH transfer)",
        validate: (v) => v.length === 0 || HEX_RE.test(v) ? null : "expected hex" },
      { name: "passphrase", label: "Per-slot passphrase (Enter if master KEK is loaded)",
        secret: true, validate: () => null },
    ];
    return (
      <Layout
        title={`Send UserOp · ${state.row.name}`}
        subtitle="Dual-signs (ECDSA owner + SPHINCS-) and submits via the configured bundler."
      >
        <Form
          fields={fields}
          onCancel={() => setState({ kind: "detail", row: state.row })}
          onSubmit={(v) => {
            // Pass `valueEth` straight through — the daemon's send RPC
            // calls `LeanKohaku.Util.Units.parseUnits ethStr 18` to get
            // the wei amount. TUI is a thin RPC forwarder; the
            // decimal-to-wei conversion deliberately stays Lean-side.
            const base: Record<string, unknown> = {
              name: state.row.name,
              valueEth: (v.valueEth ?? "0").trim(),
            };
            if (v.data && v.data.length > 0) base.data = v.data;
            if (v.passphrase && v.passphrase.length > 0) base.passphrase = v.passphrase;
            const raw = (v.to ?? "").trim();
            if (ADDR_RE.test(raw)) {
              // Already a 0x address — skip resolution.
              setState({ kind: "send-run", row: state.row, params: { ...base, to: raw } });
            } else {
              setState({
                kind: "resolve-target",
                row: state.row,
                raw,
                field: "to",
                nextKind: "send-run",
                pendingParams: base,
              });
            }
          }}
        />
      </Layout>
    );
  }

  if (state.kind === "resolve-target") {
    // Synchronous useEffect-style resolver inside a stage by chaining
    // an immediately-fired call from a tiny inline component. Reusing
    // the same chain.resolveName RPC SendFlow's ResolveStep calls.
    return (
      <ResolveStep
        raw={state.raw}
        onResolved={async (addr) => {
          const merged = { ...state.pendingParams, [state.field]: addr };
          if (state.nextKind === "send-run") setState({ kind: "send-run", row: state.row, params: merged });
          else {
            // Same local-key probe as the rotate-owner-form direct path,
            // so ENS-resolved addresses also benefit from auto-commit.
            const f = await call<{ found?: boolean; walletName?: string; accountIndex?: number }>(
              "eoa.account.findByAddress",
              { address: addr }
            );
            const pendingCommit =
              f.ok && f.result?.found
                ? {
                    newOwner: addr,
                    newWalletName: f.result.walletName!,
                    newAccountIndex: f.result.accountIndex ?? 0,
                  }
                : undefined;
            setState({ kind: "rotate-owner-run", row: state.row, params: merged, pendingCommit });
          }
        }}
        onError={(msg) => setState({ kind: "err", message: msg })}
      />
    );
  }

  if (state.kind === "send-run") {
    // Stash the submitted hash on the RpcRunner result so the user can
    // immediately follow up with the poll action via "successActions".
    let submittedHash: string | null = null;
    return (
      <RpcRunner
        title="Submitting UserOperation…"
        subtitle={`slot: ${state.row.name} · to: ${(state.params as any).to}`}
        method="sphincs.account.send"
        params={state.params}
        timeoutMs={15 * 60 * 1000}
        renderResult={(r: any) => {
          submittedHash = r?.userOpHash ?? null;
          return (
            <Box flexDirection="column">
              <Text color={theme.ok}>✓ userOp submitted</Text>
              <Text color={theme.dim} wrap="truncate-middle">
                userOpHash: <Text color={theme.primary}>{r?.userOpHash}</Text>
              </Text>
              <Text color={theme.dim} wrap="truncate-middle">sender: {r?.sender}</Text>
              <Text color={theme.dim} wrap="truncate-end">bundler: {r?.bundler}</Text>
              <Text color={theme.dim}>Enter to poll inclusion · Esc to dismiss</Text>
            </Box>
          );
        }}
        successActions={[
          {
            label: "Poll bundler for inclusion (eth_getUserOperationByHash)",
            onSelect: () => {
              if (submittedHash) setState({ kind: "poll-run", row: state.row, userOpHash: submittedHash });
              else setState({ kind: "detail", row: state.row });
            },
          },
          { label: "Back to account", onSelect: () => setState({ kind: "detail", row: state.row }) },
        ]}
        onDone={() => setState({ kind: "detail", row: state.row })}
      />
    );
  }

  if (state.kind === "poll-run") {
    // `key` forces a fresh RpcRunner mount on every "Poll again" tick,
    // because RpcRunner's fetch effect has an empty dependency array
    // and won't re-run on prop changes alone.
    const tick = state.tick ?? 0;
    return (
      <RpcRunner
        key={`poll-${state.userOpHash}-${tick}`}
        title="Polling bundler for inclusion…"
        subtitle={`userOpHash: ${state.userOpHash}`}
        method="sphincs.account.getUserOp"
        params={{ userOpHash: state.userOpHash, name: state.row.name }}
        renderResult={(r: any) => {
          const receipt = r?.receipt ?? null;
          const byHash = r?.info ?? null;
          const txHash = receipt?.receipt?.transactionHash ?? byHash?.transactionHash ?? null;
          const success = receipt?.success;
          const pendingCommit = state.pendingCommit;
          // Auto-commit a pending rotation once the on-chain side
          // succeeded. Guarded by `autoCommitted` so a "Poll again"
          // press doesn't re-fire commitRotation. The actual writeRecord
          // is idempotent on the daemon side, but skipping the second
          // call keeps the UI tidy.
          if (
            r?.included &&
            success !== false &&
            pendingCommit &&
            !state.autoCommitted
          ) {
            void (async () => {
              await call("sphincs.account.commitRotation", {
                name: state.row.name,
                newOwner: pendingCommit.newOwner,
                newWalletName: pendingCommit.newWalletName,
                newAccountIndex: pendingCommit.newAccountIndex,
              });
              setState((prev: State) =>
                prev.kind === "poll-run"
                  ? { ...prev, autoCommitted: true }
                  : prev
              );
            })();
          }
          return (
            <Box flexDirection="column">
              <Text color={theme.dim} wrap="truncate-middle">
                userOpHash: <Text color={theme.primary}>{r?.userOpHash}</Text>
              </Text>
              {r?.included ? (
                <>
                  <Text color={success === false ? theme.warn : theme.ok}>
                    {success === false ? "⚠ included, but reverted on-chain" : "✓ included on-chain"}
                  </Text>
                  {txHash && (
                    <Text color={theme.dim} wrap="truncate-middle">
                      tx: <Text color={theme.primary}>{txHash}</Text>
                    </Text>
                  )}
                  {pendingCommit && success !== false && (
                    state.autoCommitted ? (
                      <Text color={theme.ok}>
                        ✓ local slot updated to {pendingCommit.newWalletName}#{pendingCommit.newAccountIndex}
                      </Text>
                    ) : (
                      <Text color={theme.dim}>committing rotation to local store…</Text>
                    )
                  )}
                </>
              ) : (
                <Text color={theme.warn}>⏳ still pending — poll again in a few seconds</Text>
              )}
            </Box>
          );
        }}
        successActions={[
          { label: "Poll again", onSelect: () => setState({
              kind: "poll-run",
              row: state.row,
              userOpHash: state.userOpHash,
              tick: tick + 1,
              pendingCommit: state.pendingCommit,
              autoCommitted: state.autoCommitted,
            }) },
          { label: "Back to account", onSelect: () => setState({ kind: "detail", row: state.row }) },
        ]}
        onDone={() => setState({ kind: "detail", row: state.row })}
      />
    );
  }

  if (state.kind === "factory-deploy-pick-eoa") {
    if (state.eoas.length === 0) {
      return (
        <Layout title="Deploy SPHINCS- factory" subtitle="no EOAs">
          <Text color={theme.warn}>No EOA wallet to fund the factory deploy. Create one first.</Text>
          <Text color={theme.dim}>esc / q back</Text>
        </Layout>
      );
    }
    const items = state.eoas.map((e) => ({
      label: `${e.name} — ${e.address}`,
      value: e,
    }));
    return (
      <Layout
        title="Deploy SPHINCS- factory (Sepolia)"
        subtitle={`paramSet: ${state.row.paramSet}. Pick the EOA wallet that funds the deploy.`}
        hint="↑/↓ move · → / enter select · esc back"
      >
        <Select
          items={items}
          arrowNav
          onBack={() => setState({ kind: "detail", row: state.row })}
          onSelect={async (it) => {
            const r = await call<{ accounts: EoaAccount[] }>("eoa.account.list", { name: it.value.name });
            const accounts = r.ok && r.result?.accounts ? r.result.accounts : [];
            if (accounts.length <= 1) {
              const idx = accounts[0]?.index ?? 0;
              setState({
                kind: "factory-deploy-run",
                row: state.row,
                params: {
                  paramSet: state.row.paramSet,
                  deployerWallet: it.value.name,
                  deployerAccountIndex: idx,
                  chain: "sepolia",
                },
              });
            } else {
              setState({ kind: "factory-deploy-pick-account", row: state.row, eoa: it.value, accounts });
            }
          }}
        />
      </Layout>
    );
  }

  if (state.kind === "factory-deploy-pick-account") {
    const items = state.accounts.map((a) => ({
      label: `#${a.index}${a.label ? ` ${a.label}` : ""}  ${a.path}  ${a.address}`,
      value: a,
    }));
    return (
      <Layout
        title="Deploy SPHINCS- factory (Sepolia)"
        subtitle={`Pick the funding account inside ${state.eoa.name} (paramSet: ${state.row.paramSet})`}
        hint="↑/↓ move · → / enter select · esc back"
      >
        <Select
          items={items}
          arrowNav
          onBack={() => setState({ kind: "factory-deploy-pick-eoa", row: state.row, eoas: [state.eoa] })}
          onSelect={(it) => setState({
            kind: "factory-deploy-run",
            row: state.row,
            params: {
              paramSet: state.row.paramSet,
              deployerWallet: state.eoa.name,
              deployerAccountIndex: it.value.index,
              chain: "sepolia",
            },
          })}
        />
      </Layout>
    );
  }

  if (state.kind === "factory-deploy-run") {
    return (
      <RpcRunner
        title="Deploying SPHINCS- factory…"
        subtitle={`paramSet: ${(state.params as any).paramSet} · funded by: ${(state.params as any).deployerWallet}#${(state.params as any).deployerAccountIndex ?? 0}`}
        method="sphincs.factory.deploy"
        params={state.params}
        timeoutMs={5 * 60 * 1000}
        renderResult={(r: any) => (
          <Box flexDirection="column">
            <Text color={theme.ok}>✓ factory deploy completed (exitCode {r?.exitCode ?? "?"})</Text>
            <Text color={theme.dim}>factory: <Text color={theme.primary}>{r?.factory ?? "(not parsed from output)"}</Text></Text>
            <Text color={theme.dim}>verifier: {r?.verifier}</Text>
            <Text color={theme.warn}>
              ⚠ Add this address to daemon.json under sphincs_factories.sepolia.{(state.params as any).paramSet} so future RPCs see it.
            </Text>
          </Box>
        )}
        onDone={() => setState({ kind: "detail", row: state.row })}
      />
    );
  }

  if (state.kind === "rotate-owner-form") {
    // Same ENS-friendly pattern as the send form: pick from own
    // wallets via RecipientInput, fall through to resolve-target when
    // the input isn't already a 0x address.
    const senderAddr = state.row.smartAccountAddress ?? state.row.ownerAddress;
    const fields: Field[] = [
      { name: "newOwner", label: "New ECDSA owner (address, ENS, or your own)",
        kind: "recipient", excludeAddress: senderAddr,
        validate: (v) => v.trim().length > 0 ? null : "required" },
      { name: "passphrase", label: "Per-slot passphrase (Enter if master KEK is loaded)",
        secret: true, validate: () => null },
    ];
    return (
      <Layout
        title={`Rotate owner · ${state.row.name}`}
        subtitle="On-chain ECDSA owner swap. If the new owner is locally derivable, the slot auto-updates after the userOp lands."
      >
        <Form
          fields={fields}
          onCancel={() => setState({ kind: "detail", row: state.row })}
          onSubmit={async (v) => {
            const base: Record<string, unknown> = {
              name: state.row.name,
            };
            if (v.passphrase && v.passphrase.length > 0) base.passphrase = v.passphrase;
            const raw = (v.newOwner ?? "").trim();
            // Resolve ENS → address before we ask the daemon if it's a
            // local key (findByAddress matches on 0x form only).
            const resolved: string | null = ADDR_RE.test(raw) ? raw : null;
            if (resolved === null) {
              setState({
                kind: "resolve-target",
                row: state.row,
                raw,
                field: "newOwner",
                nextKind: "rotate-owner-run",
                pendingParams: base,
              });
              return;
            }
            // Probe local seeds: if the address is derivable from one
            // of our wallets, stash the (walletName, accountIndex) so
            // the poll screen can auto-commit on success. If not, the
            // user is rotating to an external key — we still submit
            // but the slot will be unusable for sends afterward
            // (commit-rotation can fix it later if they re-attach).
            const f = await call<{ found?: boolean; walletName?: string; accountIndex?: number }>(
              "eoa.account.findByAddress",
              { address: resolved }
            );
            const pendingCommit =
              f.ok && f.result?.found
                ? {
                    newOwner: resolved,
                    newWalletName: f.result.walletName!,
                    newAccountIndex: f.result.accountIndex ?? 0,
                  }
                : undefined;
            setState({
              kind: "rotate-owner-run",
              row: state.row,
              params: { ...base, newOwner: resolved },
              pendingCommit,
            });
          }}
        />
      </Layout>
    );
  }

  if (state.kind === "rotate-owner-run") {
    let submittedHash: string | null = null;
    const pendingCommit = state.pendingCommit;
    return (
      <RpcRunner
        title="Rotating on-chain ECDSA owner…"
        subtitle={`slot: ${state.row.name} · new: ${(state.params as any).newOwner}`}
        method="sphincs.account.rotateOwner"
        params={state.params}
        timeoutMs={15 * 60 * 1000}
        renderResult={(r: any) => {
          submittedHash = r?.userOpHash ?? null;
          return (
            <Box flexDirection="column">
              <Text color={theme.ok}>✓ rotateOwner userOp submitted</Text>
              <Text color={theme.dim}>userOpHash: <Text color={theme.primary}>{r?.userOpHash}</Text></Text>
              <Text color={theme.dim}>newOwner: {r?.newOwner}</Text>
              {pendingCommit ? (
                <Text color={theme.ok}>
                  → new owner is locally derivable ({pendingCommit.newWalletName}#{pendingCommit.newAccountIndex});
                  slot will auto-update once the userOp is included.
                </Text>
              ) : (
                <Text color={theme.warn}>
                  ⚠ new owner is NOT locally derivable — after this lands, the slot
                  will be unusable for sends until you re-attach a local key.
                </Text>
              )}
            </Box>
          );
        }}
        successActions={[
          {
            label: "Poll bundler for inclusion",
            onSelect: () => {
              if (submittedHash) {
                setState({
                  kind: "poll-run",
                  row: state.row,
                  userOpHash: submittedHash,
                  pendingCommit,
                });
              }
              else setState({ kind: "detail", row: state.row });
            },
          },
          { label: "Back to account", onSelect: () => setState({ kind: "detail", row: state.row }) },
        ]}
        onDone={() => setState({ kind: "detail", row: state.row })}
      />
    );
  }

  if (state.kind === "commit-rotation-form") {
    // Rewrites the slot's ecdsaAttachment so subsequent userOps sign
    // ECDSA-half with the new owner key. The daemon verifies the
    // on-chain owner() before writing, so this fails closed if the
    // rotateOwner userOp didn't actually land.
    const fields: Field[] = [
      { name: "newOwner", label: "New ECDSA owner address (must match on-chain owner())",
        validate: (v) => ADDR_RE.test(v.trim()) ? null : "must be a 0x… address" },
      { name: "newWalletName", label: "Local EOA wallet that owns the new key",
        validate: (v) => v.trim().length > 0 ? null : "required" },
      { name: "newAccountIndex", label: "Account index in that wallet (default 0)",
        validate: () => null },
      // Recovery-only: leave blank for normal use. Set to the slot's
      // ORIGINAL owner address if an earlier commit-rotation attempt
      // rewrote `ownerAddress` on disk without re-wrapping the SPHINCS
      // sk (the wrap is still keyed to the original owner). The daemon
      // uses this as the AAD when unwrapping, then re-seals under the
      // current ownerAddress on success.
      { name: "oldOwner", label: "[recovery] original owner before any prior commit-rotation (blank if first commit)",
        validate: (v) => {
          const t = v.trim();
          if (t.length === 0) return null;
          return ADDR_RE.test(t) ? null : "must be a 0x… address or blank";
        } },
    ];
    return (
      <Layout
        title={`Commit owner rotation · ${state.row.name}`}
        subtitle="Atomic local-store update. Daemon verifies on-chain owner() before writing."
      >
        <Form
          fields={fields}
          onCancel={() => setState({ kind: "detail", row: state.row })}
          onSubmit={(v) => {
            const idxRaw = (v.newAccountIndex ?? "").trim();
            const idx = idxRaw === "" ? 0 : Number.parseInt(idxRaw, 10);
            const oldOwner = (v.oldOwner ?? "").trim();
            const params: Record<string, unknown> = {
              name: state.row.name,
              newOwner: (v.newOwner ?? "").trim(),
              newWalletName: (v.newWalletName ?? "").trim(),
              newAccountIndex: Number.isFinite(idx) ? idx : 0,
            };
            if (oldOwner.length > 0) params.oldOwner = oldOwner;
            setState({ kind: "commit-rotation-run", row: state.row, params });
          }}
        />
      </Layout>
    );
  }

  if (state.kind === "commit-rotation-run") {
    return (
      <RpcRunner
        title="Committing rotation to local store…"
        subtitle={`slot: ${state.row.name}`}
        method="sphincs.account.commitRotation"
        params={state.params}
        renderResult={(r: any) => (
          <Box flexDirection="column">
            <Text color={theme.ok}>✓ slot updated</Text>
            <Text color={theme.dim}>newOwner: <Text color={theme.primary}>{r?.newOwner}</Text></Text>
            <Text color={theme.dim}>newWalletName: {r?.newWalletName} (#{r?.newAccountIndex ?? 0})</Text>
            <Text color={theme.dim}>on-chain owner() verified: {r?.onChainOwnerVerified ? "yes" : "no"}</Text>
          </Box>
        )}
        successActions={[
          { label: "Back to account", onSelect: () => setState({ kind: "detail", row: state.row }) },
        ]}
        onDone={() => setState({ kind: "detail", row: state.row })}
      />
    );
  }

  // --- Swap pipeline: delegated entirely to SwapFlow ---
  //
  // SwapFlow owns chain selection, token pickers (tokenIn / tokenOut),
  // balance display, amount entry, recipient entry, slippage, the
  // approve→swap two-step, and final dispatch. We pass the SPHINCS
  // smart-account as the `wallet` and SendRawFlow's existing
  // `kind === "sphincs"` branch routes through `sphincs.account.send`
  // for both approval and swap legs.
  if (state.kind === "swap-flow") {
    const r = state.row;
    return (
      <SwapFlow
        wallet={{
          kind: "sphincs",
          name: r.name,
          address: r.smartAccountAddress ?? r.ownerAddress,
        }}
        onDone={() => {
          if (deeplinkMode) onBack();
          else setState({ kind: "detail", row: r });
        }}
      />
    );
  }

  if (state.kind === "detail") {
    const r = state.row;
    const attach =
      r.ecdsaAttachment.kind === "existing"
        ? `existing ${r.ecdsaAttachment.walletName} (#${r.ecdsaAttachment.accountIndex})`
        : `derived ${r.ecdsaAttachment.walletName} (${r.ecdsaAttachment.path})`;
    type Action = "compute" | "deploy" | "send" | "swap" | "rotate-owner" | "commit-rotation" | "factory-deploy" | "back";
    const status = deployStatus[r.name];
    const isDeployed = status === true;
    const probePending = status === null;
    // Build the action list dynamically: when the smart-account is
    // already on-chain we hide "Deploy smart account" outright (it
    // would always revert at first-send-also-deploy initCode anyway).
    // While the probe is in flight we show the action but tag it
    // "(checking…)" so the user knows the gate is being computed.
    const actions: { label: string; value: Action }[] = [];
    actions.push({ label: "Compute counterfactual address (eth_call factory.getAddress)", value: "compute" });
    if (!isDeployed) {
      actions.push({
        label: probePending
          ? "Deploy smart account via factory.createAccount (checking…)"
          : "Deploy smart account via factory.createAccount",
        value: "deploy",
      });
    }
    actions.push({ label: "Send UserOperation via configured bundler", value: "send" });
    actions.push({ label: "Swap via Uniswap V3 (token + recipient picker)", value: "swap" });
    actions.push({ label: "Rotate on-chain ECDSA owner (rotateOwner UserOp)", value: "rotate-owner" });
    actions.push({ label: "Commit owner rotation in local store (point slot at new EOA)", value: "commit-rotation" });
    actions.push({ label: "Deploy the SPHINCS- factory (one-time, Sepolia)", value: "factory-deploy" });
    actions.push({ label: "← Back", value: "back" });
    return (
      <Layout
        title={`SPHINCS- account · ${r.name}`}
        subtitle={`paramSet: ${r.paramSet} · chainId: ${r.chainId}`}
        hint="↑/↓ move · → / enter select · esc back"
      >
        <Box flexDirection="row">
          <Box flexDirection="column" flexGrow={1} flexBasis={0} minWidth={0}>
            <Text color={theme.dim}>owner (ECDSA): <Text color={theme.primary}>{r.ownerAddress}</Text></Text>
            <Text color={theme.dim}>ECDSA source: {attach}</Text>
            <Text color={theme.dim}>pkSeed: <Text>{r.pkSeed}</Text></Text>
            <Text color={theme.dim}>pkRoot: <Text>{r.pkRoot}</Text></Text>
            <Text color={theme.dim}>master-enrolled: {r.masterEnrolled ? "yes" : "no"}</Text>
            <Text color={theme.dim}>custom passphrase: {r.customPassphrase ? "yes" : "no"}</Text>
            <Text color={theme.dim}>
              smart-account addr: {r.smartAccountAddress ?? "(pending compute)"}
            </Text>
            <Text color={theme.dim}>
              on-chain status:{" "}
              {status === undefined || status === null
                ? <Text color={theme.dim}>checking…</Text>
                : status
                  ? <Text color={theme.ok}>deployed</Text>
                  : <Text color={theme.warn}>not deployed</Text>}
            </Text>
            <SmartAcctBalances
              ethWei={r.smartAccountAddress ? ethBalances[r.name] : undefined}
              tokens={r.smartAccountAddress ? tokenBalances[r.name] : undefined}
              hasAddress={!!r.smartAccountAddress}
            />
            <Text color={theme.dim}>created: {new Date(r.createdAt * 1000).toISOString()}</Text>
            <Text color={theme.dim}>
              bundler:{" "}
              {bundlerUrls[r.name] === undefined || bundlerUrls[r.name] === null
                ? <Text color={theme.dim}>(checking…)</Text>
                : <Text color={theme.primary}>{bundlerUrls[r.name]}</Text>}
            </Text>
            <Box marginTop={1}>
              <Select
                items={actions}
                arrowNav
                onBack={onBack}
                onSelect={async (it) => {
                  if (it.value === "back") onBack();
                  else if (it.value === "compute") setState({ kind: "compute-addr", row: r });
                  else if (it.value === "deploy") {
                    const er = await call<EoaListEntry[]>("eoa.list", {});
                    setState({
                      kind: "deploy-pick-eoa",
                      row: r,
                      eoas: er.ok && Array.isArray(er.result) ? er.result : [],
                    });
                  } else if (it.value === "send") setState({ kind: "send-form", row: r });
                  else if (it.value === "swap") setState({ kind: "swap-flow", row: r });
                  else if (it.value === "rotate-owner") setState({ kind: "rotate-owner-form", row: r });
                  else if (it.value === "commit-rotation") setState({ kind: "commit-rotation-form", row: r });
                  else {
                    const er = await call<EoaListEntry[]>("eoa.list", {});
                    setState({
                      kind: "factory-deploy-pick-eoa",
                      row: r,
                      eoas: er.ok && Array.isArray(er.result) ? er.result : [],
                    });
                  }
                }}
              />
            </Box>
          </Box>
          <Box
            marginLeft={2}
            flexDirection="column"
            flexGrow={1}
            flexBasis={0}
            minWidth={0}
          >
            <HistoryPanel history={historyCells[r.name] ?? { state: "loading" }} />
          </Box>
        </Box>
      </Layout>
    );
  }

  // state.kind === "list"
  if (state.rows.length === 0) {
    return (
      <Layout title="SPHINCS- hybrid accounts" subtitle="(empty)">
        <Text color={theme.dim}>
          No hybrid accounts yet. Create one via "Create wallet →
          SPHINCS- hybrid".
        </Text>
        <Text color={theme.dim}>Press q to return.</Text>
      </Layout>
    );
  }
  // A smart-account's identity is its CREATE2 contract address (the
  // `sender` field every UserOp targets). Fall back to the ECDSA owner
  // only when the counterfactual hasn't been computed yet — that row
  // visibly prompts the user to run "Compute counterfactual address".
  const items = state.rows.map((r) => {
    const id = r.smartAccountAddress;
    const idStr = id
      ? `${id.slice(0, 10)}…${id.slice(-6)}`
      : `(pending — owner ${r.ownerAddress.slice(0, 10)}…${r.ownerAddress.slice(-6)})`;
    return {
      label: `${r.name} — ${r.paramSet} — ${idStr}`,
      value: r,
    };
  });
  return (
    <Layout
      title="SPHINCS- hybrid accounts"
      subtitle={`${state.rows.length} slot${state.rows.length === 1 ? "" : "s"}`}
      hint="↑/↓ move · → / enter detail · esc back"
    >
      <Select
        items={items}
        arrowNav
        onBack={onBack}
        onSelect={(it) => setState({ kind: "detail", row: it.value })}
      />
    </Layout>
  );
}

/** Resolves an ENS-like input via the daemon's `chain.resolveName` RPC
 *  and forwards the resulting 0x address to the caller. Mirrors the
 *  inline ResolveStep helper in `SendFlow.tsx` so the SPHINCS path
 *  surfaces ENS errors with the same shape. */
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
      if (!r.ok) return onError(`ENS resolve failed: ${r.error?.message ?? "unknown"}`);
      const addr = r.result?.address;
      const ADDR_RE = /^0x[0-9a-fA-F]{40}$/;
      if (!addr || !ADDR_RE.test(addr)) {
        return onError(`'${raw}' did not resolve to a 0x address`);
      }
      onResolved(addr);
    });
    return () => { cancelled = true; };
  }, []);
  return (
    <Layout title={`Resolving ${raw}…`}>
      <Text>
        <Text color={theme.primary}><Spinner type="dots" /></Text>{" "}
        <Text color={theme.dim}>chain.resolveName</Text>
      </Text>
    </Layout>
  );
}

/** Render the smart-account's on-chain ETH + ERC-20 balances. The probe
 *  ran (or didn't, if the counterfactual address is still pending) in
 *  the detail-view effect; this component just decodes the cell state.
 *  Token rows are filtered to non-zero balances daemon-side — same rule
 *  as ManageWalletScreen's Tokens section. */
function SmartAcctBalances({
  ethWei,
  tokens,
  hasAddress,
}: {
  ethWei: bigint | null | undefined;
  tokens:
    | undefined
    | null
    | { symbol: string; address: string; decimals: number; balanceWei: bigint }[];
  hasAddress: boolean;
}) {
  if (!hasAddress) {
    return (
      <Text color={theme.dim}>
        balances: <Text color={theme.warn}>(compute counterfactual first)</Text>
      </Text>
    );
  }
  const ethLine =
    ethWei === undefined || ethWei === null ? (
      <Text>
        <Text color={theme.primary}><Spinner type="dots" /></Text>
        <Text color={theme.dim}>{" reading…"}</Text>
      </Text>
    ) : (
      <Text>{formatEth(ethWei)}</Text>
    );
  return (
    <Box flexDirection="column">
      <Text>
        <Text color={theme.dim}>ETH balance: </Text>
        {ethLine}
      </Text>
      <Box flexDirection="column">
        <Text color={theme.dim}>
          ERC-20 (swap registry):{" "}
          {tokens === undefined || tokens === null ? (
            <>
              <Text color={theme.primary}><Spinner type="dots" /></Text>
              <Text color={theme.dim}>{" fanning out balanceOf…"}</Text>
            </>
          ) : tokens.length === 0 ? (
            <Text color={theme.dim}>none</Text>
          ) : null}
        </Text>
        {tokens && tokens.length > 0 &&
          tokens.map((t) => (
            <Text key={t.address}>
              <Text color={theme.dim}>{"  · "}</Text>
              <Text color={theme.accent}>{t.symbol.padEnd(8)}</Text>
              <Text>{" "}{formatTokenAmount(t.balanceWei, t.decimals)}</Text>
              <Text color={theme.dim}>{"  "}{t.address}</Text>
            </Text>
          ))}
      </Box>
    </Box>
  );
}

/** Truncating fixed-decimals formatter — symmetric with
 *  ManageWalletScreen's local `formatTokenAmount`. Kept inline rather
 *  than imported to avoid pulling a sibling screen for one helper. */
function formatTokenAmount(amount: bigint, decimals: number): string {
  if (decimals === 0) return amount.toString();
  const base = 10n ** BigInt(decimals);
  const whole = amount / base;
  const frac = amount % base;
  if (frac === 0n) return whole.toString();
  let fracStr = frac.toString().padStart(decimals, "0");
  if (fracStr.length > 6) fracStr = fracStr.slice(0, 6);
  fracStr = fracStr.replace(/0+$/, "");
  return fracStr.length === 0 ? whole.toString() : `${whole.toString()}.${fracStr}`;
}

/** Right-side recent-actions panel. Sources from `chain.history` (the
 *  local TxJournal). Mirrors ManageWalletScreen's panel so the SPHINCS
 *  detail view picks up parity with the EOA manage screen. */
function HistoryPanel({ history }: { history: HistoryCell }) {
  return (
    <Box flexDirection="column">
      <Text color={theme.primary} bold>
        Recent actions
      </Text>
      <Text color={theme.dim}>(local journal · slot-scoped)</Text>
      {history.state === "loading" && (
        <Box marginTop={1}>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>
          <Text color={theme.dim}>{" reading journal…"}</Text>
        </Box>
      )}
      {history.state === "err" && (
        <Box marginTop={1}>
          <Banner kind="err" text={`chain.history failed: ${history.message}`} />
        </Box>
      )}
      {history.state === "ok" && history.entries.length === 0 && (
        <Box marginTop={1}>
          <Text color={theme.dim}>no journal entries for this slot yet.</Text>
        </Box>
      )}
      {history.state === "ok" && history.entries.length > 0 && (
        <Box flexDirection="column" marginTop={1}>
          {history.entries.map((e, i) => (
            <CompactHistoryRow key={i} entry={e} />
          ))}
        </Box>
      )}
    </Box>
  );
}

/** Compact row for the SPHINCS detail panel. Adds a fourth "grind" line
 *  when the entry is a SPHINCS+ UserOp — surfaces sign duration + the
 *  parameter set so the user can see how heavy C9 / JARDIN signing was
 *  at submission time. */
function CompactHistoryRow({ entry }: { entry: JournalEntry }) {
  const status = entry.status ?? "?";
  const glyph = status === "success" ? "✓" : status === "revert" ? "✗" : "·";
  const glyphColor =
    status === "success" ? theme.ok : status === "revert" ? theme.err : theme.warn;
  let valueWei = 0n;
  try {
    valueWei = entry.valueWei ? BigInt(entry.valueWei) : 0n;
  } catch {}
  const when =
    entry.timestamp > 0
      ? new Date(entry.timestamp * 1000).toISOString().slice(0, 16).replace("T", " ")
      : "";
  const isSphincs = entry.kind === "sphincs.userOp";
  const grindLine =
    isSphincs && (entry.signMs !== undefined || entry.paramSet)
      ? `sign ${entry.signMs ?? "?"}ms${entry.paramSet ? ` · ${entry.paramSet}` : ""}`
      : null;
  return (
    <Box flexDirection="column" marginBottom={1}>
      <Box>
        <Text color={glyphColor} bold>
          {glyph}
        </Text>
        <Text> </Text>
        <Text color={theme.accent}>{entry.kind || "?"}</Text>
        {valueWei > 0n && (
          <>
            <Text>{"  "}</Text>
            <Text bold color={theme.primary}>
              {formatEth(valueWei)}
            </Text>
          </>
        )}
        {when && (
          <>
            <Text>{"  "}</Text>
            <Text color={theme.dim}>{when}</Text>
          </>
        )}
      </Box>
      {entry.to && (
        <Box>
          <Text color={theme.dim}>{"  to "}</Text>
          <Text>{entry.to}</Text>
        </Box>
      )}
      {/* For SPHINCS userOps the bundler's userOpHash and the on-chain
          L1 tx hash are different. `inclusionTxHash` (set after a
          successful poll) is the L1 hash you can paste into Etherscan.
          Falls back to `txHash` (which is the userOpHash for SPHINCS
          entries before resolution, or the L1 tx for EOA entries). */}
      {entry.inclusionTxHash ? (
        <Box>
          <Text color={theme.dim}>{"  tx "}</Text>
          <Text color={theme.dim}>{entry.inclusionTxHash}</Text>
        </Box>
      ) : entry.txHash && (
        <Box flexDirection="column">
          <Box>
            <Text color={theme.dim}>{isSphincs ? "  userOpHash " : "  tx "}</Text>
            <Text color={theme.dim}>{entry.txHash}</Text>
          </Box>
        </Box>
      )}
      {grindLine && (
        <Box>
          <Text color={theme.dim}>{"  ⚙ "}</Text>
          <Text color={theme.primary}>{grindLine}</Text>
        </Box>
      )}
    </Box>
  );
}

/** Single-purpose registry-token shape; same fields as SwapFlow's
 *  `DaemonToken`. Kept inline to avoid pulling SwapFlow's whole module
 *  for one type. */
type RegistryToken = {
  symbol: string;
  name: string;
  address: string;
  decimals: number;
};

/** Resolve `symbol` to its decimals using the registry. ETH is hard-coded
 *  to 18 (the daemon's swap RPCs accept "ETH" and map it to WETH
 *  internally, but the user's amount is still in ETH = 18 decimals). */
function decimalsFor(symbol: string, registry: RegistryToken[]): number | null {
  const s = symbol.trim().toUpperCase();
  if (s === "ETH") return 18;
  const t = registry.find((x) => x.symbol.toUpperCase() === s);
  return t ? t.decimals : null;
}

/** Parse a decimal string into base units (no JS Number — BigInt only).
 *  Returns null on malformed input or too-many fractional digits. */
function parseBaseUnits(s: string, decimals: number): bigint | null {
  if (!/^[0-9]+(\.[0-9]+)?$/.test(s)) return null;
  const [whole, frac = ""] = s.split(".");
  if (frac.length > decimals) return null;
  const padded = (frac + "0".repeat(decimals)).slice(0, decimals);
  return BigInt(whole || "0") * 10n ** BigInt(decimals) + BigInt(padded || "0");
}

/** Format base units → trimmed decimal string for display. Caps fraction
 *  digits to 6 so summary lines stay narrow. */
function formatBaseUnitsShort(amount: bigint, decimals: number): string {
  if (decimals === 0) return amount.toString();
  const base = 10n ** BigInt(decimals);
  const whole = amount / base;
  const frac = amount % base;
  if (frac === 0n) return whole.toString();
  let fracStr = frac.toString().padStart(decimals, "0");
  if (fracStr.length > 6) fracStr = fracStr.slice(0, 6);
  fracStr = fracStr.replace(/0+$/, "");
  return fracStr.length === 0 ? whole.toString() : `${whole.toString()}.${fracStr}`;
}

/** Normalize `swap.uniV3.build`'s `tx.value` (sometimes JSON num, sometimes
 *  string, sometimes bigint) into a 0x-prefixed hex string — the shape
 *  SendRawFlow expects on its `tx.value` prop. SendRawFlow re-parses to
 *  bigint via `hexToBigInt` before dispatch, so any extra leading zeros
 *  or different casings normalize cleanly. */
function normalizeValueHex(v: unknown): string {
  if (v === null || v === undefined) return "0x0";
  if (typeof v === "string") {
    if (v.startsWith("0x") || v.startsWith("0X")) return v;
    try { return "0x" + BigInt(v).toString(16); } catch { return "0x0"; }
  }
  if (typeof v === "number") return "0x" + BigInt(v).toString(16);
  if (typeof v === "bigint") return "0x" + v.toString(16);
  return "0x0";
}

/** Quote + build pipeline. Runs three daemon RPCs in sequence:
 *    1. `swap.tokens.list`  — get token decimals
 *    2. `swap.uniV3.quote`  — get amountOut for slippage math
 *    3. `swap.uniV3.build`  — get the actual {to,value,data} for swap + (optional) approval
 *  Then hands the normalized blobs + a human summary to the parent. */
function SwapPrepareStep({
  row,
  tokenIn,
  tokenOut,
  amountDec,
  fee,
  slippageBps,
  onReady,
  onError,
}: {
  row: Account;
  tokenIn: string;
  tokenOut: string;
  amountDec: string;
  fee: number;
  slippageBps: number;
  onReady: (
    approval: SwapTxBlob | null,
    swap: SwapTxBlob,
    summary: string,
  ) => void;
  onError: (message: string) => void;
}) {
  const [status, setStatus] = useState<string>("Loading token registry…");

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const chainName =
        row.chainId === 1
          ? "mainnet"
          : row.chainId === 11155111
            ? "sepolia"
            : String(row.chainId);
      if (!row.smartAccountAddress) {
        onError(
          "smart-account counterfactual address not computed yet — go to detail and run 'Compute counterfactual address' first.",
        );
        return;
      }
      // 1) Resolve decimals via the registry. Required to convert the
      //    user's decimal-amount into uint256 base units the daemon
      //    expects on `swap.uniV3.quote` / `swap.uniV3.build`.
      const tokensRes = await call<{ tokens: RegistryToken[] }>(
        "swap.tokens.list",
        { chainId: chainName },
      );
      if (cancelled) return;
      if (!tokensRes.ok) {
        onError(`swap.tokens.list failed: ${tokensRes.error.message}`);
        return;
      }
      const registry = tokensRes.result?.tokens ?? [];
      const inDecimals = decimalsFor(tokenIn, registry);
      const outDecimals = decimalsFor(tokenOut, registry);
      if (inDecimals === null) {
        onError(
          `unknown sell-token symbol "${tokenIn}" — not in the swap registry for ${chainName}`,
        );
        return;
      }
      if (outDecimals === null) {
        onError(
          `unknown buy-token symbol "${tokenOut}" — not in the swap registry for ${chainName}`,
        );
        return;
      }
      const amountInBase = parseBaseUnits(amountDec, inDecimals);
      if (amountInBase === null || amountInBase === 0n) {
        onError(`bad amount "${amountDec}" for ${tokenIn} (${inDecimals} decimals)`);
        return;
      }

      // 2) Quote — used both to display the expected output and to set
      //    `amountOutMinimum = quote * (1 - slippage)` on the build call.
      setStatus(`Quoting ${tokenIn}→${tokenOut}…`);
      const quoteRes = await call<{ amountOut: number | string; fee: number }>(
        "swap.uniV3.quote",
        {
          chainId: chainName,
          tokenIn,
          tokenOut,
          amountIn: amountInBase,
        },
      );
      if (cancelled) return;
      if (!quoteRes.ok) {
        onError(`swap.uniV3.quote failed: ${quoteRes.error.message}`);
        return;
      }
      let amountOut: bigint;
      try {
        amountOut = BigInt(quoteRes.result?.amountOut as any);
      } catch {
        onError(`malformed quote: ${JSON.stringify(quoteRes.result)}`);
        return;
      }
      if (amountOut === 0n) {
        onError(`quoter returned 0 — no liquidity for ${tokenIn}→${tokenOut} at fee ${fee}`);
        return;
      }
      const amountOutMin =
        (amountOut * BigInt(10000 - slippageBps)) / 10000n;

      // 3) Build — daemon assembles the multicall / approval blob.
      setStatus("Building exactInputSingle calldata…");
      const buildRes = await call<any>("swap.uniV3.build", {
        chainId: chainName,
        fromAddress: row.smartAccountAddress,
        tokenIn,
        tokenOut,
        amountIn: amountInBase,
        amountOutMin,
        fee,
        recipient: row.smartAccountAddress,
      });
      if (cancelled) return;
      if (!buildRes.ok) {
        onError(`swap.uniV3.build failed: ${buildRes.error.message}`);
        return;
      }
      const txField = buildRes.result?.tx;
      if (!txField || typeof txField.to !== "string") {
        onError("daemon returned no swap tx");
        return;
      }
      const swap: SwapTxBlob = {
        to: txField.to,
        value: normalizeValueHex(txField.value),
        data: typeof txField.data === "string" ? txField.data : "0x",
      };
      const a = buildRes.result?.approval;
      const approval: SwapTxBlob | null =
        a && typeof a === "object" && typeof a.to === "string"
          ? {
              to: a.to,
              value: normalizeValueHex(a.value),
              data: typeof a.data === "string" ? a.data : "0x",
            }
          : null;
      const summary =
        `Sell ${amountDec} ${tokenIn} → receive ~${formatBaseUnitsShort(amountOut, outDecimals)} ${tokenOut}` +
        ` (min ${formatBaseUnitsShort(amountOutMin, outDecimals)} after ${(slippageBps / 100).toFixed(2)}% slippage)` +
        ` via Uniswap V3 fee tier ${fee}.`;
      onReady(approval, swap, summary);
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <Layout title="Preparing swap…" subtitle={status}>
      <Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>{status}</Text>
      </Text>
    </Layout>
  );
}

/** Tiny passthrough: any input → onDone. Used to dismiss terminal "done"
 *  screens that don't need a button row. */
function BackOnInput({ onDone }: { onDone: () => void }) {
  useInput(() => onDone());
  return null;
}
