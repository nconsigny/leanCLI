#!/usr/bin/env node
/*
 * leancli-safenode-bridge — TEE-attested oblivious-RPC proxy
 *
 * Slots in *upstream* of Helios in the verified-read pipeline:
 *
 *   helios's executionRpc = http://127.0.0.1:<port>   (this sidecar)
 *                                  │
 *                                  ▼  (TLS pin == TEE-attested cert SPKI)
 *                          https://rpc-gcp.safe-node.com/<USER_KEY>/json_rpc
 *                                  │
 *                                  ▼
 *                            oblivious_node (TDX CVM, ORAM)
 *
 * Privacy comes from the ORAM server (it can't tell which slot/address you
 * queried). Integrity comes from two checks:
 *
 *   1. Boot-time: this sidecar runs verify_client_tdx.mjs to attest the
 *      deployment and derive the attested TLS pin
 *      (sha256//<base64 SPKI hash>). Two attestation modes:
 *
 *        gcp   (GCP Confidential Space, the current safe-node deployment)
 *              Verifies a Google-signed OIDC token: audience, nonce bound
 *              to the served TLS cert + fresh challenge, GCP_INTEL_TDX
 *              hardware, secure boot, debug-disabled, STABLE image, the
 *              expected container image digest, entrypoint, and env
 *              launch policy. Pure Node — no Rust verifier needed.
 *
 *        phala (dstack/Phala TDX CVM, the original deployment)
 *              Fetches a TDX quote over `domain + sha256(cert PEM) +
 *              challenge` and verifies it via the companion Rust binary
 *              `tdx_quote_verifier` (RTMR3 replay, compose-hash).
 *
 *      On failure we refuse to start so the daemon falls back to plain
 *      helios.
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
 *   LEANCLI_SAFE_NODE_URL          required. e.g. "https://rpc-gcp.safe-node.com"
 *   LEANCLI_SAFE_NODE_API_KEY      required. user-tier API key; inserted
 *                                 into the URL path before /json_rpc.
 *   LEANCLI_SAFE_NODE_DOMAIN       optional. TLS domain to verify; defaults
 *                                 to the hostname of LEANCLI_SAFE_NODE_URL.
 *   LEANCLI_SAFE_NODE_ATTESTATION  optional. "gcp" | "phala". Defaults to
 *                                 "gcp" when LEANCLI_SAFE_NODE_GCP_IMAGE_DIGEST
 *                                 is set, else "phala".
 *   LEANCLI_SAFE_NODE_EXPECTED_PIN optional. operator-published pin
 *                                 (sha256//<base64>); if set, the freshly
 *                                 attested pin must match or we refuse to
 *                                 start. Defense-in-depth, both modes.
 *
 * GCP Confidential Space mode:
 *
 *   LEANCLI_SAFE_NODE_GCP_IMAGE_DIGEST  required for gcp mode. Expected
 *                                 OCI image digest ("sha256:<hex>") from
 *                                 the operator's build.
 *   LEANCLI_SAFE_NODE_GCP_AUDIENCE      optional. OIDC token audience;
 *                                 defaults to "safe-node:<domain>".
 *   LEANCLI_SAFE_NODE_GCP_ENV           optional. comma-separated
 *                                 NAME=VALUE pairs pinned against the
 *                                 container's env launch policy
 *                                 (forwarded as --expected-gcp-env).
 *
 * Phala/dstack TDX-quote mode:
 *
 *   LEANCLI_SAFE_NODE_PCCS_URL     optional. forwarded to verify_client_tdx
 *                                 as --pccs-url.
 *   LEANCLI_SAFE_NODE_MRTD         optional. expected MRTD hex; forwarded
 *                                 as the second positional argument to
 *                                 verify_client_tdx.
 *   TDX_QUOTE_VERIFIER_BIN        required (effectively): path to the
 *                                 companion Rust verifier. We do NOT
 *                                 ship it. Without it verify_client_tdx
 *                                 falls back to `cargo run` from the
 *                                 source tree, which only works if you
 *                                 cloned obliviouslabs/tdx_easy_https.
 *                                 NOT needed in gcp mode.
 *
 * Failure modes
 * -------------
 *
 *   - Attestation fails → sidecar exits non-zero. Daemon logs the failure
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
 * Pick the attestation mode. Explicit LEANCLI_SAFE_NODE_ATTESTATION wins;
 * otherwise "gcp" when an expected image digest is configured (GCP
 * verification is meaningless without one) and "phala" when it isn't.
 */
