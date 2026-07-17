import LeanCli.Encoding.Json

/-!
# StateVault — persistent, provenance-tagged partial chain state

The wallet's "partial state node": an on-disk store of the chain state
this wallet has touched — token metadata, contract code, verified block
headers/state roots, account balances/nonces, and storage slots — so
repeated reads stop depending on third parties. The direction is the
inverse of a pruning full node: a light client that *starts remembering
things* it has already verified.

Every row carries a provenance `Tier` recording HOW the value was
obtained:

  * `rpcUnverified`     — direct configured-RPC read, no verification.
  * `consensusVerified` — served through a light client (helios/colibri)
                          that Merkle-verified it against sync-committee-
                          attested state.
  * `leanProven`        — a Merkle-Patricia proof was verified IN LEAN
                          (`LeanCli.Ethereum.Mpt`) against a consensus-
                          verified state root. Strongest tier: the proof
                          step no longer trusts the light-client binary.

Trust contract (INVARIANTS.md Category 16):

  1. *Provenance monotonicity* — a stored tier is exactly the tier of the
     read that produced it, and immutable rows are never overwritten by a
     lower-tier read (`shouldReplace`). Unknown tier strings parse DOWN to
     `rpcUnverified`, never up.
  2. *Staleness honesty* — mutable rows (accounts, storage) are keyed by
     the block they were proven at and always rendered with it; there is
     no code path that presents vault state as head state.
  3. *Signing independence* — nothing read from this store gates a
     signature. The pre-sign pipeline (`tx.decodeIntent → tx.simulate →
     ConfirmGate`) runs against fresh verified state exactly as before;
     the vault is a display/offline/prefetch tier only. Structurally,
     this module imports no signing or key-material module, and no
     signing module imports it.

The DB lives at `$XDG_DATA_HOME/leancli/statevault.db` (mode 0600, parent
0700) — chain data only, never key material. Disable persistence entirely
with `LEANCLI_VAULT=0`. This module has its own private SQLite bindings
(same `lk_sqlite_*` shim as the agent session store): the agent-layer
bindings in `LeanCli.Agent.Session` are private and layer-4, and the
daemon (layer 3) must not import the agent.
-/

namespace LeanCli.Daemon.StateVault

open LeanCli.Encoding.Json

/-- Provenance of a vault row: how the value was obtained. Ordered by
    trust; `rank` gives the total order used by `shouldReplace`. -/
inductive Tier where
  | rpcUnverified
  | consensusVerified
  | leanProven
  deriving Repr, DecidableEq, Inhabited

def Tier.rank : Tier → Nat
  | .rpcUnverified     => 0
  | .consensusVerified => 1
  | .leanProven        => 2

def Tier.asString : Tier → String
  | .rpcUnverified     => "rpc"
  | .consensusVerified => "consensus"
  | .leanProven        => "lean"

/-- Parse a stored tier tag. FAIL-SAFE DOWNWARD: anything unrecognized
    (including rows written by a future schema) reads as `rpcUnverified`
    so a corrupt or tampered tag can never claim verification. -/
def Tier.ofString : String → Tier
  | "consensus" => .consensusVerified
  | "lean"      => .leanProven
  | _           => .rpcUnverified

/-- `a ≤ b` in trust order. -/
def Tier.le (a b : Tier) : Bool := a.rank ≤ b.rank

/-- Replacement policy for rows NOT keyed by block (token metadata,
    code): a new observation may overwrite an existing row only when its
    tier is at least the stored one, so re-reading over direct RPC never
    downgrades a consensus-verified fact. -/
def shouldReplace (stored incoming : Tier) : Bool :=
  stored.le incoming

/-- Classify the provenance of a read from the presence of a verified-
    read backend: `none` (direct RPC) → `rpcUnverified`; `some` (helios /
    colibri `VerifyVia`) → `consensusVerified`. Polymorphic so it can be
    stated and proved without importing the Outbound layer. -/
def tierOfVia {α : Type} : Option α → Tier
  | none   => .rpcUnverified
  | some _ => .consensusVerified

