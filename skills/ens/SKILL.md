---
name: ens
version: 0.1
description: Ethereum Name Service — register, renew, and set records on .eth names. Decode-and-confirm coverage today; drafting (register / setAddr / setName) is decode-only until per-flow skill cards land.
category: protocol
alwaysOn: false
triggers:
  - ens
  - .eth
  - register
  - renew
  - setaddr
  - setname
  - settext
  - subname
  - ethregistrar
  - publicresolver
  - 0x253553366da8546fc250f225fe3d25d0c782303b
  - 0x231b0ee14048e9dccd1d247744d114a4eb5e8e63
---
ENS is the canonical name service on Ethereum. Users interact with two
contracts the wallet must decode-and-confirm correctly:

* **ETHRegistrarController** (`0x253553…2303b` on mainnet,
  `0xfb3ce5…1f968` on Sepolia) — the contract `register(...)`,
  `renew(...)`, and the v3 commit/reveal `commit(bytes32 commitment)`
  pattern are called against.
* **PublicResolver** (`0x231b0e…8e63` on mainnet, `0x8fade6…b7dd` on
  Sepolia) — `setAddr(bytes32 node, address a)`,
  `setName(bytes32 node, string name)`, `setText(bytes32 node, string key, string value)`.

The wallet's job at the trust boundary:

1. **Decode**: every `register` / `renew` / `setAddr` / `setName` call
   must be parsed against `bridge/clearsign/registry/ens-*.json` (7730
   descriptors) so the user sees "Register vitalik.eth for 1 year"
   instead of `register(string,address,uint256,bytes32,address,bytes[],bool,uint16)`.
2. **Simulate**: prefer the standard `tx.simulate` path; ENS calls are
   not multicall-router-shaped, so the direct RPC simulation surfaces
   no spurious reverts.
3. **Confirm**: ConfirmGate displays the parsed intent. The registrar's
   `commit` phase produces opaque bytes32 — show the rendering and let
   the user verify, but the meaning is "first half of a register; the
   wallet will follow up with `register`".

Drafting ENS calldata from chat is intentionally not wired yet — the
user-flow is dominated by the commit/reveal timing window which needs
its own skill card. The `register-name` and `setrecord` task-skills
are open follow-ups.
