#!/usr/bin/env node
// rpc-spy — logging JSON-RPC proxy. Forwards every request to UPSTREAM and
// logs {t, method, detail, ms} per call so you can see helios's state-fetch
// pattern: a parallel eth_getProof burst = access-list prefetch worked; a
// sequential trickle = miss→full-replay churn.
//
// Usage: node rpc-spy.mjs <upstream-url> [port=8788]
import http from "node:http";

const upstream = process.argv[2];
const port = Number(process.argv[3] ?? 8788);
if (!upstream) { console.error("usage: rpc-spy.mjs <upstream-url> [port]"); process.exit(1); }

const t0 = Date.now();
let seq = 0;
const counts = new Map();

function detail(req) {
  const p = req.params ?? [];
  switch (req.method) {
    case "eth_getProof": return `${p[0]} slots=${(p[1] ?? []).length}`;
    case "eth_getCode": case "eth_getBalance": case "eth_getTransactionCount": return `${p[0]}`;
    case "eth_call": case "eth_createAccessList": case "eth_estimateGas":
      return `to=${p[0]?.to} data=${(p[0]?.data ?? "0x").slice(0, 10)}`;
    default: return "";
  }
}

http.createServer((cin, cout) => {
  let body = "";
  cin.on("data", (c) => (body += c));
  cin.on("end", async () => {
    const started = Date.now();
    const n = ++seq;
    let methods = "?";
    try {
      const parsed = JSON.parse(body);
      const reqs = Array.isArray(parsed) ? parsed : [parsed];
      methods = reqs.map((r) => `${r.method}(${detail(r)})`).join(" + ");
      for (const r of reqs) counts.set(r.method, (counts.get(r.method) ?? 0) + 1);
    } catch { /* log raw */ }
    console.log(`[${String(started - t0).padStart(6)}ms] #${n} → ${methods}`);
    try {
      const res = await fetch(upstream, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body,
      });
      const text = await res.text();
      console.log(`[${String(Date.now() - t0).padStart(6)}ms] #${n} ← ${Date.now() - started}ms ${text.length}B`);
      cout.writeHead(res.status, { "content-type": "application/json" });
      cout.end(text);
    } catch (e) {
      console.log(`[${String(Date.now() - t0).padStart(6)}ms] #${n} ✗ ${e.message}`);
      cout.writeHead(502); cout.end(JSON.stringify({ error: String(e) }));
    }
  });
}).listen(port, "127.0.0.1", () =>
  console.error(`rpc-spy on http://127.0.0.1:${port} → ${upstream}`));

process.on("SIGINT", () => {
  console.error("\n--- request totals ---");
  for (const [m, c] of [...counts.entries()].sort((a, b) => b[1] - a[1]))
    console.error(`${String(c).padStart(5)}  ${m}`);
  process.exit(0);
});