function attestationModeFromEnv(env = process.env) {
  const forced = (env.LEANCLI_SAFE_NODE_ATTESTATION || '').trim().toLowerCase();
  if (forced === 'gcp' || forced === 'gcp-confidential-space') return 'gcp';
  if (forced === 'phala' || forced === 'tdx' || forced === 'dstack') return 'phala';
  if (forced) {
    throw new Error(
      `unknown LEANCLI_SAFE_NODE_ATTESTATION "${forced}" (expected "gcp" or "phala")`
    );
  }
  return (env.LEANCLI_SAFE_NODE_GCP_IMAGE_DIGEST || '').length ? 'gcp' : 'phala';
}

/**
 * Collect everything the attestation flow needs from the environment.
 * Read once; --listen mode caches the result for safenode.verify re-runs.
 */
function readAttestConfig({ baseUrl, domain }) {
  const mode = attestationModeFromEnv();
  const gcpEnvPins = (readEnv('LEANCLI_SAFE_NODE_GCP_ENV') || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  for (const pair of gcpEnvPins) {
    if (pair.indexOf('=') <= 0) {
      throw new Error(`LEANCLI_SAFE_NODE_GCP_ENV entries must be NAME=VALUE, got "${pair}"`);
    }
  }
  const cfg = {
    baseUrl,
    domain,
    mode,
    expectedPin: readEnv('LEANCLI_SAFE_NODE_EXPECTED_PIN'),
    // gcp mode
    gcpImageDigest: readEnv('LEANCLI_SAFE_NODE_GCP_IMAGE_DIGEST'),
    gcpAudience: readEnv('LEANCLI_SAFE_NODE_GCP_AUDIENCE') || `safe-node:${domain}`,
    gcpEnvPins,
    // phala mode
    expectedMrtd: readEnv('LEANCLI_SAFE_NODE_MRTD'),
    pccsUrl: readEnv('LEANCLI_SAFE_NODE_PCCS_URL'),
    verifierBin: readEnv('TDX_QUOTE_VERIFIER_BIN'),
  };
  if (mode === 'gcp' && !cfg.gcpImageDigest) {
    throw new Error(
      'LEANCLI_SAFE_NODE_GCP_IMAGE_DIGEST is required for GCP Confidential Space attestation'
    );
  }
  return cfg;
}

/**
 * Run the vendored verify_client_tdx.mjs synchronously in the configured
 * attestation mode, parse stdout for `attested_tls_pin=` (and friends),
 * and return the structured result. Throws on non-zero exit, missing pin,
 * or a mismatch against the operator-published expected pin.
 */
function runAttestVerify(cfg) {
  const verifier = resolve(scriptDir(), 'verify_client_tdx.mjs');
  if (!fs.existsSync(verifier)) {
    throw new Error(`verify_client_tdx.mjs missing at ${verifier}`);
  }
  const args = [verifier, cfg.baseUrl];
  if (cfg.mode === 'gcp') {
    args.push(
      '--gcp-confidential-space',
      '--attested-tls',
      '--tls-domain', cfg.domain,
      '--gcp-audience', cfg.gcpAudience,
      '--expected-gcp-image-digest', cfg.gcpImageDigest
    );
    for (const pair of cfg.gcpEnvPins) args.push('--expected-gcp-env', pair);
  } else {
    if (cfg.expectedMrtd) args.push(cfg.expectedMrtd);
    args.push('--strict-digests', '--attested-tls', '--tls-domain', cfg.domain);
    if (cfg.pccsUrl) args.push('--pccs-url', cfg.pccsUrl);
    if (cfg.verifierBin) args.push('--verifier-bin', cfg.verifierBin);
  }

  const result = spawnSync(process.execPath, args, {
    cwd: scriptDir(),
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
    env: process.env,
  });
  if (result.status !== 0) {
    const reason = (result.stderr || result.stdout || `exit ${result.status}`).trim();
    throw new Error(`attestation (${cfg.mode}) failed: ${reason}`);
  }
  const stdout = result.stdout || '';
  const lines = stdout.split('\n');
  const find = (prefix) =>
    lines.map((l) => l.trim()).find((l) => l.startsWith(prefix))?.slice(prefix.length) ?? null;

  const pin = find('attested_tls_pin=');
  if (!pin) {
    throw new Error(`attestation (${cfg.mode}) succeeded but no attested_tls_pin in stdout:\n${stdout}`);
  }
  if (cfg.expectedPin && pin !== cfg.expectedPin) {
    throw new Error(
      `attested TLS pin does not match LEANCLI_SAFE_NODE_EXPECTED_PIN ` +
        `(expected=${cfg.expectedPin} actual=${pin}) — refusing to proxy`
    );
  }
  const attestation = {
    mode: cfg.mode,
    pin,
    domain:
      find('attested_tls_domain=') || find('gcp_confidential_space_domain=') || cfg.domain,
    certificateSha256: find('attested_tls_certificate_sha256='),
    // Phala/dstack quote fields (null in gcp mode — the Confidential Space
    // token attests the image, not raw RTMRs).
    mrtd: find('mrtd='),
    rtmr0: find('rtmr0='),
    rtmr1: find('rtmr1='),
    rtmr2: find('rtmr2='),
    rtmr3: find('rtmr3='),
    composeHash: find('compose_hash='),
    // GCP Confidential Space fields (null in phala mode). hwmodel is
    // enforced to GCP_INTEL_TDX inside the verifier, so surfacing it as
    // teeType is a verified claim, not a guess.
    gcpAudience: find('gcp_confidential_space_audience='),
    gcpImageDigest: find('gcp_confidential_space_image_digest='),
    gcpImageReference: find('gcp_confidential_space_image_reference='),
    gcpSwVersion: find('gcp_confidential_space_swversion='),
    teeType: find('tee_type=') ?? (cfg.mode === 'gcp' ? 'GCP_INTEL_TDX' : null),
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

// Methods safe-node actually serves on /json_rpc. Everything else returns
// -32601 from the app (we proved this empirically with eth_chainId on
// 2026-06-02). For non-listed methods we transparently forward to the
// non-pinned Sepolia fallback — those calls reveal no address-level state
// to an observer, so they don't need ORAM. The privacy property holds: only
// the listed (address-revealing) reads travel the TDX-pinned channel.
const SAFENODE_METHODS = new Set(['eth_getProof']);

// Retry schedule for safe-node's -32001 ("data non availability") backfill
// path. The server queues a fetch on miss; first reach often misses, second
// or third reach typically lands. We escalate the delay so a transient
// outage doesn't spin us into a thundering retry.
const BACKFILL_DELAYS_MS = [800, 1600, 3200];

async function postOnce({ url, agent, body, headers = {} }) {
  const res = await undiciFetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body,
    dispatcher: agent,
  });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`upstream HTTP ${res.status}: ${text}`);
  }
  let json;
  try {
    json = JSON.parse(text);
  } catch (e) {
    throw new Error(`upstream returned non-JSON: ${e?.message ?? e}`);
  }
  return { json, text };
}