/-- Tier assigned to a Lean-verified MPT proof, as a function of the tier
    of the state root it was verified against. A proof against an
    unverified root proves only internal consistency — the result stays
    `rpcUnverified`. Only a consensus-verified root upgrades the entry to
    `leanProven`. (`leanProven` roots do not occur — headers come from a
    light client or direct RPC — but map to `leanProven` for totality.) -/
def pinTier : Tier → Tier
  | .rpcUnverified     => .rpcUnverified
  | .consensusVerified => .leanProven
  | .leanProven        => .leanProven

/-! ## SQLite bindings (private to this module) -/

/-- Opaque SQLite DB handle. Private constructor — no forged pointers. -/
structure Handle where
  private mk ::
  ptr : USize
  deriving Inhabited

private structure Stmt where
  mk ::
  ptr : USize

@[extern "lk_sqlite_open_ffi"]
private opaque sqliteOpen (path : @& String) : IO USize

@[extern "lk_sqlite_close_ffi"]
private opaque sqliteClose (h : USize) : IO Unit

@[extern "lk_sqlite_exec_ffi"]
private opaque sqliteExec (h : USize) (sql : @& String) : IO Unit

@[extern "lk_sqlite_prepare_ffi"]
private opaque sqlitePrepare (h : USize) (sql : @& String) : IO USize

@[extern "lk_sqlite_bind_text_ffi"]
private opaque sqliteBindText (s : USize) (idx : UInt32) (text : @& String) : IO Unit

@[extern "lk_sqlite_bind_int64_ffi"]
private opaque sqliteBindInt64 (s : USize) (idx : UInt32) (val : UInt64) : IO Unit

@[extern "lk_sqlite_step_ffi"]
private opaque sqliteStep (s : USize) : IO UInt32

@[extern "lk_sqlite_column_text_ffi"]
private opaque sqliteColumnText (s : USize) (idx : UInt32) : IO String

@[extern "lk_sqlite_column_int64_ffi"]
private opaque sqliteColumnInt64 (s : USize) (idx : UInt32) : IO UInt64

@[extern "lk_sqlite_finalize_ffi"]
private opaque sqliteFinalize (s : USize) : IO Unit

private def stepRow : UInt32 := 100
private def stepDone : UInt32 := 101

private def exec (h : Handle) (sql : String) : IO Unit :=
  sqliteExec h.ptr sql

private def withStmt {α : Type}
    (h : Handle) (sql : String) (k : Stmt → IO α) : IO α := do
  let ptr ← sqlitePrepare h.ptr sql
  let stmt : Stmt := ⟨ptr⟩
  try
    k stmt
  finally
    try sqliteFinalize stmt.ptr catch _ => pure ()

/-! ## Schema -/

/-- Schema v1. Immutable-ish facts (`token_meta`, `code`, `no_code`) are
    keyed by `(chain_id, addr)`; mutable state (`accounts`, `storage`) is
    keyed additionally by the block it was proven at — staleness honesty
    is structural. `updated_ord` is a monotonic-clock ordinal (recency
    ordering only, not wall time — same convention as the session store). -/
