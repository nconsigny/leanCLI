/-!
# Unix-domain socket FFI

Linux-only AF_UNIX stream socket bindings shared by the thin CLI client and
the daemon. The native side sets socket mode `0600`; the daemon additionally
enforces same-uid peer checks before dispatch.
-/

namespace LeanCli.Transport.Uds

structure Listener where
  fd : UInt32
  deriving Repr

structure Conn where
  fd : UInt32
  deriving Repr

structure PeerCred where
  uid : UInt32
  deriving Repr, DecidableEq

@[extern "lk_uds_bind"]
opaque bindRaw (path : @& String) : IO UInt32

@[extern "lk_uds_accept"]
opaque acceptRaw (fd : UInt32) : IO UInt32

@[extern "lk_uds_connect"]
opaque connectRaw (path : @& String) : IO UInt32

@[extern "lk_uds_read"]
opaque readRaw (fd maxBytes : UInt32) : IO ByteArray

@[extern "lk_uds_write"]
opaque writeRaw (fd : UInt32) (bytes : @& ByteArray) : IO UInt32

@[extern "lk_uds_close"]
opaque closeRaw (fd : UInt32) : IO Unit

@[extern "lk_uds_shutdown"]
opaque shutdownRaw (fd : UInt32) : IO Unit

@[extern "lk_uds_peer_uid"]
opaque peerUidRaw (fd : UInt32) : IO UInt32

@[extern "lk_uds_current_uid"]
opaque currentUid : IO UInt32

def bind (path : String) : IO Listener := do
  let fd ← bindRaw path
  pure { fd := fd }

def accept (listener : Listener) : IO Conn := do
  let fd ← acceptRaw listener.fd
  pure { fd := fd }

def connect (path : String) : IO Conn := do
  let fd ← connectRaw path
  pure { fd := fd }

def read (conn : Conn) (maxBytes : UInt32 := 65536) : IO ByteArray :=
  readRaw conn.fd maxBytes

/-- Locate the first `'\n'` (0x0A) byte in `bytes` at or after `start`.
    Returns the absolute index, or `none` if no newline is present. -/
private partial def newlineIdx (bytes : ByteArray) (start : Nat := 0) :
    Option Nat :=
  if start < bytes.size then
    if bytes.get! start == 0x0A then some start
    else newlineIdx bytes (start + 1)
  else none

/-- Read from `conn` until a `'\n'` byte is observed or the peer closes
    the connection, buffering across syscalls. Returns the bytes received
    up to (but NOT including) the trailing newline.

    `Transport.Uds.read` is a single `read(2)` and a SOCK_STREAM `read(2)`
    may return any prefix of what the peer has written — every
    line-oriented consumer of these sockets must loop until it sees its
    terminator. The previous single-read shape silently truncated agentd
    replies large enough to be split by the kernel, producing
    `unexpected end of JSON input` on the client.

    Anything received past the first newline is discarded: the wire
    protocol on these sockets is strict one-frame-per-connection, so a
    second `\n` would be a protocol error rather than a pipelined frame.

    `maxBytes` (default 4 MiB) caps the buffer so a misbehaving peer
    that never sends a newline cannot exhaust memory. -/
partial def readLine (conn : Conn) (maxBytes : Nat := 1 <<< 22) :
    IO ByteArray := do
  let rec go (acc : ByteArray) : IO ByteArray := do
    if acc.size > maxBytes then
      throw <| IO.userError
        s!"Uds.readLine: exceeded {maxBytes} bytes without newline"
    let chunk ← readRaw conn.fd 65536
    if chunk.isEmpty then
      pure acc
    else
      match newlineIdx chunk with
      | none => go (acc ++ chunk)
      | some i => pure (acc ++ chunk.extract 0 i)
  go ByteArray.empty

def write (conn : Conn) (bytes : ByteArray) : IO UInt32 :=
  writeRaw conn.fd bytes

def close (conn : Conn) : IO Unit :=
  closeRaw conn.fd

def closeListener (listener : Listener) : IO Unit :=
  closeRaw listener.fd

def shutdown (conn : Conn) : IO Unit :=
  shutdownRaw conn.fd

def peerCred (conn : Conn) : IO PeerCred := do
  let uid ← peerUidRaw conn.fd
  pure { uid := uid }

def peerUidMatchesCurrent (conn : Conn) : IO Bool := do
  let peer ← peerCred conn
  let uid ← currentUid
  pure (peer.uid == uid)

end LeanCli.Transport.Uds
