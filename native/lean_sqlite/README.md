# `c/lean_sqlite/` — SQLite FFI shim

Linked into the Lean library via `extern_lib liblean_sqlite` in
`lakefile.lean`. Consumed by `LeanCli/Agent/Session.lean` to back
the persistent session DB read/written by `leancli-agentd`.

## What's in here

- `lean_sqlite.h` — public C ABI (`lk_sqlite_*`).
- `lean_sqlite.c` — implementation + the `@[extern]` shims Lean
  imports.

## Why we use the system libsqlite3

The Arch package `sqlite` and the Debian 12+ package `libsqlite3-0`
both ship binaries with FTS5 enabled. That is the only optional
feature this codebase relies on. Vendoring the SQLite amalgamation
would:

1. Add roughly 250 KLOC of C to the tree.
2. Duplicate work the distros already do well.
3. Introduce a second source of truth for CVE patching — every
   SQLite advisory would need to be re-applied locally rather than
   being absorbed by a normal `pacman -Syu` / `apt upgrade`.

The tradeoff is that we depend on the distro's SQLite version. The
build script `script/setup_sqlite.sh` probes for `sqlite3.h` and
compiles a tiny program that creates an FTS5 virtual table; if either
check fails, the script exits non-zero with a clear message.

## Column-text lifetime

`sqlite3_column_text()` returns a pointer that is valid only until the
next `sqlite3_step` / `sqlite3_finalize` on the same statement. The
Lean FFI shim copies the bytes into a Lean `String` (via
`lean_mk_string`) before returning, so the value can safely outlive
further DB calls. This is the "safer than zero-copy" trade the Phase
1a brief approved up front.

## Threading

The Phase 1a daemon (`leancli-agentd`) opens exactly one DB handle and
serialises all access through its accept loop. SQLite is in serialised
threading mode by default; no extra Lean-side locking is needed.

## Trust

The DB stores agent conversation history only. The agent module's
import graph forbids `Crypto.Secp256k1Native`, `Crypto.Random`,
`Wallet.{EOA,HDKey,Mnemonic,Entropy}`, `Keystore/**`, and
`Daemon.State`, so by construction no key material can be written
into it. File mode is `0600`; parent directory mode is `0700`.
