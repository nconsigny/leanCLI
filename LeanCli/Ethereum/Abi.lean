import LeanCli.Crypto.Hex
import LeanCli.Encoding.Rlp

/-!
# Small ABI helpers

Only the ERC-20 selectors needed for CLI risk display are modeled here.
-/

namespace LeanCli.Ethereum.Abi

open LeanCli.Crypto
open LeanCli.Encoding.Rlp

def leftPad32 (bytes : ByteArray) : ByteArray :=
  let pad := 32 - bytes.size
  concat [List.replicate pad (0 : UInt8) |>.toByteArray, bytes]

def wordNat (n : Nat) : ByteArray :=
  leftPad32 (natBytes n)

def wordAddress (addr20 : ByteArray) : Option ByteArray :=
  if addr20.size = 20 then
    some (leftPad32 addr20)
  else
    none

def selectorTransfer : ByteArray :=
  (Hex.decode "a9059cbb").getD ByteArray.empty

def selectorApprove : ByteArray :=
  (Hex.decode "095ea7b3").getD ByteArray.empty

def selectorTransferFrom : ByteArray :=
  (Hex.decode "23b872dd").getD ByteArray.empty

inductive ERC20Call where
  | transfer (to : ByteArray) (amount : Nat)
  | approve (spender : ByteArray) (amount : Nat)
  | transferFrom (fromAddr to : ByteArray) (amount : Nat)
  | unknown (selector : ByteArray)

def take (bytes : ByteArray) (start len : Nat) : ByteArray :=
  (List.range len).foldl
    (init := ByteArray.empty)
    (fun acc i => acc.push bytes[start + i]!)

def bytesToNat (bytes : ByteArray) : Nat :=
  bytes.foldl (init := 0) (fun acc byte => acc * 256 + byte.toNat)

def decodeAddressWord (word : ByteArray) : Option ByteArray :=
  if word.size = 32 then
    some (take word 12 20)
  else
    none

def decodeERC20Call (calldata : ByteArray) : Option ERC20Call :=
  if calldata.size < 4 then
    none
  else
    let selector := take calldata 0 4
    if selector = selectorTransfer && calldata.size ≥ 68 then
      let toWord := take calldata 4 32
      let amountWord := take calldata 36 32
      match decodeAddressWord toWord with
      | some to => some (.transfer to (bytesToNat amountWord))
      | none => none
    else if selector = selectorApprove && calldata.size ≥ 68 then
      let spenderWord := take calldata 4 32
      let amountWord := take calldata 36 32
      match decodeAddressWord spenderWord with
      | some spender => some (.approve spender (bytesToNat amountWord))
      | none => none
    else if selector = selectorTransferFrom && calldata.size ≥ 100 then
      let fromWord := take calldata 4 32
      let toWord := take calldata 36 32
      let amountWord := take calldata 68 32
      match decodeAddressWord fromWord, decodeAddressWord toWord with
      | some fromAddr, some to => some (.transferFrom fromAddr to (bytesToNat amountWord))
      | _, _ => none
    else
      some (.unknown selector)

def ERC20Call.riskLabel : ERC20Call → String
  | .transfer _ _ => "ERC20 transfer"
  | .approve _ amount =>
      if amount = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff then
        "HIGH RISK: unlimited ERC20 approval"
      else
        "ERC20 approval"
  | .transferFrom _ _ _ => "HIGH RISK: ERC20 transferFrom"
  | .unknown _ => "unknown contract call"

end LeanCli.Ethereum.Abi
