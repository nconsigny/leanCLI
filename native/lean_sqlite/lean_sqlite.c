// SPDX-License-Identifier: MIT
//
// Implementation of the SQLite wrapper declared in lean_sqlite.h, plus
// the Lean FFI shims consumed by LeanCli/Agent/Session.lean via
// `@[extern]`. Matches the pattern in c/lean_uds/lean_uds.c and
// c/lean_http/lean_http.c.
//
// Column-text lifetime. SQLite's sqlite3_column_text returns a pointer
// that is valid only until the next call to sqlite3_step or
// sqlite3_finalize on the same statement. The Lean side calls
// `columnText` and then keeps the resulting Lean `String` across
// further DB calls, so this shim copies the bytes out of the SQLite
// buffer into a freshly-allocated Lean String before returning. This
// is documented in lean_sqlite.h and exercised by the session test
// (`appendMessage` x10 followed by `loadSession`).

#define _GNU_SOURCE

#include "lean_sqlite.h"

#include <lean/lean.h>

#include <sqlite3.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------------------
// Public C ABI (used by the Lean shims below and by the FTS5 probe in
// script/setup_sqlite.sh).
// ---------------------------------------------------------------------------

int lk_sqlite_open(const char* path, void** out_handle) {
  if (!path || !out_handle) return LK_SQLITE_ERR_OPEN;
  sqlite3* db = NULL;
  int rc = sqlite3_open_v2(path, &db,
                           SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                           NULL);
  if (rc != SQLITE_OK) {
    if (db) sqlite3_close_v2(db);
    *out_handle = NULL;
    return LK_SQLITE_ERR_OPEN;
  }
  // Reasonable defaults: WAL for concurrent readers + writer, normal
  // sync (durability is the OS's responsibility — session history is
  // not critical infrastructure), and a 5 s busy timeout so a brief
  // contention does not surface as a hard error.
  (void)sqlite3_exec(db, "PRAGMA journal_mode=WAL;", NULL, NULL, NULL);
  (void)sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", NULL, NULL, NULL);
  sqlite3_busy_timeout(db, 5000);
  *out_handle = (void*)db;
  return LK_SQLITE_OK;
}

void lk_sqlite_close(void* handle) {
  if (!handle) return;
  sqlite3_close_v2((sqlite3*)handle);
}

int lk_sqlite_exec(void* handle, const char* sql, char** out_err) {
  if (!handle || !sql) return LK_SQLITE_ERR_HANDLE;
  char* msg = NULL;
  int rc = sqlite3_exec((sqlite3*)handle, sql, NULL, NULL, &msg);
  if (rc != SQLITE_OK) {
    if (out_err) {
      *out_err = msg ? strdup(msg) : strdup("sqlite3_exec failed");
    }
    if (msg) sqlite3_free(msg);
    return LK_SQLITE_ERR_EXEC;
  }
  if (msg) sqlite3_free(msg);
  return LK_SQLITE_OK;
}

int lk_sqlite_prepare(void* handle, const char* sql, void** out_stmt) {
  if (!handle || !sql || !out_stmt) return LK_SQLITE_ERR_HANDLE;
  sqlite3_stmt* stmt = NULL;
  int rc = sqlite3_prepare_v2((sqlite3*)handle, sql, -1, &stmt, NULL);
  if (rc != SQLITE_OK) {
    if (stmt) sqlite3_finalize(stmt);
    *out_stmt = NULL;
    return LK_SQLITE_ERR_PREPARE;
  }
  *out_stmt = (void*)stmt;
  return LK_SQLITE_OK;
}

int lk_sqlite_bind_text(void* stmt, int idx, const char* text) {
  if (!stmt) return LK_SQLITE_ERR_HANDLE;
  int rc = sqlite3_bind_text((sqlite3_stmt*)stmt, idx,
                             text ? text : "", -1, SQLITE_TRANSIENT);
  return rc == SQLITE_OK ? LK_SQLITE_OK : LK_SQLITE_ERR_BIND;
}

int lk_sqlite_bind_int64(void* stmt, int idx, long long val) {
  if (!stmt) return LK_SQLITE_ERR_HANDLE;
  int rc = sqlite3_bind_int64((sqlite3_stmt*)stmt, idx, (sqlite3_int64)val);
  return rc == SQLITE_OK ? LK_SQLITE_OK : LK_SQLITE_ERR_BIND;
}

int lk_sqlite_step(void* stmt) {
  if (!stmt) return LK_SQLITE_ERR_HANDLE;
  int rc = sqlite3_step((sqlite3_stmt*)stmt);
  if (rc == SQLITE_ROW) return LK_SQLITE_ROW;
  if (rc == SQLITE_DONE) return LK_SQLITE_DONE;
  return LK_SQLITE_ERR_STEP;
}

const char* lk_sqlite_column_text(void* stmt, int idx) {
  if (!stmt) return NULL;
  return (const char*)sqlite3_column_text((sqlite3_stmt*)stmt, idx);
}

long long lk_sqlite_column_int64(void* stmt, int idx) {
  if (!stmt) return 0;
  return (long long)sqlite3_column_int64((sqlite3_stmt*)stmt, idx);
}

int lk_sqlite_finalize(void* stmt) {
  if (!stmt) return LK_SQLITE_OK;
  int rc = sqlite3_finalize((sqlite3_stmt*)stmt);
  return rc == SQLITE_OK ? LK_SQLITE_OK : LK_SQLITE_ERR_STEP;
}

const char* lk_sqlite_errmsg(void* handle) {
  if (!handle) return "no handle";
  return sqlite3_errmsg((sqlite3*)handle);
}

void lk_sqlite_free_err(char* err) {
  if (err) free(err);
}

