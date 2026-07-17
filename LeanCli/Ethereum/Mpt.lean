import LeanCli.Encoding.Rlp
import LeanCli.Crypto.Hex
import LeanCli.Crypto.Hacl

/-!
# Merkle-Patricia trie proof verification

Lean-side verification of `eth_getProof` account and storage proofs
against a trusted state root. This is what upgrades the wallet's
StateVault from "the light client said so" (`consensusVerified`) to
"Lean checked the Merkle proof itself" (`leanProven`): helios supplies
only the sync-committee-verified state root; any untrusted RPC supplies
the proof nodes; this module walks the trie and accepts or rejects.
A lying server can only cause a verification failure — never a wrong
value.

Structure of a proof: an ordered list of RLP-encoded trie nodes from the
root down. Each node is referenced by its keccak-256 hash (or embedded
inline when its encoding is < 32 bytes). The walk starts at the trusted
root hash, decodes the node whose keccak matches, and descends by the
nibbles of `keccak(key)` until it lands on the value (inclusion) or on a
provably empty branch/diverging leaf (exclusion).

The core verifier is PURE: it consumes `(nodeBytes, nodeHash)` pairs and
never computes a hash itself. The `*IO` wrappers compute keccak-256
through the native HACL helper (`leancli-hacl-keccak256`) — the same
Category-13 axiomatized-crypto boundary as every other hash in the
wallet — then run the pure walk. Invariant Cat 16 states the soundness
obligation (`📝 16.4`): acceptance implies the key/value pair is bound
to the root under standard keccak collision-resistance.
-/

namespace LeanCli.Ethereum.Mpt

open LeanCli.Encoding.Rlp
open LeanCli.Crypto

/-- keccak256 of the RLP empty string (`0x80`) — the root of an empty
    trie. An account missing from an empty (sub)trie is proven absent
    with an empty proof list. -/
def emptyTrieRootHex : String :=
  "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421"

def emptyTrieRoot : ByteArray :=
  (Hex.decode emptyTrieRootHex).getD ByteArray.empty

/-- keccak256 of the empty byte string — `codeHash` of a codeless
    account (EOA). -/
def emptyCodeHashHex : String :=
  "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"

private def bytesEq (a b : ByteArray) : Bool :=
  a.size == b.size &&
    (List.range a.size).all (fun i => a.get! i == b.get! i)

/-- Split a byte array into its nibble path (two nibbles per byte,
    high first). An account key is `keccak(address)` → 64 nibbles. -/
def nibblesOf (b : ByteArray) : List Nat :=
  b.foldl (init := []) (fun acc byte =>
    acc ++ [byte.toNat / 16, byte.toNat % 16])

/-- Hex-prefix decoding (Yellow Paper appendix C): unpack a leaf /
    extension node's compact path into `(isLeaf, nibbles)`. -/
def hpDecode (b : ByteArray) : Option (Bool × List Nat) :=
  match nibblesOf b with
  | [] => none
  | flag :: rest =>
      -- Even-path forms (flags 0/2) carry a zero padding nibble after
      -- the flag; odd-path forms (flags 1/3) start the path immediately.
      match flag with
      | 0 => match rest with
             | 0 :: tail => some (false, tail)
             | _ => none
      | 1 => some (false, rest)
      | 2 => match rest with
             | 0 :: tail => some (true, tail)
             | _ => none
      | 3 => some (true, rest)
      | _ => none

/-- One proof node: its raw RLP encoding and its keccak-256 hash. The
    hash is supplied by the IO wrapper — the pure walk only compares. -/
abbrev HashedNode := ByteArray × ByteArray

private def findNode (proof : List HashedNode) (want : ByteArray) :
    Option ByteArray :=
  (proof.find? (fun (_, h) => bytesEq h want)).map Prod.fst

private def isPrefixOf (pre path : List Nat) : Bool :=
  match pre, path with
  | [], _ => true
  | _, [] => false
  | p :: ps, q :: qs => p == q && isPrefixOf ps qs

