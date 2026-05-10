/*
 * leanKohaku SPHINCS- shim — JSON-RPC dispatcher around the vendored
 * sphincs/sphincsplus reference C signer.
 *
 * Methods (one-shot stdio JSON-RPC, mirrors bridge/ sidecars):
 *   info    {}                                          -> { paramSet, sigBytes, pkBytes, skBytes, seedBytes }
 *   keygen  { seedHex }                                 -> { pkSeed, pkRoot, sk }
 *   sign    { sk, digest, optrand? }                    -> { sig }
 *   verify  { pkSeed, pkRoot, digest, sig }             -> { ok: bool }
 *
 * Invocation styles:
 *   shim --rpc '<json-line>'        (one-shot via argv, matches bridge/)
 *   echo '<json>' | shim            (one-shot via stdin)
 *
 * Field-size validation is enforced before any C-side crypto runs. Any
 * malformed input becomes a JSON-RPC error; stderr stays empty for normal
 * operation. The PARAM_SET_NAME / PARAM_SET_STUB defines are supplied at
 * compile time by the Makefile, one binary per parameter set.
 *
 * Trust model: the shim is *untrusted* by the daemon. The Lean bridge
 * re-validates every output's length and runs a verify-after-sign sanity
 * check. The shim therefore only needs to be honest about lengths; it is
 * not allowed to be trusted for "this signature is valid against this key".
 */

#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <ctype.h>

#include "params.h"
#include "api.h"

extern void set_rng_buffer(const unsigned char *buf, unsigned long long len);

#ifndef PARAM_SET_NAME
#error "PARAM_SET_NAME must be defined by the build system"
#endif

/* PARAM_SET_STUB=1 means this binary is a placeholder for a parameter set
 * whose underlying algorithmic adaptation (e.g. WOTS+C / FORS+C) is not yet
 * implemented. info{} still answers truthfully; keygen/sign/verify return
 * an explicit "not implemented" error so the daemon does not silently use
 * a stub-signed UserOp. */
#ifndef PARAM_SET_STUB
#define PARAM_SET_STUB 0
#endif

#if PARAM_SET_STUB
/* Mark hex helpers as deliberately retained for future stub-parameter
 * wiring; the stub elides every code path that uses them, so silence
 * -Wunused-function. */
#define MAYBE_UNUSED __attribute__((unused))
#else
#define MAYBE_UNUSED
#endif

/* ---------------- hex helpers ---------------- */