private def schemaSql : String :=
  "BEGIN;\n" ++
  "CREATE TABLE IF NOT EXISTS vault_meta (version INTEGER NOT NULL);\n" ++
  "INSERT INTO vault_meta (version)\n" ++
  "  SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM vault_meta);\n" ++
  "CREATE TABLE IF NOT EXISTS token_meta (\n" ++
  "  chain_id INTEGER NOT NULL,\n" ++
  "  addr TEXT NOT NULL,\n" ++
  "  decimals INTEGER NOT NULL,\n" ++
  "  symbol TEXT NOT NULL,\n" ++
  "  tier TEXT NOT NULL,\n" ++
  "  updated_ord INTEGER NOT NULL,\n" ++
  "  PRIMARY KEY (chain_id, addr)\n" ++
  ");\n" ++
  "CREATE TABLE IF NOT EXISTS no_code (\n" ++
  "  chain_id INTEGER NOT NULL,\n" ++
  "  addr TEXT NOT NULL,\n" ++
  "  updated_ord INTEGER NOT NULL,\n" ++
  "  PRIMARY KEY (chain_id, addr)\n" ++
  ");\n" ++
  "CREATE TABLE IF NOT EXISTS code (\n" ++
  "  chain_id INTEGER NOT NULL,\n" ++
  "  addr TEXT NOT NULL,\n" ++
  "  code_hex TEXT NOT NULL,\n" ++
  "  tier TEXT NOT NULL,\n" ++
  "  updated_ord INTEGER NOT NULL,\n" ++
  "  PRIMARY KEY (chain_id, addr)\n" ++
  ");\n" ++
  "CREATE TABLE IF NOT EXISTS headers (\n" ++
  "  chain_id INTEGER NOT NULL,\n" ++
  "  block_number INTEGER NOT NULL,\n" ++
  "  block_hash TEXT NOT NULL,\n" ++
  "  state_root TEXT NOT NULL,\n" ++
  "  ts INTEGER NOT NULL,\n" ++
  "  tier TEXT NOT NULL,\n" ++
  "  updated_ord INTEGER NOT NULL,\n" ++
  "  PRIMARY KEY (chain_id, block_number)\n" ++
  ");\n" ++
  "CREATE TABLE IF NOT EXISTS accounts (\n" ++
  "  chain_id INTEGER NOT NULL,\n" ++
  "  addr TEXT NOT NULL,\n" ++
  "  block_number INTEGER NOT NULL,\n" ++
  "  balance_hex TEXT NOT NULL,\n" ++
  "  nonce INTEGER NOT NULL,\n" ++
  "  storage_root TEXT NOT NULL,\n" ++
  "  code_hash TEXT NOT NULL,\n" ++
  "  tier TEXT NOT NULL,\n" ++
  "  updated_ord INTEGER NOT NULL,\n" ++
  "  PRIMARY KEY (chain_id, addr, block_number)\n" ++
  ");\n" ++
  "CREATE INDEX IF NOT EXISTS idx_accounts_lookup ON accounts(chain_id, addr, block_number DESC);\n" ++
  "CREATE TABLE IF NOT EXISTS storage (\n" ++
  "  chain_id INTEGER NOT NULL,\n" ++
  "  addr TEXT NOT NULL,\n" ++
  "  slot TEXT NOT NULL,\n" ++
  "  block_number INTEGER NOT NULL,\n" ++
  "  value_hex TEXT NOT NULL,\n" ++
  "  tier TEXT NOT NULL,\n" ++
  "  updated_ord INTEGER NOT NULL,\n" ++
  "  PRIMARY KEY (chain_id, addr, slot, block_number)\n" ++
  ");\n" ++
  "CREATE INDEX IF NOT EXISTS idx_storage_lookup ON storage(chain_id, addr, slot, block_number DESC);\n" ++
  "COMMIT;"

private def expectedSchemaVersion : Nat := 1

private def checkSchemaVersion (h : Handle) : IO Unit := do
  withStmt h "SELECT version FROM vault_meta LIMIT 1;" fun s => do
    let rc ← sqliteStep s.ptr
    if rc == stepRow then
      let v ← sqliteColumnInt64 s.ptr 0
      if v.toNat ≠ expectedSchemaVersion then
        throw <| IO.userError
          s!"statevault: schema mismatch (db={v.toNat} expected={expectedSchemaVersion})"
    else
      throw <| IO.userError "statevault: vault_meta row missing"

/-- Open `path` and bootstrap the schema. Caller enforces file modes
    (skipped here so `:memory:` test handles work). -/
def openDb (path : String) : IO Handle := do
  let ptr ← sqliteOpen path
  let h : Handle := ⟨ptr⟩
  exec h schemaSql
  checkSchemaVersion h
  pure h

def close (h : Handle) : IO Unit :=
  sqliteClose h.ptr

/-- Default on-disk location: `$XDG_DATA_HOME/leancli/statevault.db`
    (fallback `~/.local/share/leancli/statevault.db`). Overridable via
    `LEANCLI_VAULT_DB` for tests. -/
def defaultPath : IO String := do
  match ← IO.getEnv "LEANCLI_VAULT_DB" with
  | some s => pure s
  | none =>
      let data ← match ← IO.getEnv "XDG_DATA_HOME" with
        | some d => pure d
        | none =>
            match ← IO.getEnv "HOME" with
            | some home => pure s!"{home}/.local/share"
            | none => pure "/tmp"
      pure s!"{data}/leancli/statevault.db"

