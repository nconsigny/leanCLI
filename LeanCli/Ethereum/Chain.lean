/-!
# Chain configuration
-/

namespace LeanCli.Ethereum.Chain

structure Chain where
  id   : Nat
  name : String
  rpc  : String
  deriving Repr

def mainnet (rpc : String) : Chain := { id := 1,       name := "mainnet",  rpc }

def sepolia (rpc : String) : Chain := { id := 11155111, name := "sepolia", rpc }

end LeanCli.Ethereum.Chain
