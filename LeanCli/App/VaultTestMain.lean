import LeanCli.Daemon.StateVault
import LeanCli.Encoding.Rlp
import LeanCli.Ethereum.Mpt

/-!
# StateVault + MPT smoke test (`vault_test`)

Three sections, exits non-zero on any regression:

1. **SQLite roundtrip** — schema bootstrap on a temp DB, token-meta
   put/get including the tier no-downgrade rule, negative code cache,
   header/account/storage rows keyed by block, status counts.
2. **RLP decoder** — encode→decode roundtrips plus canonicality
   rejections (non-minimal single byte, short-form-required lengths).
3. **MPT verifier** — self-consistent fixtures built in-process: a
   single-leaf trie, a branch+leaf two-node path, an exclusion proof,
   and a wrong-root rejection. Node hashes come from the
   `leancli-hacl-keccak256` helper; when the helper is absent (tree
   without `lake script run setup-helpers`) this section SKIPs rather
   than fails, mirroring the daemon's boot precheck posture.

Run: `lake build vault_test && .lake/build/bin/vault_test`
(`ops/tests/vault_smoke.sh` wraps this.)
-/

open LeanCli.Daemon.StateVault
open LeanCli.Encoding.Rlp
open LeanCli.Ethereum.Mpt

def check (name : String) (cond : Bool) : IO Nat := do
  if cond then
    IO.println s!"  ok   {name}"
    pure 0
  else
    IO.println s!"  FAIL {name}"
    pure 1

def bytesOf (l : List Nat) : ByteArray :=
  ByteArray.mk (l.map (fun n => UInt8.ofNat n)).toArray

def bytesEqT (a b : ByteArray) : Bool :=
  a.size == b.size && (List.range a.size).all (fun i => a.get! i == b.get! i)

/-! ## Section 1: SQLite roundtrip -/

def sqliteSection : IO Nat := do
  IO.println "statevault sqlite:"
  let path := s!"/tmp/leancli-vault-test-{← IO.monoMsNow}.db"
  let h ← openDb path
  let mut fails := 0
  -- token meta: insert at rpc tier, read back
  putTokenMeta h 1 "0xAbCd000000000000000000000000000000000001" 6 "USDC" .rpcUnverified
  let got ← getTokenMeta h 1 "0xabcd000000000000000000000000000000000001"
  fails := fails + (← check "token meta roundtrip (case-insensitive key)"
    (got == some (6, "USDC", .rpcUnverified)))
  -- upgrade to consensus is allowed
  putTokenMeta h 1 "0xabcd000000000000000000000000000000000001" 6 "USDC" .consensusVerified
  let got2 ← getTokenMeta h 1 "0xabcd000000000000000000000000000000000001"
  fails := fails + (← check "tier upgrade recorded"
    (got2 == some (6, "USDC", .consensusVerified)))
  -- downgrade attempt must be a no-op
  putTokenMeta h 1 "0xabcd000000000000000000000000000000000001" 18 "FAKE" .rpcUnverified
  let got3 ← getTokenMeta h 1 "0xabcd000000000000000000000000000000000001"
  fails := fails + (← check "no-downgrade overwrite refused"
    (got3 == some (6, "USDC", .consensusVerified)))
  -- negative cache
  putNoCode h 1 "0x00000000000000000000000000000000000000EE"
  fails := fails + (← check "no_code hit"
    (← isNoCode h 1 "0x00000000000000000000000000000000000000ee"))
  fails := fails + (← check "no_code miss"
    (!(← isNoCode h 1 "0x00000000000000000000000000000000000000ef")))
  -- headers
  putHeader h { chainId := 1, blockNumber := 100, blockHash := "0xaa",
                stateRoot := "0xbb", timestamp := 1700000000,
                tier := .consensusVerified }
  putHeader h { chainId := 1, blockNumber := 101, blockHash := "0xcc",
                stateRoot := "0xdd", timestamp := 1700000012,
                tier := .consensusVerified }
  let latest ← latestHeader h 1
  fails := fails + (← check "latest header wins"
    (latest.map (fun e => (e.blockNumber, e.stateRoot)) == some (101, "0xdd")))
  -- accounts, block-keyed
  putAccount h { chainId := 1, addr := "0x1111111111111111111111111111111111111111",
                 blockNumber := 100, balanceHex := "0x64", nonce := 5,
                 storageRoot := "0x" ++ emptyTrieRootHex,
                 codeHash := "0x" ++ emptyCodeHashHex, tier := .leanProven }
  putAccount h { chainId := 1, addr := "0x1111111111111111111111111111111111111111",
                 blockNumber := 101, balanceHex := "0x65", nonce := 6,
                 storageRoot := "0x" ++ emptyTrieRootHex,
                 codeHash := "0x" ++ emptyCodeHashHex, tier := .leanProven }
  let acct ← getAccountLatest h 1 "0x1111111111111111111111111111111111111111"
  fails := fails + (← check "account latest block served"
    (acct.map (fun e => (e.blockNumber, e.balanceHex, e.nonce)) == some (101, "0x65", 6)))
  -- storage
  putStorage h { chainId := 1, addr := "0x1111111111111111111111111111111111111111",
                 slot := "0x0", blockNumber := 101, valueHex := "0x2a",
                 tier := .leanProven }
  let slot ← getStorageAt h 1 "0x1111111111111111111111111111111111111111" "0x0" 101
  fails := fails + (← check "storage slot roundtrip"
    (slot.map (fun e => e.valueHex) == some "0x2a"))
  -- counts
  let counts ← status h
  let countOf (t : String) : Nat :=
    ((counts.toList.find? (fun (k, _) => k == t)).map Prod.snd).getD 0
  fails := fails + (← check "status counts"
    (countOf "headers" == 2 && countOf "accounts" == 2 && countOf "storage" == 1))
  close h
  IO.FS.removeFile path
  pure fails