/-- Open the default vault DB, creating parent dirs (0700) and enforcing
    file mode 0600. -/
def openDefault : IO Handle := do
  let path ← defaultPath
  let fp : System.FilePath := path
  match fp.parent with
  | some parent =>
      IO.FS.createDirAll parent
      let _ ← IO.Process.output { cmd := "chmod", args := #["700", parent.toString] }
  | none => pure ()
  let h ← openDb path
  let _ ← IO.Process.output { cmd := "chmod", args := #["600", path] }
  pure h

private def nowOrd : IO UInt64 := do
  pure ((← IO.monoMsNow).toUInt64)

/-! ## Typed rows -/

/-- A verified block header pin: the `(block, stateRoot)` anchor every
    Lean-verified proof hangs off. -/
structure HeaderEntry where
  chainId     : Nat
  blockNumber : Nat
  blockHash   : String
  stateRoot   : String
  timestamp   : Nat
  tier        : Tier
  deriving Repr, Inhabited

def HeaderEntry.toJson (e : HeaderEntry) : Json :=
  .obj #[
    ("chainId",   .num (Int.ofNat e.chainId)),
    ("block",     .num (Int.ofNat e.blockNumber)),
    ("blockHash", .str e.blockHash),
    ("stateRoot", .str e.stateRoot),
    ("timestamp", .num (Int.ofNat e.timestamp)),
    ("tier",      .str e.tier.asString)
  ]

/-- Account state as of a specific block — never "current". -/
structure AccountEntry where
  chainId     : Nat
  addr        : String
  blockNumber : Nat
  balanceHex  : String
  nonce       : Nat
  storageRoot : String
  codeHash    : String
  tier        : Tier
  deriving Repr, Inhabited

def AccountEntry.toJson (e : AccountEntry) : Json :=
  .obj #[
    ("chainId",     .num (Int.ofNat e.chainId)),
    ("address",     .str e.addr),
    ("block",       .num (Int.ofNat e.blockNumber)),
    ("balance",     .str e.balanceHex),
    ("nonce",       .num (Int.ofNat e.nonce)),
    ("storageRoot", .str e.storageRoot),
    ("codeHash",    .str e.codeHash),
    ("tier",        .str e.tier.asString)
  ]

/-- One storage slot as of a specific block. -/
structure StorageEntry where
  chainId     : Nat
  addr        : String
  slot        : String
  blockNumber : Nat
  valueHex    : String
  tier        : Tier
  deriving Repr, Inhabited

def StorageEntry.toJson (e : StorageEntry) : Json :=
  .obj #[
    ("chainId", .num (Int.ofNat e.chainId)),
    ("address", .str e.addr),
    ("slot",    .str e.slot),
    ("block",   .num (Int.ofNat e.blockNumber)),
    ("value",   .str e.valueHex),
    ("tier",    .str e.tier.asString)
  ]

private def normAddr (a : String) : String := a.toLower

/-! ## Token metadata -/

/-- Stored tier for a `(chain, addr)` token-meta row, if present. -/
private def tokenMetaTier? (h : Handle) (chainId : Nat) (addr : String) :
    IO (Option Tier) := do
  withStmt h "SELECT tier FROM token_meta WHERE chain_id = ? AND addr = ?;" fun s => do
    sqliteBindInt64 s.ptr 1 chainId.toUInt64
    sqliteBindText s.ptr 2 (normAddr addr)
    let rc ← sqliteStep s.ptr
    if rc == stepRow then
      pure (some (Tier.ofString (← sqliteColumnText s.ptr 0)))
    else
      pure none

/-- Insert/upgrade a token-meta row. No-downgrade: an existing row is
    replaced only when `shouldReplace stored incoming` holds. -/
