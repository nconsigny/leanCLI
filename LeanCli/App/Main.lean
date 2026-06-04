import LeanCli.Lib.Client

def main (args : List String) : IO UInt32 := do
  -- Same `.env` autoload as the daemon, so `leancli network show`,
  -- auto-spawned daemons, and direct CLI commands all see the same
  -- per-chain RPC URLs without manual `set -a; . .env`.
  LeanCli.Util.DotEnv.autoload
  LeanCli.Cli.run args
