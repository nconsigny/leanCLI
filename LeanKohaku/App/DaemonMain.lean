import LeanKohaku.Lib.Core

def main (_args : List String) : IO UInt32 := do
  -- Auto-load `./.env` and `~/.config/leankohaku/.env` before resolving
  -- config so `MAINNET_RPC_URL` / `SEPOLIA_RPC_URL` etc. are picked up
  -- without sourcing the file by hand. Real shell exports always win
  -- (setenv overwrite=0). Disable with `LEANKOHAKU_NO_DOTENV=1`.
  LeanKohaku.Util.DotEnv.autoload
  LeanKohaku.Daemon.Server.run (← LeanKohaku.Daemon.Config.resolve)
  return 0
