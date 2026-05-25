import LeanKohaku.Transport.Uds

/-!
# Daemon UDS compatibility alias

The implementation lives in `LeanKohaku.Transport.Uds` so the thin CLI can use
the socket transport without importing daemon modules.
-/

namespace LeanKohaku.Daemon.Uds

abbrev Listener := LeanKohaku.Transport.Uds.Listener
abbrev Conn := LeanKohaku.Transport.Uds.Conn
abbrev PeerCred := LeanKohaku.Transport.Uds.PeerCred

abbrev bindRaw := LeanKohaku.Transport.Uds.bindRaw
abbrev acceptRaw := LeanKohaku.Transport.Uds.acceptRaw
abbrev connectRaw := LeanKohaku.Transport.Uds.connectRaw
abbrev readRaw := LeanKohaku.Transport.Uds.readRaw
abbrev writeRaw := LeanKohaku.Transport.Uds.writeRaw
abbrev closeRaw := LeanKohaku.Transport.Uds.closeRaw
abbrev shutdownRaw := LeanKohaku.Transport.Uds.shutdownRaw
abbrev peerUidRaw := LeanKohaku.Transport.Uds.peerUidRaw
abbrev currentUid := LeanKohaku.Transport.Uds.currentUid

abbrev bind := LeanKohaku.Transport.Uds.bind
abbrev accept := LeanKohaku.Transport.Uds.accept
abbrev connect := LeanKohaku.Transport.Uds.connect
abbrev read := LeanKohaku.Transport.Uds.read
abbrev readLine := LeanKohaku.Transport.Uds.readLine
abbrev write := LeanKohaku.Transport.Uds.write
abbrev close := LeanKohaku.Transport.Uds.close
abbrev closeListener := LeanKohaku.Transport.Uds.closeListener
abbrev shutdown := LeanKohaku.Transport.Uds.shutdown
abbrev peerCred := LeanKohaku.Transport.Uds.peerCred
abbrev peerUidMatchesCurrent := LeanKohaku.Transport.Uds.peerUidMatchesCurrent

end LeanKohaku.Daemon.Uds