def putTokenMeta (h : Handle) (chainId : Nat) (addr : String)
    (decimals : Nat) (symbol : String) (tier : Tier) : IO Unit := do
  match ← tokenMetaTier? h chainId addr with
  | some stored =>
      if !(shouldReplace stored tier) then return
  | none => pure ()
  let ord ← nowOrd
  withStmt h
    ("INSERT OR REPLACE INTO token_meta " ++
     "(chain_id, addr, decimals, symbol, tier, updated_ord) VALUES (?, ?, ?, ?, ?, ?);")
    fun s => do
    sqliteBindInt64 s.ptr 1 chainId.toUInt64
    sqliteBindText s.ptr 2 (normAddr addr)
    sqliteBindInt64 s.ptr 3 decimals.toUInt64
    sqliteBindText s.ptr 4 symbol
    sqliteBindText s.ptr 5 tier.asString
    sqliteBindInt64 s.ptr 6 ord
    let _ ← sqliteStep s.ptr

def getTokenMeta (h : Handle) (chainId : Nat) (addr : String) :
    IO (Option (Nat × String × Tier)) := do
  withStmt h
    "SELECT decimals, symbol, tier FROM token_meta WHERE chain_id = ? AND addr = ?;"
    fun s => do
    sqliteBindInt64 s.ptr 1 chainId.toUInt64
    sqliteBindText s.ptr 2 (normAddr addr)
    let rc ← sqliteStep s.ptr
    if rc == stepRow then
      let d ← sqliteColumnInt64 s.ptr 0
      let sym ← sqliteColumnText s.ptr 1
      let tier ← sqliteColumnText s.ptr 2
      pure (some (d.toNat, sym, Tier.ofString tier))
    else
      pure none

/-- All token-meta rows for a chain: `(addr, decimals, symbol, tier)`. -/
def listTokenMeta (h : Handle) (chainId : Nat) :
    IO (Array (String × Nat × String × Tier)) := do
  withStmt h
    "SELECT addr, decimals, symbol, tier FROM token_meta WHERE chain_id = ? ORDER BY addr;"
    fun s => do
    sqliteBindInt64 s.ptr 1 chainId.toUInt64
    let mut out : Array (String × Nat × String × Tier) := #[]
    let mut rc ← sqliteStep s.ptr
    while rc == stepRow do
      let addr ← sqliteColumnText s.ptr 0
      let d ← sqliteColumnInt64 s.ptr 1
      let sym ← sqliteColumnText s.ptr 2
      let tier ← sqliteColumnText s.ptr 3
      out := out.push (addr, d.toNat, sym, Tier.ofString tier)
      rc ← sqliteStep s.ptr
    pure out

/-! ## Negative code cache -/

def putNoCode (h : Handle) (chainId : Nat) (addr : String) : IO Unit := do
  let ord ← nowOrd
  withStmt h
    "INSERT OR REPLACE INTO no_code (chain_id, addr, updated_ord) VALUES (?, ?, ?);"
    fun s => do
    sqliteBindInt64 s.ptr 1 chainId.toUInt64
    sqliteBindText s.ptr 2 (normAddr addr)
    sqliteBindInt64 s.ptr 3 ord
    let _ ← sqliteStep s.ptr

def isNoCode (h : Handle) (chainId : Nat) (addr : String) : IO Bool := do
  withStmt h "SELECT 1 FROM no_code WHERE chain_id = ? AND addr = ?;" fun s => do
    sqliteBindInt64 s.ptr 1 chainId.toUInt64
    sqliteBindText s.ptr 2 (normAddr addr)
    pure ((← sqliteStep s.ptr) == stepRow)

/-! ## Contract code -/

private def codeTier? (h : Handle) (chainId : Nat) (addr : String) :
    IO (Option Tier) := do
  withStmt h "SELECT tier FROM code WHERE chain_id = ? AND addr = ?;" fun s => do
    sqliteBindInt64 s.ptr 1 chainId.toUInt64
    sqliteBindText s.ptr 2 (normAddr addr)
    let rc ← sqliteStep s.ptr
    if rc == stepRow then
      pure (some (Tier.ofString (← sqliteColumnText s.ptr 0)))
    else
      pure none

/-- Insert/upgrade deployed bytecode for an address. Same no-downgrade
    rule as `putTokenMeta` (code at an address is immutable modulo
    selfdestruct/CREATE2 redeploys, which a re-read at ≥ tier refreshes). -/
