import LeanKohaku.Basic
import LeanKohaku.Cli.Commands
import LeanKohaku.Cli.DaemonClient
import LeanKohaku.Cli.Passphrase
import LeanKohaku.Cli.Runtime
import LeanKohaku.Encoding.Json
import LeanKohaku.Transport.Uds
import LeanKohaku.Util.DotEnv

/-!
# LeanKohaku client library

Thin CLI client surface. This root intentionally imports only argument parsing,
JSON encoding, passphrase input, and local daemon transport.
-/
