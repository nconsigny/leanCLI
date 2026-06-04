import LeanCli.Basic
import LeanCli.Cli.Commands
import LeanCli.Cli.DaemonClient
import LeanCli.Cli.Passphrase
import LeanCli.Cli.Runtime
import LeanCli.Encoding.Json
import LeanCli.Transport.Uds
import LeanCli.Util.DotEnv

/-!
# LeanCli client library

Thin CLI client surface. This root intentionally imports only argument parsing,
JSON encoding, passphrase input, and local daemon transport.
-/
