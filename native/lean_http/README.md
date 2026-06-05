# lean_http

Loopback-only HTTP POST shim for the Lean-native agent
(`LeanCli/Agent/`).

Linked as `extern_lib liblean_http` in `lakefile.lean`. Built either by
`lake build` or by `script/setup_http.sh` (the latter mirrors
`script/setup_uds.sh`).

## ABI

```c
int  lk_http_post_json(const char* url,
                       const char* body, size_t body_len,
                       int timeout_ms,
                       char** out_body, size_t* out_len, long* out_status);
void lk_http_free(char* p);
```

* `url` MUST be `http://127.0.0.1[:p]/…`, `http://[::1][:p]/…`, or
  `http://localhost[:p]/…`. Anything else is refused at the C layer
  (`LK_HTTP_ERR_LOOPBACK`). No HTTPS.
* No redirects (`CURLOPT_FOLLOWLOCATION=0`). No signals
  (`CURLOPT_NOSIGNAL=1`). Response is capped at 8 MiB.
* Returns 0 on success; negative on error. The lean shim
  (`lk_http_post_json_ffi`) translates to the Lean
  `Agent.Http.RawResponse` struct rather than throwing.

## Trust model

This module is the C floor of the loopback check. The Lean wrapper
(`LeanCli/Agent/Http.lean::assertLoopback`) re-checks the same
string-prefix rule before calling in. Both checks are intentionally
redundant — defence in depth against a Lean bug or a wrapper-bypass via
FFI.

## Build

```
lake build       # via extern_lib liblean_http in lakefile.lean
script/setup_http.sh   # idempotent standalone build (mirrors setup_uds.sh)
```

Requires libcurl ≥ 7.80 (default on every supported distro) and a
working C toolchain. Linux-only.
