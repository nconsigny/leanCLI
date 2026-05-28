#!/usr/bin/env node
/*
 * leankohaku-safenode-bridge — TDX-attested oblivious-RPC proxy
 *
 * Slots in *upstream* of Helios in the verified-read pipeline:
 *
 *   helios's executionRpc = http://127.0.0.1:<port>   (this sidecar)
 *                                  │
 *                                  ▼  (TLS pin == TDX-attested cert SPKI)
 *                          https://rpc.safe-node.com/<USER_KEY>/json_rpc
 *                                  │
 *                                  ▼
 *                            oblivious_node (TDX CVM, ORAM)
 *
 * Privacy comes from the ORAM server (it can't tell which slot/address you
 * queried). Integrity comes from two checks:
 *
 *   1. Boot-time: this sidecar runs verify_client_tdx.mjs to fetch a TDX
 *      quote over `domain + sha256(cert PEM) + challenge`, verify it via
 *      the companion Rust binary `tdx_quote_verifier`, and derive the
 *      attested TLS pin (sha256//<base64 SPKI hash>). On failure we
 *      refuse to start so the daemon falls back to plain helios.
 *
 *   2. Per-request: every outbound HTTPS request enforces that exact pin
 *      via undici's `Agent({ connect: { checkServerIdentity } })`. A MITM
 *      with a forged-but-publicly-trusted cert can't substitute proofs.
 *
 * The trust posture below the verified core is unchanged: helios still
 * verifies every proof against the consensus state root, and the daemon
 * still terminates every signing decision at ConfirmGate. Safe-node
 * shifts WHERE we fetch proofs from; it does NOT short-circuit
 * downstream verification.
 *
 * Wire protocols
 * --------------
 *
 *   --listen <uds-socket>     daemon control plane, newline-delimited
 *                             JSON-RPC. Methods:
 *                               safenode.status   → { attestedAt, pin,
 *                                                     proxyUrl, upstreamDomain,
 *                                                     attestation? }
 *                               safenode.verify   → re-runs the TDX verify
 *                                                   flow; returns updated
 *                                                   status
 *                               safenode.proxyUrl → returns just the local
 *                                                   http://127.0.0.1:<port>
 *
 *   http://127.0.0.1:<port>/  proxy plane. POST a JSON-RPC body; we
 *                             forward to ${BASE_URL}/${USER_KEY}/json_rpc
 *                             with the attested TLS pin enforced. The
 *                             user API key NEVER appears in the Lean side
 *                             (or in any params handed to helios); it
 *                             lives only in this sidecar's env.
 *
 * Environment (read once at startup; --listen mode caches them):
 *
 *   KOHAKU_SAFE_NODE_URL          required. e.g. "https://rpc.safe-node.com"
 *   KOHAKU_SAFE_NODE_API_KEY      required. user-tier API key; inserted
 *                                 into the URL path before /json_rpc.
 *   KOHAKU_SAFE_NODE_DOMAIN       optional. TLS domain to verify; defaults
 *                                 to the hostname of KOHAKU_SAFE_NODE_URL.
 *   KOHAKU_SAFE_NODE_PCCS_URL     optional. forwarded to verify_client_tdx
 *                                 as --pccs-url.
 *   KOHAKU_SAFE_NODE_MRTD         optional. expected MRTD hex; forwarded
 *                                 as the second positional argument to
 *                                 verify_client_tdx.
 *   TDX_QUOTE_VERIFIER_BIN        required (effectively): path to the
 *                                 companion Rust verifier. We do NOT
 *                                 ship it. Without it verify_client_tdx
 *                                 falls back to `cargo run` from the
 *                                 source tree, which only works if you
 *                                 cloned obliviouslabs/oblivious_node.
 *
 * Failure modes
 * -------------
 *
 *   - TDX verify fails → sidecar exits non-zero. Daemon logs the failure
 *     and continues without safenode (helios reads still work over the
 *     configured rpcEndpoint, just without ORAM privacy).
 *   - Upstream returns -32001 ("data non availability") → we retry once
 *     after a short delay (per upstream docs the miss queues a backfill).
 *     Further retries surface to the daemon as a regular JSON-RPC error.
 *   - Bad TLS pin → undici errors; we surface as a JSON-RPC error with
 *     code -32099 so the daemon can tell us apart from upstream errors.
 *
 * The sidecar is **untrusted** for signing decisions, like every sibling
 * sidecar. Its output is consumed by helios's REVM, which validates
 * every storage read against the consensus-verified state root. If the
 * ORAM server lies about a slot value, helios's Merkle verification
 * fails and the read errors out — it cannot silently propagate.
 */

