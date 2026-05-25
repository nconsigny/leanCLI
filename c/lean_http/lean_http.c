// SPDX-License-Identifier: MIT
//
// Loopback-only HTTP POST shim for the Lean-native agent. See lean_http.h
// for the C ABI. The Lean side (LeanKohaku/Agent/Http.lean) calls into
// this via @[extern] bindings, exactly mirroring the pattern in
// c/lean_uds/lean_uds.c.
//
// Loopback enforcement is intentionally redundant with the Lean wrapper.
// The C check is the floor — even a Lean bug or a wrapper-bypass via FFI
// cannot make this shim talk to a non-loopback host.

#define _GNU_SOURCE

#include "lean_http.h"

#include <lean/lean.h>

#include <curl/curl.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

// Cap response size at 8 MiB. A larger response from a local LLM is
// almost certainly a misconfiguration or a runaway model.
#define LK_HTTP_MAX_BODY (8u * 1024u * 1024u)

// Initialise libcurl globals lazily once per process. curl_global_init
// is documented thread-unsafe; the lean runtime calls into this from
// the main IO thread so a plain static flag suffices.
static int g_curl_global_inited = 0;
static int lk_curl_global_init_once(void) {
  if (g_curl_global_inited) return 0;
  CURLcode rc = curl_global_init(CURL_GLOBAL_NOTHING); // no SSL needed
  if (rc != CURLE_OK) return -1;
  g_curl_global_inited = 1;
  return 0;
}

// Case-insensitive prefix match.
static int lk_starts_with_ci(const char* s, const char* prefix) {
  size_t pn = strlen(prefix);
  if (strlen(s) < pn) return 0;
  return strncasecmp(s, prefix, pn) == 0;
}

// Loopback URL check. Accept exactly one of:
//   http://127.0.0.1[:port]/...
//   http://[::1][:port]/...
//   http://localhost[:port]/...
// followed by either ':' (port) or '/' (path) or end-of-string.
// No HTTPS — TLS to loopback is pointless and adds attack surface.
static int lk_is_loopback_url(const char* url) {
  if (url == NULL) return 0;
  static const struct {
    const char* prefix;
    char terminator_a;
    char terminator_b;
  } accepts[] = {
    { "http://127.0.0.1", ':', '/' },
    { "http://[::1]",     ':', '/' },
    { "http://localhost", ':', '/' },
  };
  for (size_t i = 0; i < sizeof(accepts) / sizeof(accepts[0]); ++i) {
    const char* p = accepts[i].prefix;
    size_t plen = strlen(p);
    if (lk_starts_with_ci(url, p)) {
      char next = url[plen];
      if (next == '\0' || next == accepts[i].terminator_a ||
          next == accepts[i].terminator_b) {
        return 1;
      }
    }
  }
  return 0;
}

// libcurl write callback — grows a heap buffer with a hard cap.
struct lk_buf {
  char* data;
  size_t len;
  size_t cap;
  int oom_or_overflow; // sticky flag → libcurl gets a short write
};

static size_t lk_write_cb(char* ptr, size_t size, size_t nmemb, void* userdata) {
  struct lk_buf* b = (struct lk_buf*)userdata;
  size_t n = size * nmemb;
  if (b->oom_or_overflow) return 0;
  if (b->len + n > LK_HTTP_MAX_BODY) {
    b->oom_or_overflow = 1;
    return 0;
  }
  if (b->len + n + 1 > b->cap) {
    size_t newcap = b->cap == 0 ? 4096 : b->cap;
    while (newcap < b->len + n + 1) {
      if (newcap > LK_HTTP_MAX_BODY) { b->oom_or_overflow = 1; return 0; }
      newcap *= 2;
    }
    if (newcap > LK_HTTP_MAX_BODY + 1) newcap = LK_HTTP_MAX_BODY + 1;
    char* nb = (char*)realloc(b->data, newcap);
    if (!nb) { b->oom_or_overflow = 1; return 0; }
    b->data = nb;
    b->cap = newcap;
  }
  memcpy(b->data + b->len, ptr, n);
  b->len += n;
  b->data[b->len] = '\0';
  return n;
}

