# tornado-cash — security

## OFAC sanctions status (factual)

The Tornado Cash smart contracts — including the four ETH pool
addresses in `contracts.json` (0.1 ETH, 1 ETH, 10 ETH, 100 ETH) —
were added to the U.S. Treasury Office of Foreign Assets Control
Specially Designated Nationals (SDN) list on **2022-08-08** under
the authority of Executive Order 13694 (cyber-enabled malicious
activity). Source:
<https://home.treasury.gov/news/press-releases/jy0916>.

The November 2022 redesignation by OFAC, and the August 2023
unrelated indictment of Tornado Cash's developers, are publicly
documented; this skill does not summarize them — interested users
should consult primary legal sources.

The agent surfaces this status as a factual statement when the
skill activates. It does **not** refuse research / decode turns on
that basis; the legal question of whether a given user, in a given
jurisdiction, may interact with these contracts is the user's to
resolve, ideally with qualified legal counsel.

## Discuss vs. draft (the crisp boundary)

The boundary the agent enforces is between **discussion** and
**drafting**:

| Request | Agent action |
|---|---|
| "What is Tornado Cash?" | Answer (overview.md). |
| "Decode this calldata, it might be Tornado." | Decode using `abi/ETHTornado.json` (TODO stub) + 4byte fallback; explain. |
| "How does Tornado differ from Privacy Pools?" | Compare; recommend Privacy Pools / RAILGUN for active use. |
| "Why is it sanctioned?" | Cite OFAC press release + E.O. 13694. |
| "Draft a 1 ETH deposit." | **Decline.** Point at sanctions + absence of SDK. |
| "Draft a withdrawal from pool X." | **Decline.** Same. |
| "Generate a Tornado note for me." | **Decline.** Same. |
| "Submit my proof to a Tornado relayer." | **Decline.** Same. |

This is the same posture that `SKILL.md` declares with
`ofacFlagged: true`: surfaces facts, does not refuse to discuss,
**does refuse to draft**.

## Why no SDK is also a safety feature

Even setting aside sanctions, the absence of a maintained Kohaku
SDK for Tornado Cash is itself a safety reason not to draft
transactions:

* Note generation requires snarkjs + a copy of the Tornado circuit
  + a properly-formed random `nullifier` and `secret`. Doing this
  by hand inside the bridge would be a fresh attack surface, not a
  reuse of audited code.
* Tornado's relayer protocol is informal and several relayer
  endpoints have been taken offline. The agent cannot durably
  point at a working relayer.
* Tornado's withdrawal proof generation took ~10s on commodity
  hardware in 2022; without a maintained SDK there is no good
  way to keep that working as proving systems and Node ABIs drift.

So the "draft refusal" is **doubly motivated**: sanctions posture
plus engineering reality. The agent surfaces both.

## What the agent does at decode time

When the agent decodes a Tornado Cash calldata blob (because the
user pasted one or `SendRawFlow` is decoding an incoming tx that
references one of the SDN addresses):

1. Identify the function from `abi/ETHTornado.json` (or the 4byte
   directory if the ABI stub is empty).
2. Pretty-print the call.
3. Surface the OFAC status as part of the decoded view —
   `contracts.json` flags the addresses, the decoder reads the
   flag, the UI rendering shows the sanctions banner.
4. If the user then asks "and now sign this", the agent declines
   per the discuss/draft boundary.

## Refusal triggers

* "Build me Tornado Cash calldata" — refuse.
* "Generate a Tornado note" — refuse.
* "Pick a Tornado relayer for me" — refuse.
* Any request that produces a transaction whose `to` address is
  in the `mainnet` table of `contracts.json` — refuse at the
  pre-sign stage.

The refusal text the agent uses cites two facts: OFAC SDN listing,
and absence of a Kohaku SDK. It does not editorialize on whether
the sanction is right or wrong — that is the user's question to
take up with their legal counsel.
