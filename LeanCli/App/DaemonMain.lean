import LeanCli.Lib.Core

def main (_args : List String) : IO UInt32 := do
  -- Auto-load `./.env` and `~/.config/leancli/.env` before resolving
  -- config so `MAINNET_RPC_URL` / `SEPOLIA_RPC_URL` etc. are picked up
  -- without sourcing the file by hand. Real shell exports always win
  -- (setenv overwrite=0). Disable with `LEANCLI_NO_DOTENV=1`.
  LeanCli.Util.DotEnv.autoload
  LeanCli.Daemon.Server.run (← LeanCli.Daemon.Config.resolve)
  return 0
