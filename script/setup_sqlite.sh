#!/usr/bin/env bash
# Build the lean_sqlite FFI shim into .lake/build/native, after
# verifying the host has sqlite3 development headers and an FTS5-enabled
# libsqlite3. Idempotent; safe to re-run.
#
# Trust note: this script does NOT vendor sqlite3 — see
# c/lean_sqlite/README.md for the system-libsqlite3 rationale.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEAN_PREFIX="$(lean --print-prefix)"
OUT_DIR="${ROOT}/.lake/build/native"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${OUT_DIR}"

# 1. Header probe. Use the compiler so we exercise the same include
#    path the Lean build will use.
if ! echo '#include <sqlite3.h>' | cc -E -x c - -o /dev/null 2>/dev/null; then
  echo "ERROR: sqlite3.h not found in the system include path." >&2
  echo "  Arch:  sudo pacman -S sqlite" >&2
  echo "  Debian/Ubuntu: sudo apt install libsqlite3-dev" >&2
  exit 1
fi

# 2. FTS5 probe. We rely on FTS5 for `messages_fts`; a libsqlite3
#    without FTS5 will compile fine and then fail at runtime when the
#    daemon tries to bootstrap the schema. Catch that here instead.
cat >"${TMP}/fts5_probe.c" <<'EOF'
#include <sqlite3.h>
#include <stdio.h>
int main(void) {
  sqlite3 *db = NULL;
  if (sqlite3_open(":memory:", &db) != SQLITE_OK) {
    fprintf(stderr, "open failed\n");
    return 1;
  }
  char *err = NULL;
  int rc = sqlite3_exec(db,
      "CREATE VIRTUAL TABLE t USING fts5(c);",
      NULL, NULL, &err);
  if (rc != SQLITE_OK) {
    fprintf(stderr, "fts5 probe failed: %s\n", err ? err : "(no msg)");
    if (err) sqlite3_free(err);
    sqlite3_close(db);
    return 2;
  }
  sqlite3_close(db);
  return 0;
}
EOF
cc -o "${TMP}/fts5_probe" "${TMP}/fts5_probe.c" -lsqlite3
if ! "${TMP}/fts5_probe"; then
  echo "ERROR: libsqlite3 lacks FTS5. Phase 1a requires it." >&2
  echo "  Arch's `sqlite` and Debian's `libsqlite3-0` ship FTS5 enabled;" >&2
  echo "  rebuild from source with -DSQLITE_ENABLE_FTS5 if you must." >&2
  exit 2
fi

# 3. Compile the shim.
cc -O2 -fPIC \
  -I"${LEAN_PREFIX}/include" \
  -I"${ROOT}/c/lean_sqlite" \
  -c "${ROOT}/c/lean_sqlite/lean_sqlite.c" \
  -o "${OUT_DIR}/lean_sqlite.o"

ar rcs "${OUT_DIR}/liblean_sqlite.a" "${OUT_DIR}/lean_sqlite.o"

cat <<EOF
sqlite FFI built at:
  ${OUT_DIR}/lean_sqlite.o
  ${OUT_DIR}/liblean_sqlite.a
sqlite3: $(sqlite3 -version 2>/dev/null | head -n1 || echo 'cli not on PATH (lib present)')
fts5 probe: OK
linker hint (caller links libsqlite3): -lsqlite3
EOF
