# ENS — security notes for ConfirmGate display

* The `node` argument in resolver calls is a `bytes32` keccak hash of
  the name's labels. The user CAN'T read it visually — the daemon
  resolves the hash back to a `.eth` string for display by querying
  the ENS subgraph or by maintaining a local reverse-namehash cache.
  Without resolution the rendered field is opaque; the descriptor
  should label it clearly.
* `register`'s `data[]` argument is an array of encoded resolver calls
  (`setAddr`, `setText`, …) executed atomically as part of registration.
  Each inner call should be decoded recursively — same path as
  Multicall3 decoding.
* `setName` (reverse record) lets anyone set ANY name they own to
  resolve to the caller's address. Visibility: only changes how the
  caller's address is displayed in name-aware UIs; doesn't change
  forward resolution. Misuse pattern: malicious dApp asks the user to
  set their reverse record to a name they don't actually own (impossible
  via PublicResolver because it checks ownership, but possible via a
  custom resolver — confirm the resolver is the canonical PublicResolver
  before signing).
* Duration is in seconds. A user typing "1 year" should result in
  31536000 — the daemon's `Numeric` tools handle this conversion;
  the chat path must NOT compute it in prose.
