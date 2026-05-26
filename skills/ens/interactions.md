# ENS — common interactions

## Register an .eth name (manual flow today)

1. User computes a `commitment = keccak256(abi.encode(name, owner, duration, secret, resolver, ...))`
   off-chain.
2. User calls `commit(bytes32 commitment)` on the Controller.
3. After at least 60 seconds (and within the commit-window), user calls
   `register(name, owner, duration, secret, resolver, data[], reverseRecord, ownerControlledFuses)`
   on the Controller with the same parameters.

The wallet decodes both calls but does not currently orchestrate the
60-second wait — users register through ens.app and ConfirmGate
reviews each tx.

## Renew an existing name

`renew(string name, uint256 duration)` on the Controller. No commit
phase; one-shot.

## Set the primary address

`setAddr(bytes32 node, address a)` on the resolver — points the name
at an address.

## Set a text record

`setText(bytes32 node, string key, string value)` on the resolver —
e.g. avatar, url, email.

## Set the reverse record (name shown for an address)

`setName(bytes32 node, string name)` on the resolver. Usually called
through `ReverseRegistrar` setName-shortcut, not directly.