import { spawnSync } from 'node:child_process';
import { createHash, X509Certificate } from 'node:crypto';
import http from 'node:http';
import net from 'node:net';
import fs from 'node:fs';
import tls from 'node:tls';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Agent, fetch as undiciFetch } from 'undici';

const SUPPORTED_CHAIN_IDS = new Set([1, 11155111]); // mainnet + sepolia

function scriptDir() {
  return dirname(fileURLToPath(import.meta.url));
}

function ok(id, result) {
  return JSON.stringify({ jsonrpc: '2.0', id, result });
}

function err(id, code, message, data) {
  const error = { code, message };
  if (data !== undefined) error.data = data;
  return JSON.stringify({ jsonrpc: '2.0', id, error });
}

function readEnv(name, { required = false } = {}) {
  const v = process.env[name];
  if (required && (!v || !v.length)) {
    throw new Error(`${name} is required`);
  }
  return v || '';
}

function joinUrl(base, key) {
  const trimmed = base.replace(/\/+$/, '');
  return `${trimmed}/${key}/json_rpc`;
}

function spkiPinFromDerCert(derBuf) {
  const x509 = new X509Certificate(derBuf);
  const spkiDer = x509.publicKey.export({ type: 'spki', format: 'der' });
  return `sha256//${createHash('sha256').update(spkiDer).digest('base64')}`;
}

/**
 * Run the vendored verify_client_tdx.mjs synchronously, parse stdout for
 * `attested_tls_pin=` and `mrtd=` lines, and return the structured result.
 * Throws on non-zero exit or missing pin.
 */
function runTdxVerify({ baseUrl, domain, expectedMrtd, pccsUrl, verifierBin }) {
  const verifier = resolve(scriptDir(), 'verify_client_tdx.mjs');
  if (!fs.existsSync(verifier)) {
    throw new Error(`verify_client_tdx.mjs missing at ${verifier}`);
  }
  const args = [verifier, baseUrl];
  if (expectedMrtd) args.push(expectedMrtd);
  args.push('--strict-digests', '--attested-tls', '--tls-domain', domain);
  if (pccsUrl) args.push('--pccs-url', pccsUrl);
  if (verifierBin) args.push('--verifier-bin', verifierBin);

  const result = spawnSync(process.execPath, args, {
    cwd: scriptDir(),
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
    env: process.env,
  });
  if (result.status !== 0) {
    const reason = (result.stderr || result.stdout || `exit ${result.status}`).trim();
    throw new Error(`TDX verify failed: ${reason}`);
  }
  const stdout = result.stdout || '';
  const lines = stdout.split('\n');
  const find = (prefix) =>
    lines.map((l) => l.trim()).find((l) => l.startsWith(prefix))?.slice(prefix.length) ?? null;

  const pin = find('attested_tls_pin=');
  if (!pin) {
    throw new Error(`TDX verify succeeded but no attested_tls_pin in stdout:\n${stdout}`);
  }
  const attestation = {
    pin,
    domain: find('attested_tls_domain=') || domain,
    certificateSha256: find('attested_tls_certificate_sha256='),
    mrtd: find('mrtd='),
    rtmr0: find('rtmr0='),
    rtmr1: find('rtmr1='),
    rtmr2: find('rtmr2='),
    rtmr3: find('rtmr3='),
    composeHash: find('compose_hash='),
    teeType: find('tee_type='),
    attestedAtMs: Date.now(),
  };
  return attestation;
}

/**
 * Build an undici Agent that pins the upstream TLS public key to the
 * attested SPKI hash. We do NOT use the system CA bundle's identity
 * check alone — a publicly-trusted-but-not-the-enclave cert would pass
 * that. The attested pin is the only acceptable identity.
 */