def putCode (h : Handle) (chainId : Nat) (addr : String)
    (codeHex : String) (tier : Tier) : IO Unit := do
  match ← codeTier? h chainId addr with
  | some stored =>
      if !(shouldReplace stored tier) then return
  | none => pure ()
  let ord ← nowOrd
  withStmt h
    ("INSERT OR REPLACE INTO code (chain_id, addr, code_hex, tier, updated_ord) " ++
     "VALUES (?, ?, ?, ?, ?);")
    fun s => do
    sqliteBindInt64 s.ptr 1 chainId.toUInt64
    sqliteBindText s.ptr 2 (normAddr addr)
    sqliteBindText s.ptr 3 codeHex
    sqliteBindText s.ptr 4 tier.asString
    sqliteBindInt64 s.ptr 5 ord
    let _ ← sqliteStep s.ptr

def getCode (h : Handle) (chainId : Nat) (addr : String) :
    IO (Option (String × Tier)) := do
  withStmt h "SELECT code_hex, tier FROM code WHERE chain_id = ? AND addr = ?;" fun s => do
    sqliteBindInt64 s.ptr 1 chainId.toUInt64
    sqliteBindText s.ptr 2 (normAddr addr)
    let rc ← sqliteStep s.ptr
    if rc == stepRow then
      let c ← sqliteColumnText s.ptr 0
      let t ← sqliteColumnText s.ptr 1
      pure (some (c, Tier.ofString t))
    else
      pure none

/-! ## Verified headers -/

def getHeader (h : Handle) (chainId blockNumber : Nat) :
    IO (Option HeaderEntry) := do
  withStmt h
    ("SELECT block_hash, state_root, ts, tier FROM headers " ++
     "WHERE chain_id = ? AND block_number = ?;")
    fun s => do
    sqliteBindInt64 s.ptr 1 chainId.toUInt64
    sqliteBindInt64 s.ptr 2 blockNumber.toUInt64
    let rc ← sqliteStep s.ptr
    if rc == stepRow then
      let bh ← sqliteColumnText s.ptr 0
      let sr ← sqliteColumnText s.ptr 1
      let ts ← sqliteColumnInt64 s.ptr 2
      let tier ← sqliteColumnText s.ptr 3
      pure (some {
        chainId, blockNumber, blockHash := bh, stateRoot := sr,
        timestamp := ts.toNat, tier := Tier.ofString tier })
    else
      pure none

/-- Store a header pin. Block-keyed, so no overwrite ambiguity; a repeat
    write for the same block upgrades tier only (no-downgrade). -/
def putHeader (h : Handle) (e : HeaderEntry) : IO Unit := do
  let stored? ← getHeader h e.chainId e.blockNumber
  match stored? with
  | some stored =>
      if !(shouldReplace stored.tier e.tier) then return
  | none => pure ()
  let ord ← nowOrd
  withStmt h
    ("INSERT OR REPLACE INTO headers " ++
     "(chain_id, block_number, block_hash, state_root, ts, tier, updated_ord) " ++
     "VALUES (?, ?, ?, ?, ?, ?, ?);")
    fun s => do
    sqliteBindInt64 s.ptr 1 e.chainId.toUInt64
    sqliteBindInt64 s.ptr 2 e.blockNumber.toUInt64
    sqliteBindText s.ptr 3 e.blockHash
    sqliteBindText s.ptr 4 e.stateRoot
    sqliteBindInt64 s.ptr 5 e.timestamp.toUInt64
    sqliteBindText s.ptr 6 e.tier.asString
    sqliteBindInt64 s.ptr 7 ord
    let _ ← sqliteStep s.ptr

/-- Most recent stored header for a chain. -/
def latestHeader (h : Handle) (chainId : Nat) : IO (Option HeaderEntry) := do
  withStmt h
    ("SELECT block_number, block_hash, state_root, ts, tier FROM headers " ++
     "WHERE chain_id = ? ORDER BY block_number DESC LIMIT 1;")
    fun s => do
    sqliteBindInt64 s.ptr 1 chainId.toUInt64
    let rc ← sqliteStep s.ptr
    if rc == stepRow then
      let bn ← sqliteColumnInt64 s.ptr 0
      let bh ← sqliteColumnText s.ptr 1
      let sr ← sqliteColumnText s.ptr 2
      let ts ← sqliteColumnInt64 s.ptr 3
      let tier ← sqliteColumnText s.ptr 4
      pure (some {
        chainId, blockNumber := bn.toNat, blockHash := bh, stateRoot := sr,
        timestamp := ts.toNat, tier := Tier.ofString tier })
    else
      pure none

