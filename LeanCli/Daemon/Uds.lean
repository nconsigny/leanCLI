import LeanCli.Transport.Uds

/-!
# Daemon UDS compatibility alias

The implementation lives in `LeanCli.Transport.Uds` so the thin CLI can use
the socket transport without importing daemon modules.
-/

namespace LeanCli.Daemon.Uds

abbrev Listener := LeanCli.Transport.Uds.Listener
abbrev Conn := LeanCli.Transport.Uds.Conn
abbrev PeerCred := LeanCli.Transport.Uds.PeerCred

abbrev bindRaw := LeanCli.Transport.Uds.bindRaw
abbrev acceptRaw := LeanCli.Transport.Uds.acceptRaw
abbrev connectRaw := LeanCli.Transport.Uds.connectRaw
abbrev readRaw := LeanCli.Transport.Uds.readRaw
abbrev writeRaw := LeanCli.Transport.Uds.writeRaw
abbrev closeRaw := LeanCli.Transport.Uds.closeRaw
abbrev shutdownRaw := LeanCli.Transport.Uds.shutdownRaw
abbrev peerUidRaw := LeanCli.Transport.Uds.peerUidRaw
abbrev currentUid := LeanCli.Transport.Uds.currentUid

abbrev bind := LeanCli.Transport.Uds.bind
abbrev accept := LeanCli.Transport.Uds.accept
abbrev connect := LeanCli.Transport.Uds.connect
abbrev read := LeanCli.Transport.Uds.read
abbrev readLine := LeanCli.Transport.Uds.readLine
abbrev write := LeanCli.Transport.Uds.write
abbrev close := LeanCli.Transport.Uds.close
abbrev closeListener := LeanCli.Transport.Uds.closeListener
abbrev shutdown := LeanCli.Transport.Uds.shutdown
abbrev peerCred := LeanCli.Transport.Uds.peerCred
abbrev peerUidMatchesCurrent := LeanCli.Transport.Uds.peerUidMatchesCurrent

end LeanCli.Daemon.Uds
