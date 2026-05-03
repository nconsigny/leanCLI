import LeanKohaku.Crypto.Hacl
import LeanKohaku.Crypto.Hex
import LeanKohaku.Ethereum.Address
import LeanKohaku.Invariants.Ens
import LeanKohaku.Privacy.NetworkPolicy
import LeanKohaku.RPC.Outbound

/-!
# ENS name resolution (ASCII-only)

Computes EIP-137 namehash via `keccak256` and resolves via the canonical
ENS Registry + resolver.

ASCII-only: callers must reject non-ASCII names before calling. The
`LeanKohaku.Invariants.Ens.normalizeLabels` helper enforces this.
-/

namespace LeanKohaku.Ethereum.Ens

open LeanKohaku.Encoding.Json
open LeanKohaku.Privacy.NetworkPolicy

/-- 32 zero bytes — the namehash of the empty name. -/
def emptyNode : ByteArray :=
  (List.range 32).foldl (init := ByteArray.empty) (fun acc _ => acc.push 0)

private def stripHexPrefix (s : String) : String :=
  if s.startsWith "0x" || s.startsWith "0X" then (s.drop 2).toString else s

private def hexNoPrefix (bytes : ByteArray) : String :=
  stripHexPrefix (LeanKohaku.Crypto.Hex.encode bytes)

/-- Compute keccak256 of the concatenation of two byte arrays, given as
    no-prefix hex. Returns the raw 32-byte digest. -/
private def keccakConcatIO (a b : ByteArray) : IO (Except String ByteArray) := do
  let inputHex := hexNoPrefix a ++ hexNoPrefix b
  LeanKohaku.Crypto.Hacl.keccak256EthereumIO inputHex

/-- keccak256 of the UTF-8 (ASCII here) bytes of a label. -/
private def labelHashIO (label : String) : IO (Except String ByteArray) :=
  LeanKohaku.Crypto.Hacl.keccak256EthereumIO (hexNoPrefix label.toUTF8)

/-- Recursive namehash: `namehash(parent.label) = keccak(namehash(parent) || keccak(label))`.
    Caller must pass labels in **left-to-right** order; we fold from the right
    so the rightmost (TLD) label is mixed first. -/
def namehashIO (name : String) : IO (Except String ByteArray) := do
  match LeanKohaku.Invariants.Ens.normalizeLabels name with
  | none => pure (.error s!"invalid ENS name (ASCII-only, no empty labels): {name}")
  | some labels =>
      -- Fold right-to-left: start with empty node, mix each label.
      let rec go (lbls : List String) (acc : ByteArray) :
          IO (Except String ByteArray) := do
        match lbls with
        | [] => pure (.ok acc)
        | lbl :: rest =>
            match ← go rest acc with
            | .error e => pure (.error e)
            | .ok parent =>
                match ← labelHashIO lbl with
                | .error e => pure (.error e)
                | .ok lh => keccakConcatIO parent lh
      go labels emptyNode

/-- Mainnet ENS Registry address. -/
def mainnetRegistry : String := "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e"
/-- Sepolia ENS Registry address (deployed by the ENS team). -/
def sepoliaRegistry : String := "0x0635513f179D50A207757E05759CbD106d7dFcE8"

/-- Pick the ENS Registry address for a chain id, or `none` if unsupported. -/
def registryFor (chainId : Nat) : Option String :=
  match chainId with
  | 1 => some mainnetRegistry
  | 11155111 => some sepoliaRegistry
  | _ => none

/-- Encode a 36-byte calldata buffer for a `(bytes32 node)` selector. -/
private def selectorPlusNode (selector4 : String) (node : ByteArray) : String :=
  "0x" ++ selector4 ++ hexNoPrefix node

/-- `resolver(bytes32)` selector. -/
def resolverSelector : String := "0178b8bf"
/-- `addr(bytes32)` selector. -/
def addrSelector : String := "3b3b57de"

private def zeroAddressHex : String :=
  "0x" ++ String.mk (List.replicate 40 '0')

/-- Parse a 32-byte ABI word (right-aligned address) into a 20-byte address hex
    string with `0x` prefix and lowercase hex. Returns `none` for malformed
    input. -/
def parseAddressWord (hex : String) : Option String := do
  let bytes ← LeanKohaku.Crypto.Hex.decode hex
  if bytes.size = 32 then
    -- Why: ABI right-aligns addresses; take last 20 bytes.
    let body := (List.range 20).foldl
      (init := ByteArray.empty)
      (fun acc i => acc.push bytes[12 + i]!)
    some (LeanKohaku.Crypto.Hex.encode body)
  else
    none

/-- Result of a successful ENS resolution. -/
structure Resolved where
  name      : String
  address   : String  -- EIP-55 checksum hex
  chainId   : Nat
  resolver  : String  -- lowercase hex of the resolver contract
  deriving Repr

/-- Resolve an ENS name to an address.
    Returns one of:
      - `.ok r` on success.
      - `.error (code, msg)` where code is the JSON-RPC error code to surface. -/
def resolveIO (policy : Policy) (endpoint : LeanKohaku.RPC.Outbound.Endpoint)
    (chainId : Nat) (name : String) : IO (Except (Int × String) Resolved) := do
  match registryFor chainId with
  | none => pure (.error (-32027, s!"ENS not configured for chainId {chainId}"))
  | some registry =>
      match ← namehashIO name with
      | .error e => pure (.error (-32602, e))
      | .ok node =>
          let resolverData := selectorPlusNode resolverSelector node
          match ← LeanKohaku.RPC.Outbound.ethCall policy endpoint registry resolverData with
          | .error e => pure (.error (-32020, s!"resolver lookup failed: {e}"))
          | .ok rJson =>
              match asString rJson with
              | none => pure (.error (-32020, "resolver lookup returned non-hex"))
              | some rHex =>
                  match parseAddressWord rHex with
                  | none => pure (.error (-32020, s!"malformed resolver word: {rHex}"))
                  | some resolverAddr =>
                      if resolverAddr = zeroAddressHex then
                        pure (.error (-32028, s!"no resolver set for {name}"))
                      else
                        let addrData := selectorPlusNode addrSelector node
                        match ← LeanKohaku.RPC.Outbound.ethCall policy endpoint resolverAddr addrData with
                        | .error e => pure (.error (-32020, s!"addr() lookup failed: {e}"))
                        | .ok aJson =>
                            match asString aJson with
                            | none => pure (.error (-32020, "addr() returned non-hex"))
                            | some aHex =>
                                match parseAddressWord aHex with
                                | none => pure (.error (-32020, s!"malformed addr word: {aHex}"))
                                | some addrLower =>
                                    if addrLower = zeroAddressHex then
                                      pure (.error (-32029, s!"{name} resolved to zero address"))
                                    else
                                      match LeanKohaku.Ethereum.Address.fromHex addrLower with
                                      | none => pure (.error (-32020, s!"resolved address is malformed: {addrLower}"))
                                      | some address =>
                                          match ← LeanKohaku.Ethereum.Address.toChecksumIO address with
                                          | .error e => pure (.error (-32020, s!"checksum failed: {e}"))
                                          | .ok checksum =>
                                              pure (.ok {
                                                name := name,
                                                address := checksum,
                                                chainId := chainId,
                                                resolver := resolverAddr
                                              })

end LeanKohaku.Ethereum.Ens