// Public C ABI.
int lk_http_post_json(const char* url,
                      const char* body, size_t body_len,
                      int timeout_ms,
                      char** out_body, size_t* out_len,
                      long* out_status) {
  if (!url || !out_body || !out_len || !out_status) return LK_HTTP_ERR_URL;
  if (!lk_is_loopback_url(url)) return LK_HTTP_ERR_LOOPBACK;
  if (lk_curl_global_init_once() != 0) return LK_HTTP_ERR_INIT;

  CURL* eh = curl_easy_init();
  if (!eh) return LK_HTTP_ERR_INIT;

  struct curl_slist* headers = NULL;
  headers = curl_slist_append(headers, "Content-Type: application/json");
  if (!headers) { curl_easy_cleanup(eh); return LK_HTTP_ERR_OOM; }

  struct lk_buf buf = { NULL, 0, 0, 0 };

  curl_easy_setopt(eh, CURLOPT_URL, url);
  curl_easy_setopt(eh, CURLOPT_POST, 1L);
  curl_easy_setopt(eh, CURLOPT_POSTFIELDS, body ? body : "");
  curl_easy_setopt(eh, CURLOPT_POSTFIELDSIZE, (long)body_len);
  curl_easy_setopt(eh, CURLOPT_HTTPHEADER, headers);
  curl_easy_setopt(eh, CURLOPT_WRITEFUNCTION, lk_write_cb);
  curl_easy_setopt(eh, CURLOPT_WRITEDATA, &buf);
  curl_easy_setopt(eh, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(eh, CURLOPT_FOLLOWLOCATION, 0L);
  if (timeout_ms > 0) {
    curl_easy_setopt(eh, CURLOPT_TIMEOUT_MS, (long)timeout_ms);
  }
  // Connect timeout: cap on TCP handshake. Half the overall budget if
  // one is set, otherwise 2 s.
  long connect_timeout_ms = timeout_ms > 0 ? (long)timeout_ms / 2 : 2000;
  curl_easy_setopt(eh, CURLOPT_CONNECTTIMEOUT_MS, connect_timeout_ms);

  CURLcode rc = curl_easy_perform(eh);

  int ret;
  if (rc == CURLE_OPERATION_TIMEDOUT) {
    ret = LK_HTTP_ERR_TIMEOUT;
  } else if (buf.oom_or_overflow) {
    ret = LK_HTTP_ERR_TOO_LARGE;
  } else if (rc != CURLE_OK) {
    ret = LK_HTTP_ERR_TRANSPORT;
  } else {
    long status = 0;
    curl_easy_getinfo(eh, CURLINFO_RESPONSE_CODE, &status);
    *out_status = status;
    *out_body = buf.data ? buf.data : strdup("");
    *out_len = buf.len;
    ret = LK_HTTP_OK;
  }

  if (ret != LK_HTTP_OK && buf.data) free(buf.data);
  curl_slist_free_all(headers);
  curl_easy_cleanup(eh);
  return ret;
}

void lk_http_free(char* p) {
  if (p) free(p);
}

// ---------------------------------------------------------------------------
// Lean FFI shims. The Lean side calls these via @[extern] bindings; they
// translate from Lean objects to the C ABI above and back.
// ---------------------------------------------------------------------------

static lean_object* lk_http_string_err(const char* msg) {
  return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(msg)));
}

static const char* lk_http_err_name(int code) {
  switch (code) {
    case LK_HTTP_ERR_URL:       return "invalid url";
    case LK_HTTP_ERR_LOOPBACK:  return "non-loopback url refused";
    case LK_HTTP_ERR_TIMEOUT:   return "timeout";
    case LK_HTTP_ERR_TRANSPORT: return "transport error";
    case LK_HTTP_ERR_TOO_LARGE: return "response exceeded 8 MiB cap";
    case LK_HTTP_ERR_INIT:      return "curl init failed";
    case LK_HTTP_ERR_OOM:       return "out of memory";
    default:                    return "unknown http error";
  }
}

