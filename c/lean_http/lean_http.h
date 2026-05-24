// SPDX-License-Identifier: MIT
//
// Tiny libcurl wrapper for the Lean-native agent. Loopback-only HTTP
// POST with JSON body. No TLS, no redirects, no auth, no cookies.
//
// Trust model: the agent calls a local LLM server (llama-server / vLLM
// / Ollama /v1) at 127.0.0.1 or ::1. Anything else is refused at this
// layer — defence in depth against a misconfiguration that would leak
// prompts to a remote endpoint. The Lean wrapper enforces the same
// rule again; both checks are intentionally redundant.

#ifndef LEANKOHAKU_LEAN_HTTP_H
#define LEANKOHAKU_LEAN_HTTP_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Error codes (negative). 0 means success.
#define LK_HTTP_OK            0
#define LK_HTTP_ERR_URL       (-1) // URL did not parse
#define LK_HTTP_ERR_LOOPBACK  (-2) // URL host was not 127.0.0.1 / ::1 / localhost
#define LK_HTTP_ERR_TIMEOUT   (-3) // libcurl reported CURLE_OPERATION_TIMEDOUT
#define LK_HTTP_ERR_TRANSPORT (-4) // any other libcurl transport error
#define LK_HTTP_ERR_TOO_LARGE (-5) // response exceeded the 8 MiB cap
#define LK_HTTP_ERR_INIT      (-6) // curl_easy_init returned NULL
#define LK_HTTP_ERR_OOM       (-7) // malloc/realloc failure

// POST `body` (length `body_len`) as Content-Type: application/json to
// `url`. On success, allocates `*out_body` (heap, caller frees via
// `lk_http_free`), writes its length to `*out_len`, and the HTTP status
// to `*out_status`. On failure returns a negative error code; the out
// pointers are left untouched. `timeout_ms` bounds the whole operation.
int lk_http_post_json(const char* url,
                      const char* body, size_t body_len,
                      int timeout_ms,
                      char** out_body, size_t* out_len,
                      long* out_status);

// Free a buffer returned by lk_http_post_json. No-op on NULL.
void lk_http_free(char* p);

#ifdef __cplusplus
}
#endif

#endif // LEANKOHAKU_LEAN_HTTP_H