/-- Result of a verified walk: `some value` = inclusion proven (the raw
    value bytes stored at the key), `none` = exclusion proven (the key is
    bound to nothing under this root). -/
abbrev WalkResult := Option ByteArray

mutual
  /-- Descend one decoded node. -/
  private def walkItem (fuel : Nat) (proof : List HashedNode)
      (item : Item) (path : List Nat) : Except String WalkResult :=
    match fuel with
    | 0 => .error "mpt: fuel exhausted (malformed proof)"
    | fuel + 1 =>
        match item with
        | .list [ .bytes hp, valueOrChild ] =>
            -- Leaf or extension node.
            match hpDecode hp with
            | none => .error "mpt: bad hex-prefix encoding"
            | some (isLeaf, nodePath) =>
                if isLeaf then
                  if nodePath == path then
                    match valueOrChild with
                    | .bytes v => .ok (some v)
                    | _ => .error "mpt: leaf value is not a byte string"
                  else
                    -- A leaf for a DIFFERENT key where ours would live:
                    -- proves our key absent.
                    .ok none
                else
                  if isPrefixOf nodePath path then
                    descend fuel proof valueOrChild (path.drop nodePath.length)
                  else
                    -- Extension diverges from our path: key absent.
                    .ok none
        | .list items =>
            if items.length == 17 then
              -- Branch node.
              match path with
              | [] =>
                  match items[16]? with
                  | some (Item.bytes v) =>
                      if v.size == 0 then .ok none else .ok (some v)
                  | _ => .error "mpt: branch value slot malformed"
              | nib :: rest =>
                  if nib < 16 then
                    match items[nib]? with
                    | some child => descend fuel proof child rest
                    | none => .error "mpt: branch child missing"
                  else
                    .error "mpt: nibble out of range"
            else
              .error s!"mpt: node arity {items.length} (expected 2 or 17)"
        | .bytes _ => .error "mpt: unexpected byte-string node"

  /-- Follow a child reference: empty (absent), 32-byte hash (resolve in
      the proof list), or inline node (encoding < 32 bytes, embedded). -/
  private def descend (fuel : Nat) (proof : List HashedNode)
      (child : Item) (path : List Nat) : Except String WalkResult :=
    match fuel with
    | 0 => .error "mpt: fuel exhausted (malformed proof)"
    | fuel + 1 =>
        match child with
        | .bytes h =>
            if h.size == 0 then
              -- Empty child slot: key absent.
              .ok none
            else if h.size == 32 then
              match findNode proof h with
              | some nodeBytes =>
                  match LeanCli.Encoding.Rlp.decode nodeBytes with
                  | some item => walkItem fuel proof item path
                  | none => .error "mpt: proof node is not valid RLP"
              | none => .error "mpt: proof missing node for hash reference"
            else
              .error "mpt: child reference is neither empty, hash, nor inline"
        | .list _ => walkItem fuel proof child path
end

/-- Verify a Merkle-Patricia proof (PURE core). `root` is the trusted
    32-byte root; `keyHash` the trie key, already keccak-hashed by the
    caller (account: `keccak(address)`; storage: `keccak(slot32)`);
    `proof` the RLP nodes each paired with its keccak hash.

    Returns `.ok (some value)` on proven inclusion, `.ok none` on proven
    exclusion, `.error` when the proof does not connect `root` to a
    verdict (missing node, hash mismatch, malformed RLP). An error means
    NOTHING was proven — callers must treat it exactly like a failed
    network read, never as absence. -/
def verify (root keyHash : ByteArray) (proof : List HashedNode) :
    Except String WalkResult :=
  if bytesEq root emptyTrieRoot then
    .ok none
  else
    let fuel := proof.length * 20 + keyHash.size * 2 + 2
    descend fuel proof (.bytes root) (nibblesOf keyHash)

/-! ## Account / storage payloads -/

