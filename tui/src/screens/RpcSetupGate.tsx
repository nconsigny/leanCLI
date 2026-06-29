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
  // Confirm phase: explicitly echo what we captured before writing. Many
  // first-run failures (paste with trailing newline, terminal eating a
  // burst, focus loss) end up with empty strings here — making the user
  // SEE the values before save catches these before the daemon spawns
  // with a half-empty config.
  | {
      kind: "confirm";
      mainnet: string;
      sepolia: string;
      mainnetErr: string | null;
      sepoliaErr: string | null;
    }
  | { kind: "saving"; mainnet: string; sepolia: string }
  | { kind: "done"; saved: { chain: string; url: string }[] }
  | { kind: "error"; msg: string };

/** Quick syntactic URL validation. Catches empty / pasted-text-only /
 *  missing-scheme errors. Doesn't make a network call — that's what the
 *  post-spawn chain.balance probe is for. */
function validateUrl(url: string): string | null {
  const u = url.trim();
  if (u.length === 0) return null; // empty = skip-this-chain, not an error
  if (!/^https?:\/\//i.test(u)) {
    return "must start with http:// or https://";
  }
  try {
    const parsed = new URL(u);
    if (!parsed.hostname) return "missing host";
    return null;
  } catch {
    return "not a valid URL";
  }
}

/** Resolve the daemon's config path the same way LeanCli/Cli/NetworkConfig
 *  does: `$LEANCLI_CONFIG`, else `$XDG_CONFIG_HOME/leancli/daemon.json`,
 *  else `~/.config/leancli/daemon.json`. Writing this from Node mirrors the
 *  `network.setRpcChain` write path; we keep the schema in lockstep with
 *  `LeanCli.Cli.NetworkConfig.setChainRpcUrl` (rpc_urls.<chain> as a bare
 *  string when no transport is supplied). */
