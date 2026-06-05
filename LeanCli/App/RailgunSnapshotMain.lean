import LeanCli.Privacy.Bridge
import LeanCli.Encoding.Json
import LeanCli.Util.DotEnv

/-!
# Railgun cold-start snapshot generator

Builds `sidecars/kohaku/railgun-sepolia-snapshot.json` — a pre-synced
`@kohaku-eth/railgun` plugin storage file that the bridge cold-start
hook in `sidecars/kohaku/bridge.mjs` copies into a user's storage path on
first call. Lets users skip the multi-minute sync from the Railgun
smart-wallet deployment block on Sepolia.

How it works:

  1. Resolve the Sepolia RPC URL from env (`SEPOLIA_RPC_URL`, loaded
     from `.env` by `DotEnv.autoload`).
  2. Spawn the leancli bridge with `shielded.railgun.balance` against
     a temp storage path, using a deterministic dummy seed.
  3. The SDK runs the indexer's full sync (Subsquid + RPC fallback)
     and the `fileStorage` adapter flushes the resulting chain-wide
     state to the temp file on every `set()`.
  4. Move the temp file to `sidecars/kohaku/railgun-sepolia-snapshot.json`.

The snapshot contains only chain-wide indexer state (UTXO commitments,
merkle tree, POI metadata) — no per-user keys. alpha-21 derives
signers from `host.keystore` on every plugin construction, so the
snapshot is keystore-agnostic.

Run as a one-shot dev tool when refreshing the snapshot for a release:

  lake build leancli-railgun-snapshot
  lake env .lake/build/bin/leancli-railgun-snapshot
-/

/-- 64 bytes of `0x00` — a valid but predictable BIP-39 master seed.
    Railgun derives signing keys at hardened BIP-32 paths from this;
    the resulting keys are predictable but never persisted (alpha-21
    stores only chain-wide indexer state). Using a fixed dummy seed
    makes the snapshot generation reproducible. -/
def deterministicSeedHex : String :=
  "0x" ++ String.ofList (List.replicate 128 '0')

private def tmpStorageDir : System.FilePath := "/tmp/leancli-railgun-snapshot"

private def snapshotOutPath : System.FilePath := "sidecars" / "kohaku" / "railgun-sepolia-snapshot.json"

private def die {α : Type} (msg : String) : IO α := do
  IO.eprintln msg
  IO.Process.exit 1

def main (_args : List String) : IO UInt32 := do
  LeanCli.Util.DotEnv.autoload

  let rpcUrl ← match ← IO.getEnv "SEPOLIA_RPC_URL" with
    | some u =>
        let trimmed := u.trimAscii.toString
        if trimmed.isEmpty then die "SEPOLIA_RPC_URL is empty"
        else pure trimmed
    | none   => die "SEPOLIA_RPC_URL not set — export it or add to .env"

  IO.FS.createDirAll tmpStorageDir
  let storagePath := (tmpStorageDir / "storage.json").toString

  -- Wipe any stale state so we generate a fresh snapshot rather than
  -- re-emitting whatever was left behind from a previous run.
  try IO.FS.removeFile storagePath catch _ => pure ()

  let env : Array (String × Option String) := #[
    ("LEANCLI_RPC_URL", some rpcUrl),
    ("LEANCLI_CHAIN_ID", some "11155111"),
    ("LEANCLI_RG_SEED_HEX", some deterministicSeedHex),
    ("LEANCLI_RG_STORAGE_PATH", some storagePath),
    -- Disable the cold-start seed-from-bundle so we generate a fresh
    -- snapshot via real sync, not a copy of any existing bundle.
    ("LEANCLI_RG_SNAPSHOT_DISABLE", some "1")
  ]

  IO.println s!"[railgun-snapshot] generating {snapshotOutPath.toString}"
  IO.println s!"[railgun-snapshot]   rpc:      {rpcUrl}"
  IO.println s!"[railgun-snapshot]   storage:  {storagePath}"
  IO.println s!"[railgun-snapshot] spawning bridge (full Subsquid sync; may take minutes)…"

  let req : LeanCli.Privacy.Bridge.Request :=
    { method := "shielded.railgun.balance", params := .obj #[], id := 0 }
  let resp ← LeanCli.Privacy.Bridge.callWithEnv req env

  match resp with
  | .ok _ =>
      if !(← System.FilePath.pathExists (System.FilePath.mk storagePath)) then
        die s!"bridge returned ok but storage file {storagePath} was not created"
      let bytes ← IO.FS.readBinFile storagePath
      match snapshotOutPath.parent with
      | some p => IO.FS.createDirAll p
      | none   => pure ()
      IO.FS.writeBinFile snapshotOutPath bytes
      IO.println s!"[railgun-snapshot] wrote {snapshotOutPath.toString} ({bytes.size} bytes)"
      IO.println "[railgun-snapshot] done — commit and ship."
      pure 0
  | .err code msg data =>
      IO.eprintln s!"[railgun-snapshot] bridge error {code}: {msg}"
      match data with
      | some d => IO.eprintln s!"[railgun-snapshot]   data: {repr d}"
      | none   => pure ()
      pure 1
  | .crash stderr exit =>
      IO.eprintln s!"[railgun-snapshot] bridge crashed (exit {exit}):"
      IO.eprintln stderr
      pure 1