/-! ## Accounts -/

def getAccountAt (h : Handle) (chainId : Nat) (addr : String) (blockNumber : Nat) :
    IO (Option AccountEntry) := do
  withStmt h
    ("SELECT balance_hex, nonce, storage_root, code_hash, tier FROM accounts " ++
     "WHERE chain_id = ? AND addr = ? AND block_number = ?;")
    fun s => do
    sqliteBindInt64 s.ptr 1 chainId.toUInt64
    sqliteBindText s.ptr 2 (normAddr addr)
    sqliteBindInt64 s.ptr 3 blockNumber.toUInt64
    let rc ← sqliteStep s.ptr
    if rc == stepRow then
      let bal ← sqliteColumnText s.ptr 0
      let nonce ← sqliteColumnInt64 s.ptr 1
      let sr ← sqliteColumnText s.ptr 2
      let ch ← sqliteColumnText s.ptr 3
      let tier ← sqliteColumnText s.ptr 4
      pure (some {
        chainId, addr := normAddr addr, blockNumber, balanceHex := bal,
        nonce := nonce.toNat, storageRoot := sr, codeHash := ch,
        tier := Tier.ofString tier })
    else
      pure none

def putAccount (h : Handle) (e : AccountEntry) : IO Unit := do
  let stored? ← getAccountAt h e.chainId e.addr e.blockNumber
  match stored? with
  | some stored =>
      if !(shouldReplace stored.tier e.tier) then return
  | none => pure ()
  let ord ← nowOrd
  withStmt h
    ("INSERT OR REPLACE INTO accounts " ++
     "(chain_id, addr, block_number, balance_hex, nonce, storage_root, code_hash, tier, updated_ord) " ++
     "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);")
    fun s => do
    sqliteBindInt64 s.ptr 1 e.chainId.toUInt64
    sqliteBindText s.ptr 2 (normAddr e.addr)
    sqliteBindInt64 s.ptr 3 e.blockNumber.toUInt64
    sqliteBindText s.ptr 4 e.balanceHex
    sqliteBindInt64 s.ptr 5 e.nonce.toUInt64
    sqliteBindText s.ptr 6 e.storageRoot
    sqliteBindText s.ptr 7 e.codeHash
    sqliteBindText s.ptr 8 e.tier.asString
    sqliteBindInt64 s.ptr 9 ord
    let _ ← sqliteStep s.ptr

/-- Latest stored account state for an address (highest proven block). -/
def getAccountLatest (h : Handle) (chainId : Nat) (addr : String) :
    IO (Option AccountEntry) := do
  withStmt h
    ("SELECT block_number, balance_hex, nonce, storage_root, code_hash, tier FROM accounts " ++
     "WHERE chain_id = ? AND addr = ? ORDER BY block_number DESC LIMIT 1;")
    fun s => do
    sqliteBindInt64 s.ptr 1 chainId.toUInt64
    sqliteBindText s.ptr 2 (normAddr addr)
    let rc ← sqliteStep s.ptr
    if rc == stepRow then
      let bn ← sqliteColumnInt64 s.ptr 0
      let bal ← sqliteColumnText s.ptr 1
      let nonce ← sqliteColumnInt64 s.ptr 2
      let sr ← sqliteColumnText s.ptr 3
      let ch ← sqliteColumnText s.ptr 4
      let tier ← sqliteColumnText s.ptr 5
      pure (some {
        chainId, addr := normAddr addr, blockNumber := bn.toNat,
        balanceHex := bal, nonce := nonce.toNat, storageRoot := sr,
        codeHash := ch, tier := Tier.ofString tier })
    else
      pure none

/-! ## Storage slots -/