function buildPinnedAgent(expectedPin, expectedDomain) {
  return new Agent({
    connect: {
      rejectUnauthorized: true,
      // Verified against the cert chain *after* TLS handshake. If we
      // throw / return an Error, undici aborts the connection.
      checkServerIdentity: (hostname, cert) => {
        if (hostname.toLowerCase() !== expectedDomain.toLowerCase()) {
          return new Error(
            `safenode: TLS hostname mismatch: expected ${expectedDomain}, got ${hostname}`
          );
        }
        // cert.raw is the DER-encoded leaf certificate.
        if (!cert?.raw || !cert.raw.length) {
          return new Error('safenode: peer certificate missing raw DER');
        }
        let actualPin;
        try {
          actualPin = spkiPinFromDerCert(cert.raw);
        } catch (e) {
          return new Error(`safenode: failed to derive SPKI pin: ${e?.message ?? e}`);
        }
        if (actualPin !== expectedPin) {
          return new Error(
            `safenode: TLS pin mismatch (expected=${expectedPin} actual=${actualPin})`
          );
        }
        // Pin matched — accept regardless of what the system CA says about
        // hostname/subject. The attested pin is our sole authority.
        return undefined;
      },
    },
  });
}

async function forwardJsonRpc({ upstreamUrl, agent, body }) {
  // Backfill retry: when the cache misses, the server returns
  // -32001 ("data non availability") and queues a fetch. Per upstream
  // docs, retrying after a short delay typically succeeds. We do exactly
  // one retry so we don't paper over genuine outages.
  const doOnce = async () => {
    const res = await undiciFetch(upstreamUrl, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body,
      dispatcher: agent,
    });
    const text = await res.text();
    if (!res.ok) {
      throw new Error(`upstream HTTP ${res.status}: ${text}`);
    }
    try {
      return { json: JSON.parse(text), text };
    } catch (e) {
      throw new Error(`upstream returned non-JSON: ${e?.message ?? e}`);
    }
  };

  let { json, text } = await doOnce();
  if (json?.error?.code === -32001) {
    await new Promise((r) => setTimeout(r, 1500));
    ({ json, text } = await doOnce());
  }
  return { json, text };
}

// ────────────────────────────────────────────────────────────────────────
//  --listen mode: UDS control plane + 127.0.0.1 HTTP proxy plane
// ────────────────────────────────────────────────────────────────────────

