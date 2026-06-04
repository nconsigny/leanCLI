/-!
# Memory-extraction prompt

The meta-prompt that asks the local LLM to update MEMORY.md from a
finished session. Kept as a separate module so the policy lives in
one auditable place — the curator can diff the wording without
touching the runtime.

Policy rationale lives in `docs/PHASE1C_PLAN.md` (`§B`). Edits to
this prompt change the agent's long-term recall behaviour; treat
them like a persona edit and land them with their motivating bug or
feature.

This module imports nothing from the signing or key-material tree
and is on the forbidden-import gated path documented in
`docs/PHASE0_PLAN.md`.
-/

namespace LeanCli.Agent.MemoryPrompts

/-- Hard cap on the LLM's output in bytes. Matches the
    `Memory.extract` post-filter cap; communicated to the model so
    it can self-truncate rather than emit content we'd drop. -/
def memoryByteCap : Nat := 8192

/-- The system-prompt body sent to the local LLM when extracting
    MEMORY.md from a session.

    Inclusions and exclusions are duplicated here verbatim — the
    model is the first line of defence; the post-extraction filter
    in `Memory.extract` is the second.

    The output schema (`{"memory": "..."}`) forces the model to
    commit to a full replacement rather than emit a diff the daemon
    would have to apply, which would multiply the trust surface. -/
def extractionInstructions : String := r"You are updating a small assistant's long-term memory file.
The file is included in every future conversation's system prompt,
so keep it small (under 8 KiB) and only include facts that are
durably useful across sessions.

INCLUDE:
- The user's stated preferences (default chain, slippage tolerance,
  preferred protocols, preferred recipients labelled with a name).
- Recurring transaction patterns (e.g. 'user sends to Trezor cold
  storage roughly monthly').
- The user's stated role or context if they shared it.
- Stable facts the user gave about themselves that they would not
  expect you to forget between sessions.

EXCLUDE (this is non-negotiable; if in doubt, omit):
- Specific transaction hashes, block numbers, exact balances, exact
  amounts the user paid.
- Specific addresses unless they appeared in the trusted wallet
  registry for the loaded seed. Memorising an address the user
  typed once is a phishing vector.
- Any hex string of length 64 (potential private key).
- Any sequence of 12 or 24 English words that could be a BIP-39
  mnemonic.
- Any information from a session marked incognito (you will not
  see one — the daemon never asks for extraction on an incognito
  session).
- Anything the user has explicitly asked you to forget.
- Signing-related method names (eth_sendRawTransaction,
  signTransaction, signTypedData, personal_sign, eth_sign).

OUTPUT FORMAT (strict):
Respond with a single JSON object on stdout, no prose before or
after. The object has exactly one field named `memory` whose value
is a string carrying the full new MEMORY.md content. For example,
if the new memory is empty, you reply with the literal three
characters: open-brace, the field, close-brace — `memory` as the
key and the empty string as the value.

Preserve relevant facts from the existing MEMORY.md unless the
new conversation contradicts them. Be conservative — when in
doubt, omit. The file is markdown; use short bulleted lists.
Stay well under 8192 bytes."

end LeanCli.Agent.MemoryPrompts