/-! ## Section 2: RLP decoder -/

def rlpRoundtrip (item : Item) : Bool :=
  match LeanCli.Encoding.Rlp.decode (encode item) with
  | some back => bytesEqT (encode back) (encode item)
  | none => false

def rlpSection : IO Nat := do
  IO.println "rlp decoder:"
  let mut fails := 0
  fails := fails + (← check "single byte" (rlpRoundtrip (.bytes (bytesOf [0x05]))))
  fails := fails + (← check "empty string" (rlpRoundtrip (.bytes ByteArray.empty)))
  fails := fails + (← check "short string" (rlpRoundtrip (.bytes (bytesOf [1,2,3,4,5]))))
  fails := fails + (← check "long string (60 bytes)"
    (rlpRoundtrip (.bytes (bytesOf ((List.range 60).map (· % 256))))))
  fails := fails + (← check "empty list" (rlpRoundtrip (.list [])))
  fails := fails + (← check "nested list"
    (rlpRoundtrip (.list [.bytes (bytesOf [0x2a]), .list [.bytes ByteArray.empty],
                          .bytes (bytesOf [1,2,3])])))
  fails := fails + (← check "17-element branch shape"
    (rlpRoundtrip (.list ((List.range 16).map (fun _ => Item.bytes ByteArray.empty)
      ++ [.bytes (bytesOf [9])]))))
  -- canonicality rejections
  fails := fails + (← check "non-minimal single byte rejected"
    ((LeanCli.Encoding.Rlp.decode (bytesOf [0x81, 0x05])).isNone))
  fails := fails + (← check "trailing garbage rejected"
    ((LeanCli.Encoding.Rlp.decode (bytesOf [0x01, 0x02])).isNone))
  fails := fails + (← check "long form for short payload rejected"
    ((LeanCli.Encoding.Rlp.decode (bytesOf [0xb8, 0x01, 0x99])).isNone))
  pure fails

/-! ## Section 3: MPT verifier -/

def nibblesToBytes (nibs : List Nat) : ByteArray :=
  match nibs with
  | hi :: lo :: rest => (bytesOf [hi * 16 + lo]) ++ nibblesToBytes rest
  | _ => ByteArray.empty

/-- Hex-prefix ENCODE (test-side inverse of `hpDecode`). -/
def hpEncode (isLeaf : Bool) (nibs : List Nat) : ByteArray :=
  let flagBase := if isLeaf then 2 else 0
  if nibs.length % 2 == 0 then
    bytesOf [flagBase * 16] ++ nibblesToBytes nibs
  else
    match nibs with
    | n :: rest => bytesOf [(flagBase + 1) * 16 + n] ++ nibblesToBytes rest
    | [] => bytesOf [flagBase * 16]

