import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Select from "./Select.js";
import Spinner from "ink-spinner";
import { call, Notification, RpcError } from "../daemon.js";
import { theme } from "../theme.js";
import { Banner } from "./Layout.js";

type State =
  | { kind: "running" }
  | { kind: "ok"; result: unknown }
  | { kind: "err"; error: RpcError };

type Props = {
  method: string;
  params: unknown;
  /** Render the success result. Defaults to a JSON pretty-print. */
  renderResult?: (result: any) => React.ReactNode;
  /** Title shown above the runner. */
  title: string;
  /** Optional one-line subtitle (e.g. "from: bbqTest"). */
  subtitle?: string;
  /** Called when user presses Enter or Esc on the result screen. */
  onDone: (success: boolean) => void;
  /** Custom timeout in ms. Default 5min — generous because shielded.deposit
   *  can take 30-60s on first run for SDK init + chain sync. */
  timeoutMs?: number;
};

/** Run a daemon RPC, render notifications as a live status feed, then show
 *  the success/error outcome. Press Enter/Esc to dismiss. */
export default function RpcRunner({
  method,
  params,
  renderResult,
  title,
  subtitle,
  onDone,
  timeoutMs = 300_000,
}: Props) {
  const [state, setState] = useState<State>({ kind: "running" });
  const [events, setEvents] = useState<Notification[]>([]);

  useEffect(() => {
    let cancelled = false;
    const onN = (n: Notification) => {
      if (cancelled) return;
      setEvents((prev) => [...prev.slice(-7), n]);
    };
    call<any>(method, params, { onNotification: onN, timeoutMs }).then((r) => {
      if (cancelled) return;
      if (r.ok) setState({ kind: "ok", result: r.result });
      else setState({ kind: "err", error: r.error });
    });
    return () => {
      cancelled = true;
    };
  }, []);

  // Belt-and-braces: also accept Esc on the result screen. Enter is
  // handled by the SelectInput "Continue" item below — Ink's useInput
  // can drop keystrokes when input control was previously held by
  // ink-text-input in the same tree, so SelectInput is the reliable path.
  useInput((_, key) => {
    if (state.kind === "running") return;
    if (key.escape) onDone(state.kind === "ok");
  });

  return (
    <Box flexDirection="column" paddingX={1}>
      <Text color={theme.primary} bold>
        {title}
      </Text>
      {subtitle && <Text color={theme.dim}>{subtitle}</Text>}
      <Box marginTop={1} flexDirection="column">
        {events.map((n, i) => (
          <Text key={i} color={notifColor(n)}>
            {notifLine(n)}
          </Text>
        ))}
        {state.kind === "running" && (
          <Text>
            <Text color={theme.primary}>
              <Spinner type="dots" />
            </Text>{" "}
            <Text color={theme.dim}>working…</Text>
          </Text>
        )}
        {state.kind === "ok" && (
          <Box flexDirection="column" marginTop={1}>
            <Banner kind="ok" text="done" />
            <Box marginTop={1}>{renderResult ? renderResult(state.result) : <DefaultJson value={state.result} />}</Box>
          </Box>
        )}
        {state.kind === "err" && (
          <Box flexDirection="column" marginTop={1}>
            <Banner
              kind="err"
              text={`daemon error ${state.error.code}: ${state.error.message}`}
            />
          </Box>
        )}
      </Box>
      {state.kind !== "running" && (
        <Box flexDirection="column" marginTop={1}>
          <Select
            items={[{ label: "Continue", value: "continue" }]}
            onSelect={() => onDone(state.kind === "ok")}
          />
          <Text color={theme.dim}>enter • continue · esc • back</Text>
        </Box>
      )}
    </Box>
  );
}

function notifColor(n: Notification): string {
  switch (n.event) {
    case "biometric-required":
      return theme.warn;
    case "biometric-success":
    case "tx-mined":
      return theme.ok;
    case "biometric-failed":
      return theme.err;
    case "tx-broadcasted":
    case "tx-pending":
      return theme.primary;
    default:
      return theme.dim;
  }
}

function notifLine(n: Notification): string {
  const d: any = n.data ?? {};
  switch (n.event) {
    case "biometric-required":
      return `🔒 touch ${d.finger ?? "fingerprint reader"} (attempt ${d.attempt ?? "?"}/${d.of ?? "?"})`;
    case "biometric-success":
      return "✓ biometric verified";
    case "biometric-failed":
      return `✗ biometric attempt ${d.attempt ?? "?"}/${d.of ?? "?"} failed`;
    case "tx-broadcasted":
      return `📡 broadcast: ${d.txHash ?? "(no hash)"}`;
    case "tx-pending":
      return `⏳ waiting for confirmation… (${d.elapsedSec ?? 0}s)`;
    case "tx-mined":
      return `⛏  mined  block=${d.blockNumber ?? "?"} status=${d.status ?? "?"}`;
    default:
      return `[${n.event ?? "event"}] ${JSON.stringify(d)}`;
  }
}

function DefaultJson({ value }: { value: unknown }) {
  let text = "";
  try {
    text = JSON.stringify(value, null, 2);
  } catch {
    text = String(value);
  }
  return <Text>{text}</Text>;
}
