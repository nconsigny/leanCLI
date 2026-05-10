import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import Select from "../widgets/Select.js";
import { Layout, Banner } from "../widgets/Layout.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";

type Endpoint = {
  url: string;
  transport: string;
  backend: string;
};

type ChainEndpoint = Endpoint & {
  name: string;
  chainId: number;
  isCurrent: boolean;
};

type IndexerEntry = {
  name: string;
  url: string;
};

export type NetworkSnapshot = {
  configFile: string;
  chainId: number;
  rpc: Endpoint;
  ens: Endpoint | null;
  perChain: ChainEndpoint[];
  policy: string;
  socketPath: string;
  logPath: string | null;
  lightclient: boolean;
  indexers: IndexerEntry[];
};

type NetAction = "monitor" | "refresh" | "back";

type Props = {
  onPick: (a: NetAction) => void;
  onBack: () => void;
};

/** Top-level Network tab. Mirrors the CLI's `network show` surface — same
 *  fields, structured. Read-only for now: mutations still flow through the
 *  CLI writers and only land at next daemon start. */
export default function NetworkScreen({ onPick, onBack }: Props) {
  const [snap, setSnap] = useState<NetworkSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    let cancelled = false;
    setSnap(null);
    setError(null);
    (async () => {
      const r = await call<NetworkSnapshot>("network.show", []);
      if (cancelled) return;
      if (r.ok) setSnap(r.result);
      else setError(`${r.error.code}: ${r.error.message}`);
    })();
    return () => {
      cancelled = true;
    };
  }, [reloadKey]);

  useInput((input, key) => {
    if (key.escape || key.leftArrow || input === "q") {
      onBack();
      return;
    }
    if (input === "r") setReloadKey((k) => k + 1);
  });

  const items: { label: string; value: NetAction }[] = [
    { label: "Live network monitor",                 value: "monitor" },
    { label: "Refresh snapshot",                     value: "refresh" },
    { label: "← Back",                               value: "back" },
  ];

  return (
    <Layout
      title="Network"
      subtitle="daemon's currently-active routing — mirrors `kohaku network show`"
      hint="↑/↓ move · → / enter select · ← / esc back · r refresh"
    >
      {error && <Banner kind="err" text={error} />}
      {!snap && !error && (
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>asking daemon for network state…</Text>
        </Text>
      )}
      {snap && <SnapshotView snap={snap} />}
      <Box marginTop={1}>
        <Select
          items={items}
          arrowNav
          onBack={onBack}
          onSelect={(it) => {
            if (it.value === "refresh") setReloadKey((k) => k + 1);
            else onPick(it.value);
          }}
        />
      </Box>
    </Layout>
  );
}

function SnapshotView({ snap }: { snap: NetworkSnapshot }) {
  // Render each per-chain entry by name; if a known chain is missing we
  // surface "<not configured>" so users can tell apart "daemon doesn't
  // know about it" from "daemon knows but no RPC".
  const chainsByName = new Map<string, ChainEndpoint>(
    snap.perChain.map((c) => [c.name, c]),
  );
  const knownChains = ["mainnet", "sepolia"];
  const extras = snap.perChain.filter((c) => !knownChains.includes(c.name));
  const orderedChains = [
    ...knownChains.map((name) => ({ name, entry: chainsByName.get(name) })),
    ...extras.map((c) => ({ name: c.name, entry: c })),
  ];

  return (
    <Box flexDirection="column">
      <Section title="Active RPC">
        <KV k="url"       v={snap.rpc.url} mono />
        <KV k="transport" v={snap.rpc.transport} />
        <KV k="backend"   v={snap.rpc.backend} />
        <KV k="lightclient" v={snap.lightclient ? "ON  ✓" : "off"}
            color={snap.lightclient ? theme.ok : theme.dim} />
      </Section>

      <Section title="Per-chain RPC">
        {orderedChains.map(({ name, entry }) => (
          <Box key={name} flexDirection="column" marginBottom={0}>
            <Box>
              <Text color={theme.accent} bold>{name.padEnd(10)}</Text>
              {entry ? (
                <>
                  <Text color={theme.dim}>chainId={entry.chainId || "?"} </Text>
                  {entry.isCurrent && <Text color={theme.ok} bold>[active] </Text>}
                </>
              ) : (
                <Text color={theme.warn}>&lt;not configured&gt;</Text>
              )}
            </Box>
            {entry && (
              <Box flexDirection="column" marginLeft={2}>
                <KV k="url"       v={entry.url} mono />
                <KV k="transport" v={entry.transport} />
                <KV k="backend"   v={entry.backend} />
              </Box>
            )}
          </Box>
        ))}
      </Section>

      <Section title="ENS resolver (always mainnet)">
        {snap.ens ? (
          <>
            <KV k="url"       v={snap.ens.url} mono />
            <KV k="transport" v={snap.ens.transport} />
            <KV k="backend"   v={snap.ens.backend} />
          </>
        ) : (
          <Text color={theme.warn}>
            &lt;unset&gt; — `kohaku network set-ens-rpc &lt;url&gt;` to enable
          </Text>
        )}
      </Section>

      <Section title="Policy & runtime">
        <KV k="policy"      v={snap.policy} color={theme.ok} />
        <KV k="chainId"     v={String(snap.chainId)} />
        <KV k="socketPath"  v={snap.socketPath} mono />
        <KV k="configFile"  v={snap.configFile} mono />
        <KV k="networkLog"  v={snap.logPath ?? "<disabled>"}
            mono={snap.logPath !== null}
            color={snap.logPath ? undefined : theme.warn} />
      </Section>

      {snap.indexers.length > 0 && (
        <Section title="Indexers">
          {snap.indexers.map((ix) => (
            <Box key={ix.name}>
              <Text color={theme.accent}>{ix.name.padEnd(12)}</Text>
              <Text color={theme.dim}>{ix.url}</Text>
            </Box>
          ))}
        </Section>
      )}
    </Box>
  );
}

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

function KV({
  k,
  v,
  mono = false,
  color,
}: {
  k: string;
  v: string;
  mono?: boolean;
  color?: string;
}) {
  return (
    <Box>
      <Text color={theme.dim}>{k.padEnd(11)}</Text>
      <Text color={color}>{mono ? v : v}</Text>
    </Box>
  );
}
