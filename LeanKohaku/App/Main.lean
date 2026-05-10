import LeanKohaku.Lib.Client

def main (args : List String) : IO UInt32 := do
  -- Same `.env` autoload as the daemon, so `kohaku network show`,
  -- auto-spawned daemons, and direct CLI commands all see the same
  -- per-chain RPC URLs without manual `set -a; . .env`.
  LeanKohaku.Util.DotEnv.autoload
  LeanKohaku.Cli.run args