/-- Big-endian Nat of a byte string (RLP integer convention). -/
def natOfBytes (b : ByteArray) : Nat :=
  b.foldl (init := 0) (fun acc byte => acc * 256 + byte.toNat)

/-- Decoded account leaf: `RLP([nonce, balance, storageRoot, codeHash])`. -/
structure AccountState where
  nonce       : Nat
  balance     : Nat
  storageRoot : ByteArray
  codeHash    : ByteArray
  deriving Inhabited

def parseAccount (b : ByteArray) : Option AccountState :=
  match LeanCli.Encoding.Rlp.decode b with
  | some (.list [ .bytes n, .bytes bal, .bytes sr, .bytes ch ]) =>
      if sr.size == 32 && ch.size == 32 then
        some { nonce := natOfBytes n, balance := natOfBytes bal,
               storageRoot := sr, codeHash := ch }
      else none
  | _ => none

/-- Verify an account proof against `stateRoot`. `keyHash` is
    `keccak(address)`. `.ok none` = account proven absent. -/
def verifyAccount (stateRoot keyHash : ByteArray) (proof : List HashedNode) :
    Except String (Option AccountState) := do
  match ← verify stateRoot keyHash proof with
  | none => .ok none
  | some v =>
      match parseAccount v with
      | some acct => .ok (some acct)
      | none => .error "mpt: account leaf failed RLP decode"

/-- Verify a storage-slot proof against an account's `storageRoot`.
    `keyHash` is `keccak(slot32)`. The stored value is itself
    RLP-encoded. `.ok none` = slot proven absent (reads as zero). -/
def verifyStorage (storageRoot keyHash : ByteArray) (proof : List HashedNode) :
    Except String (Option Nat) := do
  match ← verify storageRoot keyHash proof with
  | none => .ok none
  | some v =>
      match LeanCli.Encoding.Rlp.decode v with
      | some (.bytes raw) => .ok (some (natOfBytes raw))
      | _ => .error "mpt: storage value failed RLP decode"

/-! ## IO wrappers (keccak via the native HACL helper) -/

/-- keccak-256 of raw bytes through the `leancli-hacl-keccak256` helper.
    Same trust boundary as every other hash in the wallet (Cat 13). -/
def keccakIO (b : ByteArray) : IO (Except String ByteArray) :=
  Hacl.keccak256EthereumIO (Hex.encode b)

private def hashNodes (nodes : List ByteArray) :
    IO (Except String (List HashedNode)) := do
  let mut out : List HashedNode := []
  for n in nodes do
    match ← keccakIO n with
    | .ok h => out := out ++ [(n, h)]
    | .error e => return .error s!"mpt: keccak helper failed: {e}"
  pure (.ok out)

/-- Hash the proof nodes + the 20-byte address, then run the pure
    account verification. -/
def verifyAccountProofIO (stateRoot : ByteArray) (address20 : ByteArray)
    (proofNodes : List ByteArray) :
    IO (Except String (Option AccountState)) := do
  match ← keccakIO address20 with
  | .error e => pure (.error s!"mpt: keccak helper failed: {e}")
  | .ok keyHash =>
      match ← hashNodes proofNodes with
      | .error e => pure (.error e)
      | .ok hashed => pure (verifyAccount stateRoot keyHash hashed)

/-- Hash the proof nodes + the 32-byte padded slot key, then run the
    pure storage verification. -/
def verifyStorageProofIO (storageRoot : ByteArray) (slot32 : ByteArray)
    (proofNodes : List ByteArray) :
    IO (Except String (Option Nat)) := do
  match ← keccakIO slot32 with
  | .error e => pure (.error s!"mpt: keccak helper failed: {e}")
  | .ok keyHash =>
      match ← hashNodes proofNodes with
      | .error e => pure (.error e)
      | .ok hashed => pure (verifyStorage storageRoot keyHash hashed)

end LeanCli.Ethereum.Mpt