function daemonConfigPath(): string {
  if (process.env.LEANCLI_CONFIG) return process.env.LEANCLI_CONFIG;
  const xdg = process.env.XDG_CONFIG_HOME || path.join(os.homedir(), ".config");
  return path.join(xdg, "leancli", "daemon.json");
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
 *  daemon refuses to start without an RPC URL (LeanCli/Daemon/Config.lean),
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
      const saved: { chain: string; url: string }[] = [];
      const mt = phase.mainnet.trim();
      const st = phase.sepolia.trim();
      if (mt) {
        writeChainRpc("mainnet", mt);
        saved.push({ chain: "mainnet", url: mt });
      }
      if (st) {
        writeChainRpc("sepolia", st);
        saved.push({ chain: "sepolia", url: st });
      }
      if (saved.length > 0) {
        // Sepolia is the dev network — never default a fresh wallet to
        // mainnet (Config.lean's chainId fallback agrees). Prefer sepolia
        // whenever it was configured; only fall back to mainnet if that's
        // the only RPC the user supplied.
        const def =
          saved.find((s) => s.chain === "sepolia")?.chain ?? saved[0]!.chain;
        setDefaultChain(def as "mainnet" | "sepolia");
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
                // Syntactic validation BEFORE leaving the input phase.
                // Empty is fine (skip-this-chain), but a non-empty value
                // missing http:// is almost always a paste error — flag
                // it here rather than letting it land in daemon.json.
                const err = validateUrl(v);
                if (err) {
                  setPhase({ ...phase, err });
                  return;
                }
                if (isMainnet) {
                  setPhase({
                    kind: "sepolia",
                    mainnet: v,
                    sepolia: phase.sepolia,
                    err: null,
                  });
                } else {
                  // Both URLs collected — confirm phase echoes them back
                  // before we touch daemon.json.
                  setPhase({
                    kind: "confirm",
                    mainnet: phase.mainnet,
                    sepolia: v,
                    mainnetErr: validateUrl(phase.mainnet),
                    sepoliaErr: validateUrl(v),
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

  if (phase.kind === "confirm") {
    // Echo what we captured. Users with paste-newline glitches see
    // empty values here and can Esc back to retype before save lands
    // a half-broken daemon.json. Refuse to advance when BOTH are
    // empty — that's the "I pressed Enter twice by accident on a
    // fresh box" case the previous gate accepted silently.
    const bothEmpty =
      phase.mainnet.trim().length === 0 && phase.sepolia.trim().length === 0;
    return (
      <ConfirmRpc
        mainnet={phase.mainnet}
        sepolia={phase.sepolia}
        mainnetErr={phase.mainnetErr}
        sepoliaErr={phase.sepoliaErr}
        bothEmpty={bothEmpty}
        onAccept={() => {
          if (bothEmpty || phase.mainnetErr || phase.sepoliaErr) return;
          setPhase({
            kind: "saving",
            mainnet: phase.mainnet,
            sepolia: phase.sepolia,
          });
        }}
        onRetype={() =>
          setPhase({
            kind: "mainnet",
            mainnet: phase.mainnet,
            sepolia: phase.sepolia,
            err: null,
          })
        }
      />
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

  // done — echo what actually landed in daemon.json so the user can
  // verify before BootGate moves on. Paste-newline glitches that slip
  // past validateUrl would surface here as a chain with a truncated URL.
  return (
    <Layout title="RPC saved" hint="enter / esc — continue">
      {phase.saved.length === 0 ? (
        <Banner
          kind="warn"
          text="No URLs entered. Set later: leancli network set-rpc-chain <chain> <url>"
        />
      ) : (
        <Box flexDirection="column">
          <Banner
            kind="ok"
            text={`Wrote ${phase.saved.length} RPC entr${phase.saved.length > 1 ? "ies" : "y"} to daemon.json:`}
          />
          {phase.saved.map((s) => (
            <Box key={s.chain} marginLeft={2}>
              <Text color={theme.dim}>
                {s.chain}: <Text color={theme.primary}>{s.url}</Text>
              </Text>
            </Box>
          ))}
        </Box>
      )}
      <ContinueOnInput onDone={onDone} />
    </Layout>
  );
}

/** Confirm screen: echo the captured URLs back to the user with any
 *  validation errors. Enter accepts and proceeds to save; Esc bounces
 *  back to retype both. Both-empty isn't acceptable — the install would
 *  otherwise produce a daemon with no usable RPC. */
function ConfirmRpc({
  mainnet,
  sepolia,
  mainnetErr,
  sepoliaErr,
  bothEmpty,
  onAccept,
  onRetype,
}: {
  mainnet: string;
  sepolia: string;
  mainnetErr: string | null;
  sepoliaErr: string | null;
  bothEmpty: boolean;
  onAccept: () => void;
  onRetype: () => void;
}) {
  useInput((_, key) => {
    if (key.return) onAccept();
    if (key.escape) onRetype();
  });
  const hasErr = bothEmpty || mainnetErr !== null || sepoliaErr !== null;
  const hint = hasErr ? "esc — retype" : "enter — save · esc — retype";
  return (
    <Layout title="Confirm RPC URLs" hint={hint}>
      <Box flexDirection="column">
        <Text color={theme.dim}>About to write to daemon.json:</Text>
        <Box marginTop={1} flexDirection="column">
          <Text wrap="truncate-end">
            mainnet:{" "}
            <Text color={mainnetErr ? theme.err : theme.primary}>
              {mainnet.trim().length === 0 ? "(blank — chain will be skipped)" : mainnet}
            </Text>
          </Text>
          {mainnetErr && (
            <Text color={theme.err}>          ↳ {mainnetErr}</Text>
          )}
          <Text wrap="truncate-end">
            sepolia:{" "}
            <Text color={sepoliaErr ? theme.err : theme.primary}>
              {sepolia.trim().length === 0 ? "(blank — chain will be skipped)" : sepolia}
            </Text>
          </Text>
          {sepoliaErr && (
            <Text color={theme.err}>          ↳ {sepoliaErr}</Text>
          )}
        </Box>
        {bothEmpty && (
          <Box marginTop={1}>
            <Banner
              kind="err"
              text="Both chains are blank. The daemon needs at least one RPC URL — press Esc to retype."
            />
          </Box>
        )}
      </Box>
    </Layout>
  );
}

function ContinueOnInput({ onDone }: { onDone: () => void }) {
  useInput((_, key) => {
    if (key.return || key.escape) onDone();
  });
  return null;
}