/**
 * Splice `address` into an eth_getProof response when safe-node omits it.
 *
 * The Ethereum JSON-RPC spec requires eth_getProof to return an
 * `EIP1186AccountProof` object with `address`, `accountProof`, `balance`,
 * `codeHash`, `nonce`, `storageHash`, `storageProof`. Safe-node's current
 * deployment omits `address`, so strict Rust deserializers (Helios's REVM,
 * ethers, viem) reject the response. We get the address back from the
 * original request `params[0]` — safe to fill in losslessly, since the
 * server's proof is *for* that address by request.
 *
 * This is a temporary workaround. Filed upstream as a spec-compliance bug.
 */
function patchGetProofResponse(reqBody, respJson) {
  if (!respJson || typeof respJson !== 'object') return respJson;
  if (!respJson.result || typeof respJson.result !== 'object') return respJson;
  if (typeof respJson.result.address === 'string' && respJson.result.address.length > 0) {
    return respJson;
  }
  let addr = null;
  try {
    const parsed = JSON.parse(reqBody);
    if (parsed && Array.isArray(parsed.params) && typeof parsed.params[0] === 'string') {
      addr = parsed.params[0];
    }
  } catch {
    // bad incoming body, can't recover; let the original response flow
    return respJson;
  }
  if (!addr) return respJson;
  // Mutate in place — caller will re-stringify.
  respJson.result.address = addr;
  return respJson;
}