def mptSection : IO Nat := do
  IO.println "mpt verifier:"
  -- Key material: any fixed 32-byte "hashed key" works — `verify` takes
  -- the key hash directly, so the fixtures need keccak only for NODES.
  let keyHash := bytesOf ((List.range 32).map (fun i => (i * 7 + 3) % 256))
  let value := bytesOf [0xde, 0xad, 0xbe, 0xef]
  -- Probe the keccak helper; skip the section if this tree has no
  -- native helpers built (same posture as the daemon boot precheck).
  match ← keccakIO (bytesOf [0x80]) with
  | .error e =>
      IO.println s!"  SKIP mpt fixtures (keccak helper unavailable: {e})"
      pure 0
  | .ok emptyRootProbe =>
      let mut fails := 0
      fails := fails + (← check "keccak(0x80) is the canonical empty trie root"
        (bytesEqT emptyRootProbe emptyTrieRoot))
      let path := nibblesOf keyHash
      -- (a) single-leaf trie: leaf holds the full 64-nibble path
      let leafFull : Item := .list [.bytes (hpEncode true path), .bytes value]
      let leafFullBytes := encode leafFull
      match ← keccakIO leafFullBytes with
      | .error e =>
          IO.println s!"  FAIL keccak on leaf: {e}"
          pure (fails + 1)
      | .ok leafFullHash =>
          fails := fails + (← check "single-leaf inclusion"
            (match verify leafFullHash keyHash [(leafFullBytes, leafFullHash)] with
             | .ok (some v) => bytesEqT v value
             | _ => false))
          -- (b) branch + leaf: branch at nibble path.head, leaf holds the tail
          let leafTail : Item := .list [.bytes (hpEncode true (path.drop 1)), .bytes value]
          let leafTailBytes := encode leafTail
          match ← keccakIO leafTailBytes with
          | .error e =>
              IO.println s!"  FAIL keccak on tail leaf: {e}"
              pure (fails + 1)
          | .ok leafTailHash =>
              let firstNib := (path.head? ).getD 0
              let branchItems : List Item :=
                (List.range 16).map (fun i =>
                  if i == firstNib then Item.bytes leafTailHash
                  else Item.bytes ByteArray.empty)
                ++ [Item.bytes ByteArray.empty]
              let branch : Item := .list branchItems
              let branchBytes := encode branch
              match ← keccakIO branchBytes with
              | .error e =>
                  IO.println s!"  FAIL keccak on branch: {e}"
                  pure (fails + 1)
              | .ok branchHash =>
                  let proof := [(branchBytes, branchHash), (leafTailBytes, leafTailHash)]
                  fails := fails + (← check "branch→leaf inclusion"
                    (match verify branchHash keyHash proof with
                     | .ok (some v) => bytesEqT v value
                     | _ => false))
                  -- (c) exclusion: a key whose first nibble hits an empty slot
                  let otherFirst := (firstNib + 1) % 16
                  let keyHash2 := bytesOf ([otherFirst * 16] ++
                    ((List.range 31).map (fun i => (i * 5 + 1) % 256)))
                  fails := fails + (← check "exclusion via empty branch slot"
                    (match verify branchHash keyHash2 [(branchBytes, branchHash)] with
                     | .ok none => true
                     | _ => false))
                  -- (d) wrong root must not verify
                  let wrongRoot := bytesOf ((List.range 32).map (fun _ => 0x42))
                  fails := fails + (← check "wrong root rejected"
                    (match verify wrongRoot keyHash proof with
                     | .error _ => true
                     | _ => false))
                  -- (e) empty trie root proves absence with an empty proof
                  fails := fails + (← check "empty trie exclusion"
                    (match verify emptyTrieRoot keyHash [] with
                     | .ok none => true
                     | _ => false))
                  pure fails

def main : IO UInt32 := do
  let f1 ← sqliteSection
  let f2 ← rlpSection
  let f3 ← mptSection
  let total := f1 + f2 + f3
  if total == 0 then
    IO.println "vault_test: all checks passed"
    pure 0
  else
    IO.println s!"vault_test: {total} check(s) FAILED"
    pure 1