static int hex_nibble(int c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

MAYBE_UNUSED static int hex_decode(const char *hex, size_t hlen, unsigned char *out, size_t out_len)
{
    if (hlen >= 2 && hex[0] == '0' && (hex[1] == 'x' || hex[1] == 'X')) {
        hex += 2; hlen -= 2;
    }
    if (hlen != out_len * 2) return -1;
    for (size_t i = 0; i < out_len; i++) {
        int hi = hex_nibble(hex[2 * i]);
        int lo = hex_nibble(hex[2 * i + 1]);
        if (hi < 0 || lo < 0) return -1;
        out[i] = (unsigned char)((hi << 4) | lo);
    }
    return 0;
}

/* Append `len` bytes as lowercase hex into `dst` (caller pre-sizes). */
MAYBE_UNUSED static void hex_encode(const unsigned char *src, size_t len, char *dst)
{
    static const char H[] = "0123456789abcdef";
    for (size_t i = 0; i < len; i++) {
        dst[2 * i]     = H[(src[i] >> 4) & 0xF];
        dst[2 * i + 1] = H[src[i] & 0xF];
    }
    dst[2 * len] = 0;
}

/* ---------------- minimal JSON scanner ----------------
 * We only need to extract:
 *   - top-level "method" string
 *   - top-level "id" number
 *   - top-level "params" object containing string fields with hex values
 * No nested objects/arrays beyond `params`, no escapes beyond \" and \\.
 * Strict by design: anything unexpected -> -32700 parse error. */

typedef struct {
    const char *p;
    const char *end;
} Scan;

static void skip_ws(Scan *s)
{
    while (s->p < s->end) {
        char c = *s->p;
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') s->p++;
        else break;
    }
}

/* Scan a JSON string into [out_start, out_len) — pointer into the original
 * buffer when there are no escapes, or into `escbuf` when there are. */
static int scan_string(Scan *s, char *escbuf, size_t escbuf_cap,
                       const char **out_start, size_t *out_len)
{
    skip_ws(s);
    if (s->p >= s->end || *s->p != '"') return -1;
    s->p++;
    const char *start = s->p;
    int has_esc = 0;
    while (s->p < s->end && *s->p != '"') {
        if (*s->p == '\\') { has_esc = 1; s->p++; if (s->p < s->end) s->p++; }
        else s->p++;
    }
    if (s->p >= s->end) return -1;
    size_t raw_len = (size_t)(s->p - start);
    s->p++;
    if (!has_esc) {
        *out_start = start;
        *out_len = raw_len;
        return 0;
    }
    /* Decode minimal escapes: \" \\ \/ \n \r \t */
    if (raw_len > escbuf_cap) return -1;
    size_t j = 0;
    for (size_t i = 0; i < raw_len; i++) {
        char c = start[i];
        if (c == '\\' && i + 1 < raw_len) {
            char e = start[++i];
            switch (e) {
                case '"': escbuf[j++] = '"'; break;
                case '\\': escbuf[j++] = '\\'; break;
                case '/': escbuf[j++] = '/'; break;
                case 'n': escbuf[j++] = '\n'; break;
                case 'r': escbuf[j++] = '\r'; break;
                case 't': escbuf[j++] = '\t'; break;
                default: return -1;
            }
        } else {
            escbuf[j++] = c;
        }
    }
    *out_start = escbuf;
    *out_len = j;
    return 0;
}

static int scan_int(Scan *s, long long *out)
{
    skip_ws(s);
    int neg = 0;
    if (s->p < s->end && (*s->p == '-')) { neg = 1; s->p++; }
    if (s->p >= s->end || !isdigit((unsigned char)*s->p)) return -1;
    long long v = 0;
    while (s->p < s->end && isdigit((unsigned char)*s->p)) {
        v = v * 10 + (*s->p - '0');
        s->p++;
    }
    *out = neg ? -v : v;
    return 0;
}

/* Find a top-level field of `obj` by key, returning a Scan positioned at
 * the value. `obj_start..obj_end` must enclose the matching `{...}`.
 * Only handles flat string/int/object values (no arrays). */
static int find_field(const char *obj_start, const char *obj_end,
                      const char *key, Scan *out_scan)
{
    Scan s = { obj_start, obj_end };
    skip_ws(&s);
    if (s.p >= s.end || *s.p != '{') return -1;
    s.p++;
    while (s.p < s.end) {
        skip_ws(&s);
        if (s.p < s.end && *s.p == '}') return 0;  /* not found */
        const char *k_start; size_t k_len;
        char escbuf[64];
        if (scan_string(&s, escbuf, sizeof(escbuf), &k_start, &k_len) != 0) return -1;
        skip_ws(&s);
        if (s.p >= s.end || *s.p != ':') return -1;
        s.p++;
        skip_ws(&s);
        const char *val_start = s.p;
        int matches = (k_len == strlen(key) && memcmp(k_start, key, k_len) == 0);
        /* Skip the value: handle string, number, object, true/false/null. */
        if (s.p >= s.end) return -1;
        char c = *s.p;
        if (c == '"') {
            const char *vs; size_t vl;
            char eb[2];
            (void)eb;
            /* Don't decode escapes here; just walk past. */
            s.p++;
            while (s.p < s.end && *s.p != '"') {
                if (*s.p == '\\' && s.p + 1 < s.end) s.p += 2; else s.p++;
            }
            if (s.p >= s.end) return -1;
            s.p++;
            (void)vs; (void)vl;
        } else if (c == '{') {
            int depth = 0;
            do {
                if (s.p >= s.end) return -1;
                if (*s.p == '{') depth++;
                else if (*s.p == '}') depth--;
                else if (*s.p == '"') {
                    s.p++;
                    while (s.p < s.end && *s.p != '"') {
                        if (*s.p == '\\' && s.p + 1 < s.end) s.p += 2; else s.p++;
                    }
                    if (s.p >= s.end) return -1;
                }
                s.p++;
            } while (depth > 0);
        } else if (c == '-' || isdigit((unsigned char)c)) {
            if (c == '-') s.p++;
            while (s.p < s.end && isdigit((unsigned char)*s.p)) s.p++;
        } else if ((s.end - s.p) >= 4 && (memcmp(s.p, "true", 4) == 0 || memcmp(s.p, "null", 4) == 0)) {
            s.p += 4;
        } else if ((s.end - s.p) >= 5 && memcmp(s.p, "false", 5) == 0) {
            s.p += 5;
        } else {
            return -1;
        }
        if (matches) {
            out_scan->p = val_start;
            out_scan->end = s.end;
            return 1;
        }
        skip_ws(&s);
        if (s.p < s.end && *s.p == ',') { s.p++; continue; }
        if (s.p < s.end && *s.p == '}') return 0;
        return -1;
    }
    return -1;
}

/* ---------------- response emission ---------------- */

static void emit_error(long long id_val, int has_id, int code, const char *msg)
{
    /* { "jsonrpc":"2.0", "error":{"code":N,"message":"..."}, "id":... } */
    if (has_id) {
        printf("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":%d,\"message\":\"%s\"},\"id\":%lld}\n",
               code, msg, id_val);
    } else {
        printf("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":%d,\"message\":\"%s\"},\"id\":null}\n",
               code, msg);
    }
    fflush(stdout);
}

static void emit_result_open(long long id_val, int has_id)
{
    if (has_id) {
        printf("{\"jsonrpc\":\"2.0\",\"result\":{");
    } else {
        (void)id_val;
        printf("{\"jsonrpc\":\"2.0\",\"result\":{");
    }
}

static void emit_result_close(long long id_val, int has_id)
{
    if (has_id) {
        printf("},\"id\":%lld}\n", id_val);
    } else {
        printf("},\"id\":null}\n");
    }
    fflush(stdout);
}

/* ---------------- method handlers ---------------- */

#define DIGEST_BYTES 32  /* userOpHash is keccak256 — always 32 bytes */

static void handle_info(long long id_val, int has_id)
{
    emit_result_open(id_val, has_id);
    printf("\"paramSet\":\"%s\",", PARAM_SET_NAME);
#if PARAM_SET_STUB
    /* Stub binary: report zero-sized placeholders so the daemon's
     * length-validation refuses any keygen/sign/verify result. The build
     * driver is expected to override these per parameter set when a real
     * stub is wanted; until then the values must not look like a working
     * variant. */
    printf("\"sigBytes\":0,");
    printf("\"pkBytes\":0,");
    printf("\"skBytes\":0,");
    printf("\"seedBytes\":0,");
#else
    printf("\"sigBytes\":%d,", SPX_BYTES);
    printf("\"pkBytes\":%d,", SPX_PK_BYTES);
    printf("\"skBytes\":%d,", SPX_SK_BYTES);
    printf("\"seedBytes\":%d,", 3 * SPX_N);
#endif
    printf("\"stub\":%s", PARAM_SET_STUB ? "true" : "false");
    emit_result_close(id_val, has_id);
}

static void handle_keygen(const char *params_start, const char *params_end,
                          long long id_val, int has_id)
{
#if PARAM_SET_STUB
    (void)params_start; (void)params_end;
    emit_error(id_val, has_id, -32099,
        "stub binary: keygen not implemented for this parameter set");
#else
    Scan f;
    int rc = find_field(params_start, params_end, "seedHex", &f);
    if (rc <= 0) { emit_error(id_val, has_id, -32602, "missing seedHex"); return; }
    const char *seed_str; size_t seed_len;
    char escbuf[8];
    if (scan_string(&f, escbuf, sizeof(escbuf), &seed_str, &seed_len) != 0) {
        emit_error(id_val, has_id, -32602, "seedHex must be a string"); return;
    }
    unsigned char seed[3 * SPX_N];
    if (hex_decode(seed_str, seed_len, seed, sizeof(seed)) != 0) {
        emit_error(id_val, has_id, -32602, "seedHex length mismatch"); return;
    }
    unsigned char pk[SPX_PK_BYTES];
    unsigned char sk[SPX_SK_BYTES];
    if (crypto_sign_seed_keypair(pk, sk, seed) != 0) {
        emit_error(id_val, has_id, -32603, "keygen failed"); return;
    }
    char pk_seed_hex[2 * SPX_N + 1];
    char pk_root_hex[2 * SPX_N + 1];
    char sk_hex[2 * SPX_SK_BYTES + 1];
    /* Upstream pk = [pk_seed || pk_root] per `crypto_sign_seed_keypair` source. */
    hex_encode(pk, SPX_N, pk_seed_hex);
    hex_encode(pk + SPX_N, SPX_N, pk_root_hex);
    hex_encode(sk, SPX_SK_BYTES, sk_hex);
    emit_result_open(id_val, has_id);
    printf("\"pkSeed\":\"%s\",", pk_seed_hex);
    printf("\"pkRoot\":\"%s\",", pk_root_hex);
    printf("\"sk\":\"%s\"", sk_hex);
    emit_result_close(id_val, has_id);
#endif
}

static void handle_sign(const char *params_start, const char *params_end,
                        long long id_val, int has_id)
{
#if PARAM_SET_STUB
    (void)params_start; (void)params_end;
    emit_error(id_val, has_id, -32099,
        "stub binary: sign not implemented for this parameter set");
#else
    Scan fsk, fdg, fopt;
    if (find_field(params_start, params_end, "sk", &fsk) <= 0) {
        emit_error(id_val, has_id, -32602, "missing sk"); return;
    }
    if (find_field(params_start, params_end, "digest", &fdg) <= 0) {
        emit_error(id_val, has_id, -32602, "missing digest"); return;
    }
    int has_optrand = (find_field(params_start, params_end, "optrand", &fopt) > 0);
    char escbuf[8];
    const char *sk_str; size_t sk_len;
    const char *dg_str; size_t dg_len;
    if (scan_string(&fsk, escbuf, sizeof(escbuf), &sk_str, &sk_len) != 0) {
        emit_error(id_val, has_id, -32602, "sk must be hex string"); return;
    }
    if (scan_string(&fdg, escbuf, sizeof(escbuf), &dg_str, &dg_len) != 0) {
        emit_error(id_val, has_id, -32602, "digest must be hex string"); return;
    }
    unsigned char sk[SPX_SK_BYTES];
    if (hex_decode(sk_str, sk_len, sk, sizeof(sk)) != 0) {
        emit_error(id_val, has_id, -32602, "sk length mismatch"); return;
    }
    unsigned char dg[DIGEST_BYTES];
    if (hex_decode(dg_str, dg_len, dg, sizeof(dg)) != 0) {
        emit_error(id_val, has_id, -32602, "digest must be 32-byte hex"); return;
    }
    unsigned char optrand[SPX_N];
    memset(optrand, 0, sizeof(optrand));
    if (has_optrand) {
        const char *or_str; size_t or_len;
        if (scan_string(&fopt, escbuf, sizeof(escbuf), &or_str, &or_len) != 0) {
            emit_error(id_val, has_id, -32602, "optrand must be hex string"); return;
        }
        if (hex_decode(or_str, or_len, optrand, sizeof(optrand)) != 0) {
            emit_error(id_val, has_id, -32602, "optrand length mismatch"); return;
        }
    }
    set_rng_buffer(optrand, sizeof(optrand));
    unsigned char sig[SPX_BYTES];
    size_t siglen = 0;
    if (crypto_sign_signature(sig, &siglen, dg, sizeof(dg), sk) != 0 || siglen != SPX_BYTES) {
        emit_error(id_val, has_id, -32603, "sign failed"); return;
    }
    char *sig_hex = (char *)malloc(2 * SPX_BYTES + 1);
    if (!sig_hex) { emit_error(id_val, has_id, -32603, "oom"); return; }
    hex_encode(sig, SPX_BYTES, sig_hex);
    emit_result_open(id_val, has_id);
    printf("\"sig\":\"%s\"", sig_hex);
    emit_result_close(id_val, has_id);
    free(sig_hex);
#endif
}

static void handle_verify(const char *params_start, const char *params_end,
                          long long id_val, int has_id)
{
#if PARAM_SET_STUB
    (void)params_start; (void)params_end;
    emit_error(id_val, has_id, -32099,
        "stub binary: verify not implemented for this parameter set");
#else
    Scan fps, fpr, fdg, fsg;
    if (find_field(params_start, params_end, "pkSeed", &fps) <= 0 ||
        find_field(params_start, params_end, "pkRoot", &fpr) <= 0 ||
        find_field(params_start, params_end, "digest", &fdg) <= 0 ||
        find_field(params_start, params_end, "sig", &fsg) <= 0) {
        emit_error(id_val, has_id, -32602, "verify requires pkSeed/pkRoot/digest/sig"); return;
    }
    char escbuf[8];
    const char *ps_str, *pr_str, *dg_str, *sg_str;
    size_t ps_len, pr_len, dg_len, sg_len;
    if (scan_string(&fps, escbuf, sizeof(escbuf), &ps_str, &ps_len) != 0 ||
        scan_string(&fpr, escbuf, sizeof(escbuf), &pr_str, &pr_len) != 0 ||
        scan_string(&fdg, escbuf, sizeof(escbuf), &dg_str, &dg_len) != 0 ||
        scan_string(&fsg, escbuf, sizeof(escbuf), &sg_str, &sg_len) != 0) {
        emit_error(id_val, has_id, -32602, "verify fields must be hex strings"); return;
    }
    unsigned char pk[SPX_PK_BYTES];
    unsigned char dg[DIGEST_BYTES];
    if (hex_decode(ps_str, ps_len, pk, SPX_N) != 0 ||
        hex_decode(pr_str, pr_len, pk + SPX_N, SPX_N) != 0) {
        emit_error(id_val, has_id, -32602, "pkSeed/pkRoot must be 16-byte hex"); return;
    }
    if (hex_decode(dg_str, dg_len, dg, sizeof(dg)) != 0) {
        emit_error(id_val, has_id, -32602, "digest must be 32-byte hex"); return;
    }
    unsigned char *sig = (unsigned char *)malloc(SPX_BYTES);
    if (!sig) { emit_error(id_val, has_id, -32603, "oom"); return; }
    if (hex_decode(sg_str, sg_len, sig, SPX_BYTES) != 0) {
        free(sig);
        emit_error(id_val, has_id, -32602, "sig length mismatch"); return;
    }
    int rc = crypto_sign_verify(sig, SPX_BYTES, dg, sizeof(dg), pk);
    free(sig);
    emit_result_open(id_val, has_id);
    printf("\"ok\":%s", (rc == 0) ? "true" : "false");
    emit_result_close(id_val, has_id);
#endif
}

/* ---------------- dispatcher ---------------- */

static int dispatch(const char *line, size_t line_len)
{
    /* Extract method, id, and params. */
    Scan f;
    long long id_val = 0;
    int has_id = 0;
    int rc = find_field(line, line + line_len, "id", &f);
    if (rc > 0) {
        skip_ws(&f);
        if (f.p < f.end && *f.p == '"') {
            /* tolerate string ids by passing them through is unnecessary;
             * we only accept numeric ids. */
            emit_error(0, 0, -32600, "id must be numeric");
            return 0;
        }
        if (scan_int(&f, &id_val) == 0) has_id = 1;
    }
    Scan fmeth;
    if (find_field(line, line + line_len, "method", &fmeth) <= 0) {
        emit_error(id_val, has_id, -32600, "missing method"); return 0;
    }
    char escbuf[64];
    const char *m_str; size_t m_len;
    if (scan_string(&fmeth, escbuf, sizeof(escbuf), &m_str, &m_len) != 0) {
        emit_error(id_val, has_id, -32600, "method must be string"); return 0;
    }
    /* params is optional for `info`. */
    Scan fparams;
    int has_params = (find_field(line, line + line_len, "params", &fparams) > 0);
    const char *params_start = has_params ? fparams.p : "{}";
    const char *params_end   = has_params ? fparams.end : params_start + 2;

#define M(name) (m_len == strlen(name) && memcmp(m_str, name, m_len) == 0)
    if      (M("info"))   handle_info(id_val, has_id);
    else if (M("keygen")) handle_keygen(params_start, params_end, id_val, has_id);
    else if (M("sign"))   handle_sign(params_start, params_end, id_val, has_id);
    else if (M("verify")) handle_verify(params_start, params_end, id_val, has_id);
    else                  emit_error(id_val, has_id, -32601, "method not found");
#undef M
    return 0;
}

int main(int argc, char **argv)
{
    if (argc == 3 && strcmp(argv[1], "--rpc") == 0) {
        return dispatch(argv[2], strlen(argv[2]));
    }
    if (argc != 1) {
        fprintf(stderr, "Usage: %s [--rpc <json-line>]\n", argv[0]);
        return 2;
    }
    /* stdin: one request per line. We process exactly one and exit, matching
     * the bridge sidecars' one-shot semantics. */
    char *line = NULL;
    size_t cap = 0;
    ssize_t n = getline(&line, &cap, stdin);
    if (n <= 0) {
        fprintf(stderr, "%s: empty stdin\n", argv[0]);
        free(line);
        return 2;
    }
    int rc = dispatch(line, (size_t)n);
    free(line);
    return rc;
}
