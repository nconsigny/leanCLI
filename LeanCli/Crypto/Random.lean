/-!
# OS randomness

Runtime entropy comes directly from Linux `/dev/urandom`. This module is IO-only
and intentionally has no deterministic fallback.
-/

namespace LeanCli.Crypto.Random

private def appendBytes (a b : ByteArray) : ByteArray :=
  b.foldl (init := a) (fun acc byte => acc.push byte)

private partial def readLoop (h : IO.FS.Handle) (remaining : Nat) (acc : ByteArray) :
    IO ByteArray := do
  if remaining = 0 then
    pure acc
  else
    let want := min remaining 65536
    let chunk ← h.read want.toUSize
    if chunk.size = 0 then
      throw <| IO.userError "unexpected EOF from /dev/urandom"
    else
      readLoop h (remaining - chunk.size) (appendBytes acc chunk)

def requireLinux : IO Unit := do
  let out ← IO.Process.output { cmd := "uname", args := #["-s"] }
  if out.exitCode != 0 then
    throw <| IO.userError out.stderr
  if out.stdout.trimAscii.toString != "Linux" then
    throw <| IO.userError "getRandomBytes is supported only on Linux"

def getRandomBytes (n : Nat) : IO ByteArray := do
  requireLinux
  let h ← IO.FS.Handle.mk "/dev/urandom" .read
  readLoop h n ByteArray.empty

end LeanCli.Crypto.Random
