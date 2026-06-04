// SPDX-License-Identifier: MIT
//
// Tiny SQLite wrapper for the persistent Lean-native agent (`leancli-
// agentd`). Backed by the system libsqlite3 — Arch (`sqlite`) and
// Debian 12+ (`libsqlite3-0`) ship FTS5-enabled binaries, which is the
// only optional feature we rely on. Vendoring the amalgamation would
// duplicate ~250 KLOC and divorce our CVE patching from the distro;
// linking against the system library keeps the surface narrow.
//
// Trust model: the session DB stores agent conversation history only.
// It never contains private keys, seed material, or signing payloads
// (the agent import graph forbids those modules). The DB file mode is
// 0600 and lives under XDG_DATA_HOME; the parent dir is 0700.
//
// Threading: callers must serialise their own access. The Phase 1a
// daemon opens exactly one Handle and routes all requests through a
// single accept loop, so no internal locking is needed beyond what
// SQLite gives us in its default (serialised) threading mode.

#ifndef LEANCLI_LEAN_SQLITE_H
#define LEANCLI_LEAN_SQLITE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Return codes. 0 means success; negative codes are our own
// classification, positive codes are SQLite's raw `int` extended
// result codes passed through verbatim for diagnostics.
#define LK_SQLITE_OK             0
#define LK_SQLITE_ROW            100  // sqlite3_step: row available
#define LK_SQLITE_DONE           101  // sqlite3_step: end of result set
#define LK_SQLITE_ERR_OPEN      (-1)  // sqlite3_open_v2 failed
#define LK_SQLITE_ERR_PREPARE   (-2)  // sqlite3_prepare_v2 failed
#define LK_SQLITE_ERR_BIND      (-3)  // sqlite3_bind_* failed
#define LK_SQLITE_ERR_STEP      (-4)  // sqlite3_step returned an error
#define LK_SQLITE_ERR_EXEC      (-5)  // sqlite3_exec failed
#define LK_SQLITE_ERR_HANDLE    (-6)  // NULL handle or stmt passed in
#define LK_SQLITE_ERR_OOM       (-7)  // malloc failure

// Open `path`. On success, writes a non-NULL opaque handle into
// `*out_handle`. On failure, leaves `*out_handle` NULL and returns
// LK_SQLITE_ERR_OPEN.
//
// Opens with SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE so a missing
// file is created. After the FFI shim returns control to Lean, the
// caller should `chmod(path, 0600)` — the C side does not own file
// permissions because the same handle type is intended for in-memory
// (`:memory:`) DBs in tests.
int  lk_sqlite_open(const char* path, void** out_handle);

// Close a handle. No-op on NULL. Finalises any leaked statements
// implicitly via sqlite3_close_v2.
void lk_sqlite_close(void* handle);

// Run `sql` for side effect (no rows expected). On failure, copies the
// SQLite error message into a freshly-allocated buffer at `*out_err`
// (caller frees via `lk_sqlite_free_err`) and returns
// LK_SQLITE_ERR_EXEC. On success, leaves `*out_err` untouched and
// returns LK_SQLITE_OK.
int  lk_sqlite_exec(void* handle, const char* sql, char** out_err);

// Prepare `sql`. Writes the opaque statement handle into `*out_stmt`
// on success.
int  lk_sqlite_prepare(void* handle, const char* sql, void** out_stmt);

// Bind by 1-indexed parameter slot.
int  lk_sqlite_bind_text(void* stmt, int idx, const char* text);
int  lk_sqlite_bind_int64(void* stmt, int idx, long long val);

// Advance the cursor. Returns LK_SQLITE_ROW when a row is ready,
// LK_SQLITE_DONE at end of result set, LK_SQLITE_ERR_STEP on error.
int  lk_sqlite_step(void* stmt);

// Read the current row's column at `idx` (0-indexed). Pointer is owned
// by SQLite and is valid only until the next `_step` or `_finalize`;
// the Lean shim copies bytes out before returning to caller.
// `column_text` may return NULL if the column is NULL.
const char* lk_sqlite_column_text(void* stmt, int idx);
long long   lk_sqlite_column_int64(void* stmt, int idx);

// Release the statement. Safe to call on a partially-stepped or
// errored stmt.
int  lk_sqlite_finalize(void* stmt);

// Last error message for `handle`. Pointer is owned by SQLite; copy
// before further calls.
const char* lk_sqlite_errmsg(void* handle);

// Free an error buffer returned through `out_err` by `_exec`.
void lk_sqlite_free_err(char* err);

#ifdef __cplusplus
}
#endif

#endif // LEANCLI_LEAN_SQLITE_H
