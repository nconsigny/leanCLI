# ENS (Ethereum Name Service)

The canonical Ethereum name service. Maps `.eth` names to addresses,
text records, and other resources via three layers:

* **Registry** (`ENSRegistry`) — root mapping `node → (owner, resolver, ttl)`.
* **Registrar** (`BaseRegistrarImplementation` for `.eth` second-level,
  `ETHRegistrarController` for the commit/reveal registration flow).
* **Resolver** (`PublicResolver` is the default; users can deploy their
  own).

The wallet today supports:

* Decoding `register` / `renew` / `commit` calls against the controller.
* Decoding `setAddr` / `setName` / `setText` calls against the resolver.

The wallet does NOT currently draft ENS calldata from chat — the
register flow's commit/reveal timing (a ~60 s commit-age gate) needs
its own skill card to walk the user through the wait. That's a
follow-up.