async function forwardSafeNode({ upstreamUrl, agent, body }) {
  let { json, text } = await postOnce({ url: upstreamUrl, agent, body });
  let i = 0;
  while (json?.error?.code === -32001 && i < BACKFILL_DELAYS_MS.length) {
    await new Promise((r) => setTimeout(r, BACKFILL_DELAYS_MS[i++]));
    ({ json, text } = await postOnce({ url: upstreamUrl, agent, body }));
  }
  // Safe-node omits the spec-required `address` field on eth_getProof
  // responses. Patch it back in so downstream consumers (Helios REVM,
  // ethers, viem) don't reject the otherwise-valid proof.
  json = patchGetProofResponse(body, json);
  text = JSON.stringify(json);
  return { json, text };
}

async function forwardFallback({ fallbackUrl, fallbackAgent, body }) {
  // Non-private, non-pinned. Best-effort one-shot retry on transport
  // failure (timeouts, transient 5xx) but not on JSON-RPC errors.
  try {
    return await postOnce({ url: fallbackUrl, agent: fallbackAgent, body });
  } catch (e) {
    await new Promise((r) => setTimeout(r, 500));
    return await postOnce({ url: fallbackUrl, agent: fallbackAgent, body });
  }
}

/**
 * Route a single JSON-RPC request to the right backend.
 * Privacy-sensitive (eth_getProof) → TDX-pinned safe-node.
 * Everything else → non-pinned Sepolia fallback RPC.
 */
async function forwardJsonRpc({ upstreamUrl, agent, fallbackUrl, fallbackAgent, body }) {
  let method = null;
  try {
    const parsed = JSON.parse(body);
    if (parsed && typeof parsed.method === 'string') {
      method = parsed.method;
    }
  } catch {
    // Non-JSON or array-batch: don't try to be clever, send to fallback.
    // The fallback's error response will surface to the caller.
  }
  if (method && SAFENODE_METHODS.has(method)) {
    return await forwardSafeNode({ upstreamUrl, agent, body });
  }
  return await forwardFallback({ fallbackUrl, fallbackAgent, body });
}

// ────────────────────────────────────────────────────────────────────────
//  --listen mode: UDS control plane + 127.0.0.1 HTTP proxy plane
// ────────────────────────────────────────────────────────────────────────