async function listenMode(socketPath) {
  const baseUrl = readEnv('KOHAKU_SAFE_NODE_URL', { required: true });
  const apiKey = readEnv('KOHAKU_SAFE_NODE_API_KEY', { required: true });
  const domain = readEnv('KOHAKU_SAFE_NODE_DOMAIN') || new URL(baseUrl).hostname;
  const expectedMrtd = readEnv('KOHAKU_SAFE_NODE_MRTD');
  const pccsUrl = readEnv('KOHAKU_SAFE_NODE_PCCS_URL');
  const verifierBin = readEnv('TDX_QUOTE_VERIFIER_BIN');

  // Boot-time TDX verify. Failure ⇒ refuse to start; daemon falls back.
  let attestation;
  try {
    attestation = runTdxVerify({ baseUrl, domain, expectedMrtd, pccsUrl, verifierBin });
  } catch (e) {
    process.stderr.write(`[safenode] ${e.message}\n`);
    process.exit(2);
  }

  let agent = buildPinnedAgent(attestation.pin, domain);
  const upstreamUrl = joinUrl(baseUrl, apiKey);

  // Bind HTTP proxy plane on 127.0.0.1, random port.
  const httpServer = http.createServer(async (req, res) => {
    if (req.method !== 'POST') {
      res.writeHead(405, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32600, message: 'method not allowed' } }));
      return;
    }
    let chunks = [];
    let total = 0;
    const MAX = 8 * 1024 * 1024;
    for await (const c of req) {
      total += c.length;
      if (total > MAX) {
        res.writeHead(413, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32600, message: 'payload too large' } }));
        return;
      }
      chunks.push(c);
    }
    const body = Buffer.concat(chunks).toString('utf8');
    try {
      const { text } = await forwardJsonRpc({ upstreamUrl, agent, body });
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(text);
    } catch (e) {
      const reason = e?.message ?? String(e);
      // -32099 is our "transport/attestation failure" code, kept distinct
      // from upstream JSON-RPC errors (-32000..-32099 range upstream uses).
      const payload = JSON.stringify({
        jsonrpc: '2.0',
        id: null,
        error: { code: -32099, message: `safenode proxy: ${reason}` },
      });
      res.writeHead(502, { 'content-type': 'application/json' });
      res.end(payload);
    }
  });
  await new Promise((resolveListen, rejectListen) => {
    httpServer.once('error', rejectListen);
    httpServer.listen(0, '127.0.0.1', () => {
      httpServer.off('error', rejectListen);
      resolveListen();
    });
  });
  const httpAddr = httpServer.address();
  const proxyUrl = `http://127.0.0.1:${httpAddr.port}`;
  process.stderr.write(`[safenode] proxy on ${proxyUrl} → ${baseUrl} (domain=${domain})\n`);
  process.stderr.write(`[safenode] attested TLS pin = ${attestation.pin}\n`);

  // Bind UDS control plane.
  try {
    fs.unlinkSync(socketPath);
  } catch (e) {
    if (e?.code !== 'ENOENT') {
      process.stderr.write(`[safenode] could not remove stale socket ${socketPath}: ${e.message}\n`);
    }
  }
  const statusJson = () => ({
    proxyUrl,
    upstreamUrl,
    upstreamDomain: domain,
    attestedAtMs: attestation.attestedAtMs,
    pin: attestation.pin,
    mrtd: attestation.mrtd,
    rtmr0: attestation.rtmr0,
    rtmr1: attestation.rtmr1,
    rtmr2: attestation.rtmr2,
    rtmr3: attestation.rtmr3,
    composeHash: attestation.composeHash,
    teeType: attestation.teeType,
    supportedChainIds: [...SUPPORTED_CHAIN_IDS],
  });

  const udsServer = net.createServer((conn) => {
    let buf = '';
    conn.on('data', (chunk) => {
      buf += chunk.toString('utf8');
      let idx;
      while ((idx = buf.indexOf('\n')) !== -1) {
        const line = buf.slice(0, idx);
        buf = buf.slice(idx + 1);
        if (!line.trim()) continue;
        let req;
        try {
          req = JSON.parse(line);
        } catch (e) {
          conn.write(err(null, -32700, `parse error: ${e?.message ?? e}`) + '\n');
          continue;
        }
        Promise.resolve()
          .then(() => handleControl(req, { agent, baseUrl, domain, expectedMrtd, pccsUrl, verifierBin, statusJson, applyNewAttestation: (next) => { attestation = next; agent = buildPinnedAgent(next.pin, domain); } }))
          .then((reply) => conn.write(reply + '\n'))
          .catch((e) => conn.write(err(req?.id ?? null, -32603, `internal: ${e?.message ?? e}`) + '\n'));
      }
    });
    conn.on('error', () => {});
  });
  await new Promise((resolveListen, rejectListen) => {
    udsServer.once('error', rejectListen);
    udsServer.listen(socketPath, () => {
      udsServer.off('error', rejectListen);
      resolveListen();
    });
  });
  process.stderr.write(`[safenode] control plane on uds://${socketPath}\n`);

  const shutdown = () => {
    try { udsServer.close(); } catch {}
    try { httpServer.close(); } catch {}
    try { fs.unlinkSync(socketPath); } catch {}
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

async function handleControl(req, ctx) {
  const id = req?.id ?? null;
  const method = req?.method;
  if (typeof method !== 'string') {
    return err(id, -32600, 'method must be a string');
  }
  switch (method) {
    case 'safenode.status':
      return ok(id, ctx.statusJson());
    case 'safenode.proxyUrl':
      return ok(id, { proxyUrl: ctx.statusJson().proxyUrl });
    case 'safenode.verify': {
      try {
        const next = runTdxVerify({
          baseUrl: ctx.baseUrl,
          domain: ctx.domain,
          expectedMrtd: ctx.expectedMrtd,
          pccsUrl: ctx.pccsUrl,
          verifierBin: ctx.verifierBin,
        });
        ctx.applyNewAttestation(next);
        return ok(id, ctx.statusJson());
      } catch (e) {
        return err(id, -32099, `re-attest failed: ${e?.message ?? e}`);
      }
    }
    default:
      return err(id, -32601, `method not found: ${method}`);
  }
}

// ────────────────────────────────────────────────────────────────────────
//  --rpc <json> mode: one-shot, mostly for smoke tests
// ────────────────────────────────────────────────────────────────────────

async function rpcMode(encoded) {
  let req;
  try {
    req = JSON.parse(encoded);
  } catch (e) {
    process.stdout.write(err(null, -32700, `parse error: ${e?.message ?? e}`) + '\n');
    process.exit(1);
  }
  const baseUrl = readEnv('KOHAKU_SAFE_NODE_URL', { required: true });
  const apiKey = readEnv('KOHAKU_SAFE_NODE_API_KEY', { required: true });
  const domain = readEnv('KOHAKU_SAFE_NODE_DOMAIN') || new URL(baseUrl).hostname;
  const expectedMrtd = readEnv('KOHAKU_SAFE_NODE_MRTD');
  const pccsUrl = readEnv('KOHAKU_SAFE_NODE_PCCS_URL');
  const verifierBin = readEnv('TDX_QUOTE_VERIFIER_BIN');

  const attestation = runTdxVerify({ baseUrl, domain, expectedMrtd, pccsUrl, verifierBin });
  const agent = buildPinnedAgent(attestation.pin, domain);
  const upstreamUrl = joinUrl(baseUrl, apiKey);

  if (req.method === 'safenode.status') {
    process.stdout.write(
      ok(req.id ?? null, {
        proxyUrl: null,
        upstreamUrl,
        upstreamDomain: domain,
        attestedAtMs: attestation.attestedAtMs,
        pin: attestation.pin,
        mrtd: attestation.mrtd,
        rtmr3: attestation.rtmr3,
      }) + '\n'
    );
    return;
  }
  if (req.method === 'safenode.proxy') {
    const innerBody = JSON.stringify(req.params?.inner ?? {});
    try {
      const { text } = await forwardJsonRpc({ upstreamUrl, agent, body: innerBody });
      process.stdout.write(ok(req.id ?? null, JSON.parse(text)) + '\n');
    } catch (e) {
      process.stdout.write(err(req.id ?? null, -32099, `safenode proxy: ${e?.message ?? e}`) + '\n');
    }
    return;
  }
  process.stdout.write(err(req.id ?? null, -32601, `method not found: ${req.method}`) + '\n');
}

// ────────────────────────────────────────────────────────────────────────
//  Mode dispatch
// ────────────────────────────────────────────────────────────────────────

const argv = process.argv.slice(2);
const listenIdx = argv.indexOf('--listen');
const rpcIdx = argv.indexOf('--rpc');

if (listenIdx !== -1 && argv[listenIdx + 1]) {
  listenMode(argv[listenIdx + 1]).catch((e) => {
    process.stderr.write(`[safenode] fatal: ${e?.message ?? e}\n`);
    process.exit(1);
  });
} else if (rpcIdx !== -1 && argv[rpcIdx + 1]) {
  rpcMode(argv[rpcIdx + 1]).catch((e) => {
    process.stderr.write(`[safenode] fatal: ${e?.message ?? e}\n`);
    process.exit(1);
  });
} else {
  process.stderr.write(
    'usage: bridge.mjs (--listen <uds-socket> | --rpc <json>)\n' +
      'env: KOHAKU_SAFE_NODE_URL, KOHAKU_SAFE_NODE_API_KEY (required)\n' +
      '     KOHAKU_SAFE_NODE_DOMAIN, KOHAKU_SAFE_NODE_MRTD, KOHAKU_SAFE_NODE_PCCS_URL (optional)\n' +
      '     TDX_QUOTE_VERIFIER_BIN (path to companion Rust verifier)\n'
  );
  process.exit(2);
}