// ---------------------------------------------------------------------------
// Lean FFI shims. The Lean side calls these via @[extern] bindings.
//
// Handles and statements are passed across the boundary as
// `USize` (boxed pointer values). This is the same approach
// `c/lean_uds/lean_uds.c` uses for socket file descriptors.
// ---------------------------------------------------------------------------

static lean_object* lk_sqlite_string_err(const char* msg) {
  return lean_io_result_mk_error(
      lean_mk_io_user_error(lean_mk_string(msg ? msg : "sqlite error")));
}

// open : @& String -> IO (USize)        (throws on failure)
lean_object* lk_sqlite_open_ffi(lean_object* path_obj) {
  const char* path = lean_string_cstr(path_obj);
  void* handle = NULL;
  int rc = lk_sqlite_open(path, &handle);
  if (rc != LK_SQLITE_OK) {
    char buf[256];
    snprintf(buf, sizeof(buf), "sqlite open failed: %s", path);
    return lk_sqlite_string_err(buf);
  }
  return lean_io_result_mk_ok(lean_box_usize((size_t)handle));
}

// close : USize -> IO Unit
lean_object* lk_sqlite_close_ffi(size_t handle) {
  lk_sqlite_close((void*)handle);
  return lean_io_result_mk_ok(lean_box(0));
}

// exec : USize -> @& String -> IO Unit  (throws with errmsg on failure)
lean_object* lk_sqlite_exec_ffi(size_t handle, lean_object* sql_obj) {
  const char* sql = lean_string_cstr(sql_obj);
  char* err = NULL;
  int rc = lk_sqlite_exec((void*)handle, sql, &err);
  if (rc != LK_SQLITE_OK) {
    char buf[512];
    snprintf(buf, sizeof(buf), "sqlite exec failed: %s",
             err ? err : "unknown");
    if (err) lk_sqlite_free_err(err);
    return lk_sqlite_string_err(buf);
  }
  return lean_io_result_mk_ok(lean_box(0));
}

// prepare : USize -> @& String -> IO USize
lean_object* lk_sqlite_prepare_ffi(size_t handle, lean_object* sql_obj) {
  const char* sql = lean_string_cstr(sql_obj);
  void* stmt = NULL;
  int rc = lk_sqlite_prepare((void*)handle, sql, &stmt);
  if (rc != LK_SQLITE_OK) {
    char buf[512];
    snprintf(buf, sizeof(buf), "sqlite prepare failed: %s: %s",
             sql, lk_sqlite_errmsg((void*)handle));
    return lk_sqlite_string_err(buf);
  }
  return lean_io_result_mk_ok(lean_box_usize((size_t)stmt));
}

// bindText : USize -> UInt32 -> @& String -> IO Unit
lean_object* lk_sqlite_bind_text_ffi(size_t stmt, uint32_t idx,
                                     lean_object* text_obj) {
  const char* text = lean_string_cstr(text_obj);
  int rc = lk_sqlite_bind_text((void*)stmt, (int)idx, text);
  if (rc != LK_SQLITE_OK) {
    return lk_sqlite_string_err("sqlite bind_text failed");
  }
  return lean_io_result_mk_ok(lean_box(0));
}

// bindInt64 : USize -> UInt32 -> UInt64 -> IO Unit
//   Matches columnInt64 — Phase 1a only binds non-negative values.
lean_object* lk_sqlite_bind_int64_ffi(size_t stmt, uint32_t idx,
                                      uint64_t val) {
  int rc = lk_sqlite_bind_int64((void*)stmt, (int)idx, (long long)val);
  if (rc != LK_SQLITE_OK) {
    return lk_sqlite_string_err("sqlite bind_int64 failed");
  }
  return lean_io_result_mk_ok(lean_box(0));
}

// step : USize -> IO UInt32
//   Returns 100 (ROW), 101 (DONE), or throws on error.
lean_object* lk_sqlite_step_ffi(size_t stmt) {
  int rc = lk_sqlite_step((void*)stmt);
  if (rc == LK_SQLITE_ROW || rc == LK_SQLITE_DONE) {
    return lean_io_result_mk_ok(lean_box_uint32((uint32_t)rc));
  }
  return lk_sqlite_string_err("sqlite step failed");
}

// columnText : USize -> UInt32 -> IO String
//   Returns the empty string when the column is NULL. Copy is made
//   inside `lean_mk_string`, so the returned String is safe to keep
//   across further DB calls.
lean_object* lk_sqlite_column_text_ffi(size_t stmt, uint32_t idx) {
  const char* p = lk_sqlite_column_text((void*)stmt, (int)idx);
  return lean_io_result_mk_ok(lean_mk_string(p ? p : ""));
}

// columnInt64 : USize -> UInt32 -> IO UInt64
//   Phase 1a only stores non-negative values (autoincrement rowids,
//   timestamps, monotonic seq counters). A negative value would be
//   silently clamped to a huge u64; we don't write such values so
//   this can't happen in practice. The Lean side does a safe
//   narrowing via `UInt64.toNat`.
lean_object* lk_sqlite_column_int64_ffi(size_t stmt, uint32_t idx) {
  long long v = lk_sqlite_column_int64((void*)stmt, (int)idx);
  return lean_io_result_mk_ok(lean_box_uint64((uint64_t)v));
}

// finalize : USize -> IO Unit
lean_object* lk_sqlite_finalize_ffi(size_t stmt) {
  (void)lk_sqlite_finalize((void*)stmt);
  return lean_io_result_mk_ok(lean_box(0));
}

// errmsg : USize -> IO String
lean_object* lk_sqlite_errmsg_ffi(size_t handle) {
  const char* m = lk_sqlite_errmsg((void*)handle);
  return lean_io_result_mk_ok(lean_mk_string(m ? m : ""));
}
