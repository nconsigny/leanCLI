import React, { useState } from "react";
import { Box, Text, useInput } from "ink";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Layout, Banner } from "../widgets/Layout.js";
import Select from "../widgets/Select.js";
import { theme } from "../theme.js";

type Policy = "strict" | "permissive" | "tor";

type Phase =
  | { kind: "pick" }
  | { kind: "saving"; policy: Policy }
  | { kind: "done"; policy: Policy }
  | { kind: "error"; msg: string };

/** Same resolution as RpcSetupGate.daemonConfigPath and the shell helper
 *  in kohakuspawn — `$LEANKOHAKU_CONFIG`, else
 *  `$XDG_CONFIG_HOME/leankohaku/daemon.json`. Writing this from Node
 *  before the daemon ever reads it sidesteps the in-memory cfg staleness
 *  problem (cfg.policy is loaded once at startup; `network set-policy`
 *  on a running daemon doesn't actually take effect until restart). */
function daemonConfigPath(): string {
  if (process.env.LEANKOHAKU_CONFIG) return process.env.LEANKOHAKU_CONFIG;
  const xdg = process.env.XDG_CONFIG_HOME || path.join(os.homedir(), ".config");
  return path.join(xdg, "leankohaku", "daemon.json");
}

function writeNetworkPolicy(policy: Policy): void {
  const cfg = daemonConfigPath();
  fs.mkdirSync(path.dirname(cfg), { recursive: true });
  let json: Record<string, unknown> = {};
  if (fs.existsSync(cfg)) {
    try {
      const txt = fs.readFileSync(cfg, "utf8");
      const parsed = JSON.parse(txt);
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        json = parsed as Record<string, unknown>;
      }
    } catch {
      // Overwriting a corrupted config is fine; daemon would have hit
      // the same parse error on startup anyway.
    }
  }
  json.network_policy = policy;
  fs.writeFileSync(cfg, JSON.stringify(json) + "\n");
}

const POLICY_OPTIONS: { value: Policy; label: string; blurb: string[] }[] = [
  {
    value: "permissive",
    label: "permissive",
    blurb: [
      "Configured RPC allowed on every chain over any transport.",
      "Balance reads + broadcasts work out of the box on mainnet.",
      "Privacy: your RPC provider sees every address you query.",
      "",
      "Independent of policy: when the Colibri light client is",
      "toggled on (main menu → Colibri), reads are ALSO verified via",
      "committee signatures — no reason not to leave it on.",
    ],
  },
  {
    value: "strict",
    label: "strict (default)",
    blurb: [
      "Mainnet: configured RPC denied. Reads must come from a local",
      "node (loopback transport) or via the Colibri light client.",
      "Broadcasts on mainnet need a local node too.",
      "Testnets (Sepolia): configured RPC allowed — mistakes don't",
      "cost real money so the privacy bar is lower.",
      "Privacy: best — no third-party leaks on mainnet.",
    ],
  },
  {
    value: "tor",
    label: "tor",
    blurb: [
      "Configured RPC allowed only over the Tor transport.",
      "Privacy: RPC provider sees a Tor circuit, not your real IP.",
      "Requires a Tor daemon running locally (separate setup).",
    ],
  },
];

/** First-run network policy picker. Runs after RpcSetupGate (so the user
 *  has already picked their RPC URLs) and before the daemon is allowed to
 *  start (BootGate phase 1 — fs-only). The picked policy lands in
 *  daemon.json so the daemon reads it on its first launch. */
export default function NetworkPolicyGate(
  { onDone }: { onDone: () => void },
) {
  const [phase, setPhase] = useState<Phase>({ kind: "pick" });
  const [highlight, setHighlight] = useState<Policy>("permissive");

  useInput((_, key) => {
    if (key.escape && phase.kind !== "saving") onDone();
  });

  React.useEffect(() => {
    if (phase.kind !== "saving") return;
    try {
      writeNetworkPolicy(phase.policy);
      setPhase({ kind: "done", policy: phase.policy });
    } catch (e: any) {
      setPhase({ kind: "error", msg: e?.message ?? String(e) });
    }
  }, [phase.kind]);

  if (phase.kind === "pick") {
    const active: (typeof POLICY_OPTIONS)[number] =
      POLICY_OPTIONS.find((o) => o.value === highlight) ??
      POLICY_OPTIONS[1]!; // 1 = strict, our recommended default; `!` is safe — array literal has 3 entries
    return (
      <Layout
        title="First-run network policy"
        subtitle="how the daemon is allowed to talk to RPC providers"
        hint="↑/↓ pick · enter — save · esc — skip"
      >
        <Box flexDirection="column">
          <Select<Policy>
            items={POLICY_OPTIONS.map((o) => ({
              label: o.label,
              value: o.value,
            }))}
            onHighlight={(it) => setHighlight(it.value)}
            onSelect={(it) => setPhase({ kind: "saving", policy: it.value })}
            initialIndex={1}
          />
          <Box marginTop={1} flexDirection="column">
            {active.blurb.map((line, i) => (
              <Text key={i} color={theme.dim} wrap="wrap">
                {line}
              </Text>
            ))}
          </Box>
        </Box>
      </Layout>
    );
  }

  if (phase.kind === "saving") {
    return (
      <Layout title="Saving network policy…">
        <Text color={theme.dim}>writing daemon.json</Text>
      </Layout>
    );
  }

  if (phase.kind === "error") {
    return (
      <Layout title="Network policy — error" hint="esc — back">
        <Banner kind="err" text={phase.msg} />
      </Layout>
    );
  }

  // done
  return (
    <Layout title="Network policy saved" hint="enter / esc — continue">
      <Banner
        kind="ok"
        text={`network_policy=${phase.policy} written to daemon.json. Change later with: kohaku network set-policy <strict|permissive|tor> (then restart the daemon).`}
      />
      <ContinueOnInput onDone={onDone} />
    </Layout>
  );
}

function ContinueOnInput({ onDone }: { onDone: () => void }) {
  useInput((_, key) => {
    if (key.return || key.escape) onDone();
  });
  return null;
}
