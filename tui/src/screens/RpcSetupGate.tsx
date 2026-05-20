import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import TextInput from "ink-text-input";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Layout, Banner } from "../widgets/Layout.js";
import { theme } from "../theme.js";

type Phase =
  | { kind: "mainnet"; mainnet: string; sepolia: string; err: string | null }
  | { kind: "sepolia"; mainnet: string; sepolia: string; err: string | null }
  | { kind: "saving"; mainnet: string; sepolia: string }
  | { kind: "done"; saved: string[] }
  | { kind: "error"; msg: string };

/** Resolve the daemon's config path the same way LeanKohaku/Cli/NetworkConfig
 *  does: `$LEANKOHAKU_CONFIG`, else `$XDG_CONFIG_HOME/leankohaku/daemon.json`,
 *  else `~/.config/leankohaku/daemon.json`. Writing this from Node mirrors the
 *  `network.setRpcChain` write path; we keep the schema in lockstep with
 *  `LeanKohaku.Cli.NetworkConfig.setChainRpcUrl` (rpc_urls.<chain> as a bare
 *  string when no transport is supplied). */
function daemonConfigPath(): string {
  if (process.env.LEANKOHAKU_CONFIG) return process.env.LEANKOHAKU_CONFIG;
  const xdg = process.env.XDG_CONFIG_HOME || path.join(os.homedir(), ".config");
  return path.join(xdg, "leankohaku", "daemon.json");
}

function writeChainRpc(chain: "mainnet" | "sepolia", url: string): void {
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
      // Leave json={} — overwriting a corrupted config is fine; the user
      // would have hit the same problem on next daemon start anyway.
    }
  }
  const existing =
    json.rpc_urls && typeof json.rpc_urls === "object" && !Array.isArray(json.rpc_urls)
      ? (json.rpc_urls as Record<string, unknown>)
      : {};
  json.rpc_urls = { ...existing, [chain]: url };
  fs.writeFileSync(cfg, JSON.stringify(json) + "\n");
}

function setDefaultChain(chain: "mainnet" | "sepolia"): void {
  const cfg = daemonConfigPath();
  let json: Record<string, unknown> = {};
  if (fs.existsSync(cfg)) {
    try {
      json = JSON.parse(fs.readFileSync(cfg, "utf8"));
    } catch {
      // ignore
    }
  }
  json.chain_id = chain === "mainnet" ? 1 : 11155111;
  delete json.chainId;
  fs.writeFileSync(cfg, JSON.stringify(json) + "\n");
}

/** First-run RPC setup. Writes daemon.json directly from Node because the
 *  daemon refuses to start without an RPC URL (LeanKohaku/Daemon/Config.lean),
 *  so we can't route the write through a daemon RPC. After save the user is
 *  told to retry — daemon needs to be (re)started to pick up the new file. */
export default function RpcSetupGate({ onDone }: { onDone: () => void }) {
  const [phase, setPhase] = useState<Phase>({
    kind: "mainnet",
    mainnet: "",
    sepolia: "",
    err: null,
  });

  useInput((_, key) => {
    if (key.escape && phase.kind !== "saving") onDone();
  });

  useEffect(() => {
    if (phase.kind !== "saving") return;
    try {
      const saved: string[] = [];
      const mt = phase.mainnet.trim();
      const st = phase.sepolia.trim();
      if (mt) {
        writeChainRpc("mainnet", mt);
        saved.push("mainnet");
      }
      if (st) {
        writeChainRpc("sepolia", st);
        saved.push("sepolia");
      }
      if (saved.length > 0) {
        setDefaultChain(saved[0] as "mainnet" | "sepolia");
      }
      setPhase({ kind: "done", saved });
    } catch (e: any) {
      setPhase({ kind: "error", msg: e?.message ?? String(e) });
    }
  }, [phase.kind]);

  if (phase.kind === "mainnet" || phase.kind === "sepolia") {
    const isMainnet = phase.kind === "mainnet";
    const current = isMainnet ? phase.mainnet : phase.sepolia;
    return (
      <Layout
        title="First-run RPC setup"
        subtitle="daemon refuses to start without at least one RPC URL"
        hint="enter — next · esc — skip"
      >
        <Box flexDirection="column">
          <Text color={theme.dim}>
            Configure mainnet and/or sepolia RPC URLs. Leave a chain blank to skip it.
          </Text>
          <Box marginTop={1}>
            <Text color={theme.dim}>{isMainnet ? "mainnet: " : "sepolia: "}</Text>
            {/* Constrain the TextInput's footprint to the remaining row width
                and clip overflow on the right. Without this, RPC URLs longer
                than the koi-frame's inner width — common with provider keys
                in the path — wrap to the next terminal line and bleed onto
                the koi ASCII art column at the left margin. flexShrink=1 +
                minWidth=0 + overflow="hidden" tells Ink to let this child
                shrink to whatever room is left in the row and clip the
                trailing chars when the value overruns it. */}
            <Box flexGrow={1} flexShrink={1} minWidth={0} overflow="hidden">
              <TextInput
                value={current}
                placeholder={
                  isMainnet ? "https://eth.llamarpc.com" : "https://sepolia.drpc.org"
                }
                onChange={(v) =>
                  setPhase({
                    ...phase,
                    ...(isMainnet ? { mainnet: v } : { sepolia: v }),
                    err: null,
                  })
                }
                onSubmit={(v) => {
                if (isMainnet) {
                  setPhase({
                    kind: "sepolia",
                    mainnet: v,
                    sepolia: phase.sepolia,
                    err: null,
                  });
                } else {
                  // Sepolia entered — save both.
                  setPhase({
                    kind: "saving",
                    mainnet: phase.mainnet,
                    sepolia: v,
                  });
                }
              }}
              />
            </Box>
          </Box>
          {phase.err && (
            <Box marginTop={1}>
              <Text color={theme.err}>{phase.err}</Text>
            </Box>
          )}
        </Box>
      </Layout>
    );
  }

  if (phase.kind === "saving") {
    return (
      <Layout title="Saving RPC config…">
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>writing daemon.json</Text>
        </Text>
      </Layout>
    );
  }

  if (phase.kind === "error") {
    return (
      <Layout title="RPC setup — error" hint="esc — back">
        <Banner kind="err" text={phase.msg} />
      </Layout>
    );
  }

  // done
  return (
    <Layout title="RPC saved" hint="enter / esc — continue">
      {phase.saved.length === 0 ? (
        <Banner
          kind="warn"
          text="No URLs entered. Set later: kohaku network set-rpc-chain <chain> <url>"
        />
      ) : (
        <>
          <Banner
            kind="ok"
            text={`Wrote ${phase.saved.join(" + ")} RPC URL${phase.saved.length > 1 ? "s" : ""} to daemon.json.`}
          />
          <Box marginTop={1}>
            <Text color={theme.dim}>
              Restart the daemon to pick up the new config:{" "}
              <Text color={theme.primary}>kohaku daemon stop &amp;&amp; kohaku daemon ping</Text>
            </Text>
          </Box>
        </>
      )}
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
