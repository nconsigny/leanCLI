# tornado-cash — security

## OFAC sanctions status

The Tornado Cash smart contracts (including the four ETH pool
addresses listed in `contracts.json`) were added to the U.S.
Treasury Office of Foreign Assets Control Specially Designated
Nationals list on **2022-08-08**. The deposit and withdrawal
addresses associated with the pools and the underlying smart
contracts are sanctioned under Executive Order 13694. Source:
<https://home.treasury.gov/news/press-releases/jy0916>.

The agent surfaces this status as a factual statement on every
turn that activates this skill. The agent does NOT refuse turns
on the basis of sanctions — that is a legal decision the user
must make in their own jurisdiction. Users in U.S.-jurisdiction
contexts should obtain qualified legal advice before interacting
with these contracts.

## Pre-sign

TODO(curator): protocol-level safety checks beyond the OFAC
surfacing — note encoding, nullifier hygiene, relayer-fee
verification.