def getStorageAt (h : Handle) (chainId : Nat) (addr slot : String) (blockNumber : Nat) :
    IO (Option StorageEntry) := do
  withStmt h
    ("SELECT value_hex, tier FROM storage " ++
     "WHERE chain_id = ? AND addr = ? AND slot = ? AND block_number = ?;")
    fun s => do
    sqliteBindInt64 s.ptr 1 chainId.toUInt64
    sqliteBindText s.ptr 2 (normAddr addr)
    sqliteBindText s.ptr 3 slot.toLower
    sqliteBindInt64 s.ptr 4 blockNumber.toUInt64
    let rc ← sqliteStep s.ptr
    if rc == stepRow then
      let v ← sqliteColumnText s.ptr 0
      let tier ← sqliteColumnText s.ptr 1
      pure (some {
        chainId, addr := normAddr addr, slot := slot.toLower, blockNumber,
        valueHex := v, tier := Tier.ofString tier })
    else
      pure none

def putStorage (h : Handle) (e : StorageEntry) : IO Unit := do
  let stored? ← getStorageAt h e.chainId e.addr e.slot e.blockNumber
  match stored? with
  | some stored =>
      if !(shouldReplace stored.tier e.tier) then return
  | none => pure ()
  let ord ← nowOrd
  withStmt h
    ("INSERT OR REPLACE INTO storage " ++
     "(chain_id, addr, slot, block_number, value_hex, tier, updated_ord) " ++
     "VALUES (?, ?, ?, ?, ?, ?, ?);")
    fun s => do
    sqliteBindInt64 s.ptr 1 e.chainId.toUInt64
    sqliteBindText s.ptr 2 (normAddr e.addr)
    sqliteBindText s.ptr 3 e.slot.toLower
    sqliteBindInt64 s.ptr 4 e.blockNumber.toUInt64
    sqliteBindText s.ptr 5 e.valueHex
    sqliteBindText s.ptr 6 e.tier.asString
    sqliteBindInt64 s.ptr 7 ord
    let _ ← sqliteStep s.ptr

/-- All stored slots for an address at its latest proven block, i.e. the
    slots of the account's most recent pin. -/
def listStorageLatest (h : Handle) (chainId : Nat) (addr : String) :
    IO (Array StorageEntry) := do
  withStmt h
    ("SELECT slot, block_number, value_hex, tier FROM storage " ++
     "WHERE chain_id = ? AND addr = ? AND block_number = " ++
     "(SELECT MAX(block_number) FROM storage WHERE chain_id = ? AND addr = ?) " ++
     "ORDER BY slot;")
    fun s => do
    sqliteBindInt64 s.ptr 1 chainId.toUInt64
    sqliteBindText s.ptr 2 (normAddr addr)
    sqliteBindInt64 s.ptr 3 chainId.toUInt64
    sqliteBindText s.ptr 4 (normAddr addr)
    let mut out : Array StorageEntry := #[]
    let mut rc ← sqliteStep s.ptr
    while rc == stepRow do
      let slot ← sqliteColumnText s.ptr 0
      let bn ← sqliteColumnInt64 s.ptr 1
      let v ← sqliteColumnText s.ptr 2
      let tier ← sqliteColumnText s.ptr 3
      out := out.push {
        chainId, addr := normAddr addr, slot, blockNumber := bn.toNat,
        valueHex := v, tier := Tier.ofString tier }
      rc ← sqliteStep s.ptr
    pure out

/-! ## Status -/

private def countTable (h : Handle) (table : String) : IO Nat := do
  -- `table` comes from the fixed list in `status` below, never user input.
  withStmt h s!"SELECT COUNT(*) FROM {table};" fun s => do
    let rc ← sqliteStep s.ptr
    if rc == stepRow then
      pure (← sqliteColumnInt64 s.ptr 0).toNat
    else
      pure 0

/-- Row counts per table, for `vault.status`. -/
def status (h : Handle) : IO (Array (String × Nat)) := do
  let tables := #["token_meta", "no_code", "code", "headers", "accounts", "storage"]
  let mut out : Array (String × Nat) := #[]
  for t in tables do
    out := out.push (t, ← countTable h t)
  pure out

end LeanCli.Daemon.StateVault