// Lean signature:
//   @[extern "lk_http_post_json"]
//   opaque postJsonRaw (url : @& String) (body : @& ByteArray) (timeoutMs : UInt32)
//     : IO (UInt32 × UInt32 × ByteArray)
//
// Returns a triple `(statusOrCode, kind, body)` where:
//   * On success      : kind=0, statusOrCode = HTTP status, body = response bytes.
//   * On any failure  : kind=N for the LK_HTTP_ERR_* constant (positive form),
//                       body is a UTF-8 description of the failure (empty if not
//                       available). statusOrCode = 0.
// Encoding the failure inline (instead of throwing) lets the Lean caller
// keep the structured Error enum without juggling exception traffic.
lean_object* lk_http_post_json_ffi(lean_object* url_obj,
                                   lean_object* body_obj,
                                   uint32_t timeout_ms) {
  const char* url = lean_string_cstr(url_obj);
  size_t body_len = lean_sarray_size(body_obj);
  const char* body = (const char*)lean_sarray_cptr(body_obj);

  char* out_body = NULL;
  size_t out_len = 0;
  long status = 0;
  int rc = lk_http_post_json(url, body, body_len, (int)timeout_ms,
                             &out_body, &out_len, &status);

  // Build the response triple. Lean's `structure RawResponse where
  //   status : UInt32; kind : UInt32; body : ByteArray`
  // is laid out objects-first: 1 object pointer (body) followed by
  // 8 bytes of scalar storage (status u32, kind u32) in declaration
  // order. Earlier versions of this shim passed `(0, 3, 0)` to
  // lean_alloc_ctor and boxed the two UInt32s as objects, which
  // corrupted the body field on read and segfaulted in
  // `Agent.Http.fromRaw` the first time `String.fromUTF8!` was
  // invoked on what the runtime thought was a ByteArray.
  uint32_t status_field = 0;
  uint32_t kind_field   = 0;
  lean_object* body_field = NULL;

  if (rc == LK_HTTP_OK) {
    status_field = (uint32_t)status;
    kind_field   = 0;
    // Move out_body bytes into a Lean ByteArray.
    body_field = lean_alloc_sarray(1, out_len, out_len);
    if (out_len > 0) memcpy(lean_sarray_cptr(body_field), out_body, out_len);
    lean_sarray_set_size(body_field, out_len);
    lk_http_free(out_body);
  } else {
    status_field = 0;
    kind_field   = (uint32_t)(-rc); // map negative code to positive kind
    const char* msg = lk_http_err_name(rc);
    size_t mlen = strlen(msg);
    body_field = lean_alloc_sarray(1, mlen, mlen);
    if (mlen > 0) memcpy(lean_sarray_cptr(body_field), msg, mlen);
    lean_sarray_set_size(body_field, mlen);
  }

  lean_object* tup = lean_alloc_ctor(0, /*num_objs=*/1, /*scalar_size=*/8);
  lean_ctor_set(tup, 0, body_field);
  // lean_ctor_set_uint32's `offset` is bytes from lean_ctor_obj_cptr(o)
  // (start of the object pointer area), not from the scalar area —
  // see Lean 4 runtime lean.h:lean_ctor_set_uint32, which asserts
  // `offset >= num_objs * sizeof(void*)`. The scalar block starts
  // after our 1 object pointer (8 bytes on 64-bit hosts).
  {
    const unsigned scalar_base = (unsigned)(sizeof(void*) * 1u);
    lean_ctor_set_uint32(tup, scalar_base + 0u, status_field);
    lean_ctor_set_uint32(tup, scalar_base + 4u, kind_field);
  }

  return lean_io_result_mk_ok(tup);
}
