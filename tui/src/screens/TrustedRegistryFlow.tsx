import React, { useEffect, useMemo, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { join } from "node:path";
import { Layout, Banner } from "../widgets/Layout.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";

/** Subset of `status.snapshot` we consume — only the version block,
 *  which carries the checkout root we need to locate skills/ and
 *  bridge/clearsign/registry/ on disk. Keeping the type local avoids
 *  importing StatusFlow's full Snapshot shape. */
type VersionsSnap = {
  versions: { checkoutRoot: string | null };
  network: { chainId: number };
};

/** One trusted-registry wallet entry — mirrors the daemon's
 *  `wallet.lean_verified_addresses` response (see
 *  LeanCli/Agent/ToolDefs/TrustedRegistry.lean#TrustedAddress). */
type WalletEntry = {
  kind: string; // "eoa" | "sphincs"
  slot?: string;
  path?: string;
  label?: string;
  unlocked?: boolean;
  ownerAddress?: string;
  smartAccountAddress?: string;
  paramSet?: string;
  chainId?: number;
  address: string;
};

type WalletResp =
  | { ok: true; addresses: WalletEntry[]; count: number; seedFingerprint: string }
  | { ok: false; error: { kind: string; msg: string } };

/** One row sourced from skills/<protocol>/contracts.json. The file
 *  format is `{ chainName: { ContractName: { address, abi?, source?, family?, legacy?, _note? } } }`
 *  plus a few `_*_note` strings we deliberately surface so the curator's
 *  rationale stays visible. */
type ProtocolRow = {
  protocol: string;
  chain: string;
  contractName: string;
  address: string;
  family?: string;
  legacy?: boolean;
  hasAbi: boolean;
  source?: string;
  note?: string;
};

/** One ERC-7730 descriptor in bridge/clearsign/registry/*.json. The
 *  `4byte.json` file is structurally different — it's a selector
 *  fallback table, not a descriptor — so we flag it separately. */
type DescriptorRow = {
  file: string;
  id?: string; // context.$id
  owner?: string;
  contractName?: string;
  deployments: { chainId: number; address?: string; verifyingContract?: string }[];
  intents: string[]; // display.formats[*].intent
  isSelectorFallback: boolean; // 4byte.json
};

type Props = {
  onBack: () => void;
};

/** Trusted Registry page. Three sections:
 *   1. WALLET — addresses the daemon vouches for (your seeds + TPM keys),
 *      via `wallet.lean_verified_addresses`. Requires an unlocked seed.
 *   2. PROTOCOLS — every entry in `skills/<proto>/contracts.json`,
 *      filtered to the current chain (mainnet/sepolia). Read directly
 *      from the checkout; this is what the agent's protocol picker sees.
 *   3. ERC-7730 / 4byte — descriptors the clearsign sidecar uses to
 *      render calldata. Joined-by-address with the protocol section so
 *      the user can tell at a glance which contracts have human-readable
 *      decoders.
 *
 *  This page does no signing, no chain reads, no policy-gated I/O. It is
 *  pure display + filesystem reads + one daemon RPC for the wallet
 *  block. */
export default function TrustedRegistryFlow({ onBack }: Props) {
  const [snap, setSnap] = useState<VersionsSnap | null>(null);
  const [wallets, setWallets] = useState<WalletResp | null>(null);
  const [protocols, setProtocols] = useState<ProtocolRow[]>([]);
  const [descriptors, setDescriptors] = useState<DescriptorRow[]>([]);
  const [protocolErrors, setProtocolErrors] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  useInput((input, key) => {
    if (key.escape || key.leftArrow || input === "q") {
      onBack();
      return;
    }
    if (input === "r" || input === "R") setRefreshKey((k) => k + 1);
  });

  // Phase 1: snapshot + wallet RPC. Both are daemon calls and can run in
  // parallel; the filesystem walk in Phase 2 depends on `versions.checkoutRoot`
  // so it waits for the snapshot.
  useEffect(() => {
    let cancelled = false;
    setError(null);
    setSnap(null);
    setWallets(null);
    setProtocols([]);
    setDescriptors([]);
    setProtocolErrors([]);
    (async () => {
      const [snapR, wR] = await Promise.all([
        call<VersionsSnap>("status.snapshot", {}),
        call<WalletResp>("wallet.lean_verified_addresses", {}),
      ]);
      if (cancelled) return;
      if (!snapR.ok) {
        setError(`status.snapshot ${snapR.error.code}: ${snapR.error.message}`);
        return;
      }
      setSnap(snapR.result);
      // wallet.lean_verified_addresses uses an in-result `{ ok: false, error }`
      // envelope for the locked/bad_path cases (see Phase 1d threat model);
      // a transport-level failure shows up as wR.ok=false. Both are non-fatal —
      // the page still renders the protocol and descriptor sections.
      if (wR.ok) setWallets(wR.result);
      else
        setWallets({
          ok: false,
          error: { kind: "transport", msg: wR.error.message },
        });
    })();
    return () => {
      cancelled = true;
    };
  }, [refreshKey]);

  // Phase 2: walk skills/ and bridge/clearsign/registry/ once we know the
  // checkout root. Synchronous fs is fine — this is the TUI process, not
  // the daemon, and the trees are tiny (<30 files total).
  useEffect(() => {
    if (!snap?.versions.checkoutRoot) return;
    const root = snap.versions.checkoutRoot;
    const { rows: pRows, errors } = loadProtocols(root);
    setProtocols(pRows);
    setProtocolErrors(errors);
    setDescriptors(loadDescriptors(root));
  }, [snap?.versions.checkoutRoot]);

  const chainId = snap?.network.chainId ?? 0;
  const chainName = chainLabel(chainId);
  const protoForChain = useMemo(
    () => protocols.filter((p) => p.chain === chainName || p.chain === "mainnet"),
    [protocols, chainName]
  );
  const hasDescriptor = useMemo(() => {
    const set = new Set<string>();
    for (const d of descriptors) {
      if (d.isSelectorFallback) continue;
      for (const dep of d.deployments) {
        if (dep.chainId !== chainId) continue;
        const a = (dep.address ?? dep.verifyingContract ?? "").toLowerCase();
        if (a) set.add(a);
      }
    }
    return set;
  }, [descriptors, chainId]);

  return (
    <Layout
      title="◉ Trusted Registry"
      subtitle={
        snap
          ? `chain ${chainName} · ${protoForChain.length} protocol contracts · ${
              descriptors.length
            } ERC-7730 / fallback descriptors`
          : "loading…"
      }
      hint="r refresh · ← / esc back · q quit"
    >
      {error && <Banner kind="err" text={error} />}
      {!snap && !error && (
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>asking daemon for snapshot…</Text>
        </Text>
      )}
      {snap && (
        <Box flexDirection="column">
          <WalletSection wallets={wallets} />
          <ProtocolSection
            rows={protoForChain}
            chainName={chainName}
            hasDescriptor={hasDescriptor}
          />
          <DescriptorSection rows={descriptors} chainId={chainId} />
          {protocolErrors.length > 0 && (
            <Box marginTop={1} flexDirection="column">
              <Text color={theme.warn}>
                ⚠ {protocolErrors.length} skill registry file(s) failed to parse
              </Text>
              {protocolErrors.slice(0, 4).map((e, i) => (
                <Text key={i} color={theme.dim} wrap="truncate-end">
                  {"  · "}
                  {e}
                </Text>
              ))}
            </Box>
          )}
        </Box>
      )}
    </Layout>
  );
}

/* ------------------------------------------------------------------ *
 * WALLET section — your seeds and TPM-backed keys.
 * ------------------------------------------------------------------ */

function WalletSection({ wallets }: { wallets: WalletResp | null }) {
  if (!wallets) {
    return (
      <Section title="Your wallets (daemon-verified)">
        <Text color={theme.dim}>
          <Spinner type="dots" /> loading…
        </Text>
      </Section>
    );
  }
  if (!wallets.ok) {
    const kind = wallets.error.kind;
    // `locked` is the common happy-path miss — the master / per-slot
    // unlock just hasn't happened yet. Phrase it as guidance, not error.
    if (kind === "locked") {
      return (
        <Section title="Your wallets (daemon-verified)">
          <Text color={theme.dim}>
            No seed unlocked. Unlock from the main menu (u) or via
            <Text color={theme.accent}> wallet.unlock </Text>
            to populate this section.
          </Text>
        </Section>
      );
    }
    return (
      <Section title="Your wallets (daemon-verified)">
        <Text color={theme.err}>
          {kind}: {wallets.error.msg}
        </Text>
      </Section>
    );
  }
  if (wallets.addresses.length === 0) {
    return (
      <Section title="Your wallets (daemon-verified)">
        <Text color={theme.dim}>(empty)</Text>
      </Section>
    );
  }
  return (
    <Section
      title={`Your wallets (daemon-verified · ${wallets.count} entries · fp ${
        wallets.seedFingerprint || "—"
      })`}
    >
      {wallets.addresses.map((a, i) => (
        <WalletRow key={`${a.address}-${i}`} a={a} />
      ))}
    </Section>
  );
}

function WalletRow({ a }: { a: WalletEntry }) {
  const lockBadge =
    a.kind === "eoa" && a.unlocked === false ? (
      <Text color={theme.warn}> · LOCKED</Text>
    ) : null;
  const name = displayName(a);
  const kindBadge =
    a.kind === "sphincs" ? "SC " : "EOA";
  return (
    <Box>
      <Text color={theme.accent}>{kindBadge} </Text>
      <Text color={theme.primary}>{pad(name, 28)} </Text>
      <Text color={theme.dim}>{a.address}</Text>
      {lockBadge}
    </Box>
  );
}

function displayName(a: WalletEntry): string {
  if (a.kind === "sphincs")
    return `${a.slot ?? "?"} [${a.paramSet ?? ""}]`;
  // EOA: prefer slot/label, then slot/index, then slot, then path.
  if (a.slot && a.label) return `${a.slot}/${a.label}`;
  if (a.slot && a.path) {
    const idx = bip44Account(a.path);
    return idx !== null ? `${a.slot}/${idx}` : `${a.slot} @ ${a.path}`;
  }
  if (a.slot) return a.slot;
  return a.path ?? "?";
}

function bip44Account(path: string): number | null {
  const parts = path.split("/");
  const acct = parts[3];
  if (!acct) return null;
  const n = Number(acct.replace(/'$/, ""));
  return Number.isInteger(n) ? n : null;
}

/* ------------------------------------------------------------------ *
 * PROTOCOL section — skills/<proto>/contracts.json.
 * ------------------------------------------------------------------ */

function ProtocolSection({
  rows,
  chainName,
  hasDescriptor,
}: {
  rows: ProtocolRow[];
  chainName: string;
  hasDescriptor: Set<string>;
}) {
  // Group by protocol so the view stays scannable even at ~40 rows.
  const byProtocol = new Map<string, ProtocolRow[]>();
  for (const r of rows) {
    const arr = byProtocol.get(r.protocol) ?? [];
    arr.push(r);
    byProtocol.set(r.protocol, arr);
  }
  const protocols = Array.from(byProtocol.keys()).sort();
  return (
    <Section title={`Protocol contracts (skills/ · chain ${chainName} + mainnet)`}>
      {protocols.length === 0 && (
        <Text color={theme.dim}>(no skills/*/contracts.json entries loaded)</Text>
      )}
      {protocols.map((p) => {
        const prows = byProtocol.get(p) ?? [];
        return (
          <Box key={p} flexDirection="column" marginBottom={1}>
            <Text color={theme.koiCream} bold>
              {p}
            </Text>
            {prows.map((r, i) => (
              <ProtocolRowView
                key={`${p}-${i}`}
                r={r}
                hasDescriptor={hasDescriptor.has(r.address.toLowerCase())}
              />
            ))}
          </Box>
        );
      })}
    </Section>
  );
}

function ProtocolRowView({
  r,
  hasDescriptor,
}: {
  r: ProtocolRow;
  hasDescriptor: boolean;
}) {
  const chainColor = r.chain === "sepolia" ? theme.accent : theme.dim;
  return (
    <Box flexDirection="column">
      <Text wrap="truncate-end">
        <Text color={chainColor}>{pad(r.chain, 8)} </Text>
        <Text color={theme.primary}>{pad(r.contractName, 32)} </Text>
        <Text color={theme.dim}>{r.address} </Text>
        {r.family && <Text color={theme.dim}>· {r.family} </Text>}
        {r.legacy && <Text color={theme.warn}>· LEGACY </Text>}
        {hasDescriptor && <Text color={theme.ok}>· 7730 ✓</Text>}
        {r.hasAbi && !hasDescriptor && <Text color={theme.dim}>· ABI</Text>}
      </Text>
      {r.note && (
        <Text color={theme.dim} wrap="truncate-end">
          {"    "}↳ {r.note}
        </Text>
      )}
    </Box>
  );
}

/* ------------------------------------------------------------------ *
 * DESCRIPTOR section — bridge/clearsign/registry/*.json.
 * ------------------------------------------------------------------ */

function DescriptorSection({
  rows,
  chainId,
}: {
  rows: DescriptorRow[];
  chainId: number;
}) {
  return (
    <Section
      title={`ERC-7730 + 4byte fallback (bridge/clearsign/registry/ · ${rows.length} files)`}
    >
      {rows.map((r) => (
        <DescriptorRowView key={r.file} r={r} chainId={chainId} />
      ))}
    </Section>
  );
}

function DescriptorRowView({
  r,
  chainId,
}: {
  r: DescriptorRow;
  chainId: number;
}) {
  if (r.isSelectorFallback) {
    return (
      <Box>
        <Text color={theme.dim}>{pad(r.file, 36)} </Text>
        <Text color={theme.dim}>selector fallback (4byte)</Text>
      </Box>
    );
  }
  const onThisChain = r.deployments.some((d) => d.chainId === chainId);
  const chainColor = onThisChain ? theme.ok : theme.dim;
  const dep =
    r.deployments.find((d) => d.chainId === chainId) ?? r.deployments[0];
  const addr = dep?.address ?? dep?.verifyingContract ?? "";
  return (
    <Box flexDirection="column">
      <Text wrap="truncate-end">
        <Text color={theme.primary}>{pad(r.file, 36)} </Text>
        <Text color={chainColor}>
          {r.deployments.length > 0
            ? r.deployments.map((d) => d.chainId).join(",")
            : "—"}
          {" "}
        </Text>
        <Text color={theme.dim}>{addr}</Text>
      </Text>
      {r.intents.length > 0 && (
        <Text color={theme.dim} wrap="truncate-end">
          {"    "}↳ {r.intents.slice(0, 4).join(" · ")}
          {r.intents.length > 4 ? ` +${r.intents.length - 4}` : ""}
        </Text>
      )}
    </Box>
  );
}

/* ------------------------------------------------------------------ *
 * Filesystem walks (synchronous — files are tiny and few).
 * ------------------------------------------------------------------ */

function loadProtocols(checkoutRoot: string): {
  rows: ProtocolRow[];
  errors: string[];
} {
  const rows: ProtocolRow[] = [];
  const errors: string[] = [];
  const skillsDir = join(checkoutRoot, "skills");
  if (!existsSync(skillsDir)) return { rows, errors };
  let entries: string[];
  try {
    entries = readdirSync(skillsDir);
  } catch (e) {
    errors.push(`skills/: ${String(e)}`);
    return { rows, errors };
  }
  for (const protocol of entries.sort()) {
    const contractsPath = join(skillsDir, protocol, "contracts.json");
    if (!existsSync(contractsPath)) continue;
    try {
      const raw = readFileSync(contractsPath, "utf8");
      const parsed = JSON.parse(raw);
      for (const chain of Object.keys(parsed)) {
        if (chain.startsWith("_")) continue;
        const chainBlock = parsed[chain];
        if (!chainBlock || typeof chainBlock !== "object") continue;
        for (const contractName of Object.keys(chainBlock)) {
          const c = chainBlock[contractName];
          if (!c || typeof c !== "object" || !c.address) continue;
          rows.push({
            protocol,
            chain,
            contractName,
            address: c.address,
            family: c.family,
            legacy: !!c.legacy,
            hasAbi: !!c.abi,
            source: c.source,
            note: c._note,
          });
        }
      }
    } catch (e) {
      errors.push(`${protocol}/contracts.json: ${String(e)}`);
    }
  }
  return { rows, errors };
}

function loadDescriptors(checkoutRoot: string): DescriptorRow[] {
  const out: DescriptorRow[] = [];
  const dir = join(checkoutRoot, "bridge", "clearsign", "registry");
  if (!existsSync(dir)) return out;
  let files: string[];
  try {
    files = readdirSync(dir).filter((f) => f.endsWith(".json"));
  } catch {
    return out;
  }
  for (const f of files.sort()) {
    const p = join(dir, f);
    try {
      // Skip anything that is not a regular file.
      if (!statSync(p).isFile()) continue;
      const parsed = JSON.parse(readFileSync(p, "utf8"));
      if (f === "4byte.json") {
        out.push({
          file: f,
          deployments: [],
          intents: [],
          isSelectorFallback: true,
        });
        continue;
      }
      const ctx = parsed?.context ?? {};
      const meta = parsed?.metadata ?? {};
      const display = parsed?.display?.formats ?? {};
      const intents: string[] = [];
      for (const k of Object.keys(display)) {
        const fmt = display[k];
        if (fmt && typeof fmt.intent === "string") intents.push(fmt.intent);
      }
      const deps: DescriptorRow["deployments"] = [];
      const contractDeps = ctx?.contract?.deployments;
      if (Array.isArray(contractDeps)) {
        for (const d of contractDeps) {
          if (typeof d?.chainId === "number")
            deps.push({ chainId: d.chainId, address: d.address });
        }
      }
      const eip712Deps = ctx?.eip712?.deployments;
      if (Array.isArray(eip712Deps)) {
        for (const d of eip712Deps) {
          if (typeof d?.chainId === "number")
            deps.push({
              chainId: d.chainId,
              verifyingContract: d.verifyingContract,
            });
        }
      }
      out.push({
        file: f,
        id: ctx?.$id,
        owner: meta?.owner,
        contractName: meta?.contractName,
        deployments: deps,
        intents,
        isSelectorFallback: false,
      });
    } catch {
      // Skip malformed files silently; the protocol-side errors block
      // surfaces the skills/ tree which is more user-facing. Descriptor
      // breakage here is a clearsign-bridge bug, not a registry bug.
    }
  }
  return out;
}

/* ------------------------------------------------------------------ *
 * Layout primitives — match StatusFlow's so the two feel like cousins.
 * ------------------------------------------------------------------ */

function Section({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <Box flexDirection="column" marginBottom={1}>
      <Text color={theme.primary} bold>
        {title}
      </Text>
      <Box flexDirection="column" marginLeft={2}>
        {children}
      </Box>
    </Box>
  );
}

function pad(s: string, n: number): string {
  if (s.length >= n) return s.slice(0, Math.max(0, n - 1)) + "…";
  return s + " ".repeat(n - s.length);
}

function chainLabel(chainId: number): string {
  switch (chainId) {
    case 1:
      return "mainnet";
    case 11155111:
      return "sepolia";
    case 17000:
      return "holesky";
    default:
      return "chain-" + chainId;
  }
}