async function listenMode(socketPath) {
  const baseUrl = readEnv('LEANCLI_SAFE_NODE_URL', { required: true });
  const apiKey = readEnv('LEANCLI_SAFE_NODE_API_KEY', { required: true });
  const domain = readEnv('LEANCLI_SAFE_NODE_DOMAIN') || new URL(baseUrl).hostname;
  // Non-private fallback for every eth_* method safe-node doesn't implement
  // (everything other than eth_getProof). Default = a public Sepolia
  // node — the GCP safe-node deployment serves Sepolia (ETH_NETWORK=sepolia
  // is part of the attested launch policy). The privacy property holds: an
  // observer at this RPC sees block-header / chainId reads and helios's
  // REVM internals — they do NOT see which address/slot we proved, because
  // that travels safe-node's ORAM channel.
  const fallbackUrl =
    readEnv('LEANCLI_SAFE_NODE_FALLBACK_RPC') ||
    'https://ethereum-sepolia-rpc.publicnode.com';

  // Boot-time attestation. Failure ⇒ refuse to start; daemon falls back.
  let attestation;
  let attestCfg;
  try {
    attestCfg = readAttestConfig({ baseUrl, domain });
    attestation = runAttestVerify(attestCfg);
  } catch (e) {
    process.stderr.write(`[safenode] ${e.message}\n`);
    process.exit(2);
  }

  let agent = buildPinnedAgent(attestation.pin, domain);
  // The fallback is a regular public RPC: no pinning, no key in the path.
  // Use a fresh undici Agent so its connection pool doesn't share state
  // with the pinned one.
  const fallbackAgent = new Agent({ connect: { rejectUnauthorized: true } });
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
      const { text } = await forwardJsonRpc({
        upstreamUrl,
        agent,
        fallbackUrl,
        fallbackAgent,
        body,
      });
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
  process.stderr.write(`[safenode] split-route: ${[...SAFENODE_METHODS].join(',')} → safe-node; everything else → ${fallbackUrl}\n`);

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
    fallbackUrl,
    privateMethods: [...SAFENODE_METHODS],
    backfillDelaysMs: BACKFILL_DELAYS_MS,
    attestationMode: attestation.mode,
    attestedAtMs: attestation.attestedAtMs,
    pin: attestation.pin,
    mrtd: attestation.mrtd,
    rtmr0: attestation.rtmr0,
    rtmr1: attestation.rtmr1,
    rtmr2: attestation.rtmr2,
    rtmr3: attestation.rtmr3,
    composeHash: attestation.composeHash,
    gcpAudience: attestation.gcpAudience,
    gcpImageDigest: attestation.gcpImageDigest,
    gcpImageReference: attestation.gcpImageReference,
    gcpSwVersion: attestation.gcpSwVersion,
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
          .then(() => handleControl(req, { attestCfg, statusJson, applyNewAttestation: (next) => { attestation = next; agent = buildPinnedAgent(next.pin, domain); } }))
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
        const next = runAttestVerify(ctx.attestCfg);
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
  const baseUrl = readEnv('LEANCLI_SAFE_NODE_URL', { required: true });
  const apiKey = readEnv('LEANCLI_SAFE_NODE_API_KEY', { required: true });
  const domain = readEnv('LEANCLI_SAFE_NODE_DOMAIN') || new URL(baseUrl).hostname;

  const fallbackUrl =
    readEnv('LEANCLI_SAFE_NODE_FALLBACK_RPC') ||
    'https://ethereum-sepolia-rpc.publicnode.com';

  const attestation = runAttestVerify(readAttestConfig({ baseUrl, domain }));
  const agent = buildPinnedAgent(attestation.pin, domain);
  const fallbackAgent = new Agent({ connect: { rejectUnauthorized: true } });
  const upstreamUrl = joinUrl(baseUrl, apiKey);

  if (req.method === 'safenode.status') {
    process.stdout.write(
      ok(req.id ?? null, {
        proxyUrl: null,
        upstreamUrl,
        upstreamDomain: domain,
        attestationMode: attestation.mode,
        attestedAtMs: attestation.attestedAtMs,
        pin: attestation.pin,
        mrtd: attestation.mrtd,
        rtmr3: attestation.rtmr3,
        gcpImageDigest: attestation.gcpImageDigest,
        teeType: attestation.teeType,
      }) + '\n'
    );
    return;
  }
  if (req.method === 'safenode.proxy') {
    const innerBody = JSON.stringify(req.params?.inner ?? {});
    try {
      const { text } = await forwardJsonRpc({
        upstreamUrl,
        agent,
        fallbackUrl,
        fallbackAgent,
        body: innerBody,
      });
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
      'env: LEANCLI_SAFE_NODE_URL, LEANCLI_SAFE_NODE_API_KEY (required)\n' +
      '     LEANCLI_SAFE_NODE_DOMAIN, LEANCLI_SAFE_NODE_ATTESTATION (gcp|phala),\n' +
      '     LEANCLI_SAFE_NODE_EXPECTED_PIN (optional)\n' +
      'gcp: LEANCLI_SAFE_NODE_GCP_IMAGE_DIGEST (required),\n' +
      '     LEANCLI_SAFE_NODE_GCP_AUDIENCE, LEANCLI_SAFE_NODE_GCP_ENV (optional)\n' +
      'phala: LEANCLI_SAFE_NODE_MRTD, LEANCLI_SAFE_NODE_PCCS_URL (optional),\n' +
      '     TDX_QUOTE_VERIFIER_BIN (path to companion Rust verifier)\n'
  );
  process.exit(2);
}
