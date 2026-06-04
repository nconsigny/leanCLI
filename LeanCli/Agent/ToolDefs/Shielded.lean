import LeanCli.Agent.Tools
import LeanCli.Agent.DaemonClient
import LeanCli.Encoding.Json

/-!
# Shielded agent tools (Privacy Pool + Railgun)

Typed tools wrapping the daemon's `shielded.*` RPCs so the LLM-driven
chat path has a structured surface instead of free-forming
`propose_send` hex for shielded calldata. Mirrors the shape of
`ToolDefs/Aave.lean`: per-action JSON Schema, decimal-string amounts
(avoiding IEEE-754 truncation), one `DaemonClient.call` per tool.

## Coverage (PR 3 of the privacy slice)

| Tool                              | Daemon RPC                          | Notes                                  |
|-----------------------------------|-------------------------------------|----------------------------------------|
| `prepare_privacy_pool_deposit`    | `shielded.prepareDeposit`           | Returns prepared txns; no broadcast.   |
| `prepare_privacy_pool_withdraw`   | `shielded.prepareWithdraw`          | Returns prepared txns; no broadcast.   |
| `prepare_railgun_shield`          | `shielded.railgun.prepareShield`    | Returns prepared txns; no broadcast.   |
| `prepare_railgun_unshield`        | `shielded.railgun.unshield`         | Bundler path: signs + broadcasts via SDK. |
| `prepare_railgun_transfer`        | `shielded.railgun.transfer`         | 0zk → 0zk internal; ERC-20 only.      |
| `prepare_tornado_deposit`         | `shielded.tornado.prepareDeposit`   | Fixed denominations; bridge stub.     |
| `prepare_tornado_withdraw`        | `shielded.tornado.prepareWithdraw`  | Needs user's saved deposit note.      |

PR 2 lands the Tornado wrappers + daemon RPCs + chat.draft envelope.
The bridge SDK integration (snarkjs + Baby Jubjub Pedersen) is a
follow-up; the typed tools surface a clear `daemon_error` until the
sidecar implementation lands.

## Trust model

* All tools `classify := .read`. They never sign and never broadcast
  *from inside the agent loop*. Railgun unshield/transfer DO broadcast
  via the bundler at daemon level, but that's the existing surface
  the chat.draft prepare envelope already exposes (PR 1, see
  `chatDraftIntentResponse`). The agent tool here is a thin RPC
  wrapper, not a new signing path.
* No passphrase field is exposed. The daemon's `unlockPpSecretSmart`
  resolves PP secrets through the master KEK path (see
  [[feedback_no_per_slot_passphrase]] — in-flow prompts are master
  KEK + TPM PIN only).
* No custom 7702 delegate construction. The Railgun paymaster only
  sponsors the hardcoded IMPL contract (see [[project_railgun_poi]]);
  any other delegate is rejected. The bridge SDK signs and embeds
  the authorization — the tool never fabricates one.

## Schema convention

* `amountEth` — decimal STRING (`"0.05"`). Same convention as the
  underlying RPCs and as `ToolDefs/Aave.lean`'s `amount`. Lets us
  carry sub-wei precision without ambiguity in JSON numbers.
* `recipient` — 0x-prefixed 20-byte address.
* `tokenAddress` — optional ERC-20 address. Absent ⇒ native ETH
  (the bridge wraps to WETH internally for Railgun).
* `name` — optional wallet-slot name; absent ⇒ daemon default. Only
  applicable to Railgun (Privacy Pool deposits don't need an EOA
  derivation).
* `chainId` — required so the agent loop's chain-pin gate
  (`Tools.dispatch`) can reject mis-targeted calls before invocation.
-/

namespace LeanCli.Agent.ToolDefs.Shielded

open LeanCli.Agent
open LeanCli.Agent.Tools
open LeanCli.Agent.DaemonClient
open LeanCli.Encoding.Json

/-- Structured error envelope. Same shape as `ToolDefs/Aave.lean`'s
    `errResult` so the LLM sees a uniform `{kind, error}` payload
    across protocols. -/
private def errResult (kind err : String)
    (extra : Array (String × Json) := #[]) : ToolResult :=
  { ok := false,
    data := .obj <| #[("kind", .str kind), ("error", .str err)] ++ extra }

/-- Forward to the daemon and translate transport / protocol errors
    uniformly. On success the daemon's JSON is passed through
    verbatim — shielded responses are heterogeneous (prepared txns,
    bundler receipts, etc.) and the model is the right consumer for
    the structure. -/
private def callDaemon (cfg : AgentConfig) (toolName method : String)
    (params : Json) : IO ToolResult := do
  match ← DaemonClient.call cfg.daemonSocket method params with
  | .error e =>
      let msg := match e with
        | .transport m => s!"daemon transport ({toolName}): {m}"
        | .protocol  m => s!"daemon protocol ({toolName}): {m}"
        | .appError code m _ => s!"daemon {toolName} error {code}: {m}"
      pure (errResult "daemon_error" msg)
  | .ok j =>
      pure { ok := true, data := j,
             summary := some s!"{toolName} ready" }

/-! ## Shared schema fragments — kept verbose so each tool stays self-readable -/

private def chainIdProp : Json := .obj #[
  ("type", .str "integer"),
  ("description", .str "EVM chain id (1 = mainnet, 11155111 = sepolia)")
]
private def amountEthProp : Json := .obj #[
  ("type", .str "string"),
  ("description",
    .str "Amount in ETH as a decimal STRING (e.g. \"0.05\"). Strings avoid the IEEE-754 truncation a JSON number would impose at this precision.")
]
private def recipientProp : Json := .obj #[
  ("type", .str "string"),
  ("description",
    .str "0x-prefixed 20-byte destination address. Should be a FRESH address with no on-chain link to the source to preserve anonymity-set linkage.")
]
private def tokenAddressProp : Json := .obj #[
  ("type", .str "string"),
  ("description",
    .str "Optional ERC-20 token address. Omit for native ETH (the bridge will wrap internally for Railgun).")
]
private def tornadoNoteProp : Json := .obj #[
  ("type", .str "string"),
  ("description",
    .str "The user's saved Tornado deposit note. Canonical form `tornado-note-eth-<denom>-<base58>` — the value the prepare_tornado_deposit tool handed back at deposit time. NEVER fabricate one; if the user hasn't supplied a note, ask for it before calling.")
]
private def tornadoDenominationEthProp : Json := .obj #[
  ("type", .str "string"),
  ("description",
    .str "Tornado pool denomination as a decimal-ETH string. MUST be exactly \"0.1\", \"1\", \"10\", or \"100\" — Tornado pools are fixed-denomination and any other value mis-routes to the wrong contract.")
]
private def nameProp : Json := .obj #[
  ("type", .str "string"),
  ("description",
    .str "Wallet-slot name (e.g. \"leanWallet\"). Omit to use the daemon's default slot.")
]
private def viaRelayerProp : Json := .obj #[
  ("type", .str "boolean"),
  ("description",
    .str "When true (default), withdrawal goes through a relayer so the recipient never pays gas — preserves the shield. Setting false reveals the recipient's ETH balance change at chain level.")
]

/-! ## Extract helpers -/

private def requireString (name field : String) (args : Json) :
    Except ToolResult String :=
  match getField field args >>= asString with
  | some s => .ok s
  | none   =>
      .error (errResult "bad_request" s!"{name}: missing or non-string '{field}'")

private def optString (args : Json) (k : String) : Option String :=
  getField k args >>= asString

private def optBool (args : Json) (k : String) : Option Bool :=
  match getField k args with
  | some (.bool b) => some b
  | _ => none

/-! ## The five tools -/

/-- Privacy Pool deposit. Returns prepared txns; the TUI walks each
    through `tx.simulate` + ConfirmGate before signing. -/
def preparePrivacyPoolDeposit : ToolDecl := {
  name := "prepare_privacy_pool_deposit",
  description :=
    "Prepare an unsigned 0xbow Privacy Pool deposit of native ETH. \
     Returns one or more prepared txns (typically just the deposit; \
     no approval needed for native ETH). The model must NOT compute \
     calldata by hand — call this tool, then feed the returned \
     tx(s) into propose_send one at a time.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "chainId", .str "amountEth"]),
    ("properties", .obj #[
      ("chainId",   chainIdProp),
      ("amountEth", amountEthProp)
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match requireString "prepare_privacy_pool_deposit" "amountEth" args with
    | .error e => pure e
    | .ok amountEth =>
        let params : Json := .obj #[("amountEth", .str amountEth)]
        callDaemon cfg "prepare_privacy_pool_deposit"
          "shielded.prepareDeposit" params
}

/-- Privacy Pool withdraw. `viaRelayer` defaults to true at the daemon
    side; expose it for the model's transparency. -/
def preparePrivacyPoolWithdraw : ToolDecl := {
  name := "prepare_privacy_pool_withdraw",
  description :=
    "Prepare an unsigned 0xbow Privacy Pool withdrawal of native ETH \
     to a recipient address (canonically a freshly-generated wallet \
     that has never appeared in the deposit chain). Returns prepared \
     txns; feed them into propose_send one at a time.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "chainId", .str "amountEth", .str "recipient"]),
    ("properties", .obj #[
      ("chainId",    chainIdProp),
      ("amountEth",  amountEthProp),
      ("recipient",  recipientProp),
      ("viaRelayer", viaRelayerProp)
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match requireString "prepare_privacy_pool_withdraw" "amountEth" args with
    | .error e => pure e
    | .ok amountEth =>
        match requireString "prepare_privacy_pool_withdraw" "recipient" args with
        | .error e => pure e
        | .ok recipient =>
            let viaRelayer := (optBool args "viaRelayer").getD true
            let params : Json := .obj #[
              ("amountEth",  .str amountEth),
              ("recipient",  .str recipient),
              ("viaRelayer", .bool viaRelayer)
            ]
            callDaemon cfg "prepare_privacy_pool_withdraw"
              "shielded.prepareWithdraw" params
}

/-- Railgun shield (preview / prepare). Daemon orchestrates paymaster
    sponsorship and 7702 stamping inside the bridge SDK — the agent
    layer never sees those details. -/
def prepareRailgunShield : ToolDecl := {
  name := "prepare_railgun_shield",
  description :=
    "Prepare an unsigned Railgun shield of native ETH (or an ERC-20 \
     when tokenAddress is supplied). Returns prepared txns; the \
     paymaster + 7702 authorization are stamped by the bridge SDK \
     (the model must NOT fabricate any 7702 delegate — the paymaster \
     only sponsors the hardcoded IMPL contract). Shielded funds are \
     spendable after the POI tree updates (minutes to hours).",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "chainId", .str "amountEth"]),
    ("properties", .obj #[
      ("chainId",      chainIdProp),
      ("amountEth",    amountEthProp),
      ("tokenAddress", tokenAddressProp),
      ("name",         nameProp)
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match requireString "prepare_railgun_shield" "amountEth" args with
    | .error e => pure e
    | .ok amountEth =>
        let params : Json := .obj <|
          #[("amountEth", .str amountEth)]
            ++ (match optString args "tokenAddress" with
                | some t => #[("tokenAddress", .str t)]
                | none   => #[])
            ++ (match optString args "name" with
                | some n => #[("name", .str n)]
                | none   => #[])
        callDaemon cfg "prepare_railgun_shield"
          "shielded.railgun.prepareShield" params
}

/-- Railgun unshield. Unlike the Privacy Pool path, the daemon's RPC
    here builds + relays the userOp through a 4337 bundler in one
    pass (no separate prepare step exists at the SDK layer). The
    model still calls this once; the bundler receipt is returned. -/
def prepareRailgunUnshield : ToolDecl := {
  name := "prepare_railgun_unshield",
  description :=
    "Unshield Railgun ETH (or an ERC-20 when tokenAddress is set) to \
     a recipient address via the SDK's bundler path. Requires a \
     wallet-slot `name` so the daemon can derive the delegating EOA \
     private key. The daemon's pre-configured bundler URL or \
     CANDIDE_API_KEY is required; absence returns daemon_error. \
     Returns the bundler receipt; the model then summarizes for the user.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required",
      .arr #[.str "chainId", .str "name", .str "recipient", .str "amountEth"]),
    ("properties", .obj #[
      ("chainId",      chainIdProp),
      ("name",         nameProp),
      ("recipient",    recipientProp),
      ("amountEth",    amountEthProp),
      ("tokenAddress", tokenAddressProp)
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match requireString "prepare_railgun_unshield" "name" args with
    | .error e => pure e
    | .ok name =>
        match requireString "prepare_railgun_unshield" "recipient" args with
        | .error e => pure e
        | .ok recipient =>
            match requireString "prepare_railgun_unshield" "amountEth" args with
            | .error e => pure e
            | .ok amountEth =>
                let params : Json := .obj <|
                  #[("name",      .str name),
                    ("recipient", .str recipient),
                    ("amountEth", .str amountEth)]
                    ++ (match optString args "tokenAddress" with
                        | some t => #[("tokenAddress", .str t)]
                        | none   => #[])
                callDaemon cfg "prepare_railgun_unshield"
                  "shielded.railgun.unshield" params
}

/-- Tornado Cash deposit. Fixed-denomination mixer; the bridge sidecar
    generates the spending note + Pedersen-hashed commitment and
    returns `deposit(commitment)` calldata. PR 2 ships a bridge stub
    until the snarkjs + Baby Jubjub Pedersen layer lands; users see a
    clear "not yet implemented" `daemon_error` in that interim. -/
def prepareTornadoDeposit : ToolDecl := {
  name := "prepare_tornado_deposit",
  description :=
    "Prepare an unsigned Tornado Cash deposit of native ETH into one \
     of the fixed-denomination pools (0.1 / 1 / 10 / 100 ETH). The \
     bridge sidecar generates and returns the spending note — the user \
     MUST save it; the wallet cannot reconstruct the note from the \
     on-chain commitment alone. Any amountEth outside the canonical \
     set is rejected.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "chainId", .str "amountEth"]),
    ("properties", .obj #[
      ("chainId",   chainIdProp),
      ("amountEth", tornadoDenominationEthProp)
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match requireString "prepare_tornado_deposit" "amountEth" args with
    | .error e => pure e
    | .ok amountEth =>
        let params : Json := .obj #[("amountEth", .str amountEth)]
        callDaemon cfg "prepare_tornado_deposit"
          "shielded.tornado.prepareDeposit" params
}

/-- Tornado Cash withdraw. Consumes the user's saved deposit note and
    builds withdraw calldata with a ZK proof against the pool's
    current merkle tree. The bridge sidecar owns the proof generation;
    PR 2's stub returns a `daemon_error` pending implementation. -/
def prepareTornadoWithdraw : ToolDecl := {
  name := "prepare_tornado_withdraw",
  description :=
    "Prepare an unsigned Tornado Cash withdrawal. Requires the user's \
     saved deposit `note` from a prior prepare_tornado_deposit call \
     (the bridge cannot recover a note from the chain — only the user \
     has it). Recipient should be a FRESH address with no on-chain \
     link to the deposit source; otherwise the mix is defeated.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required",
      .arr #[.str "chainId", .str "amountEth",
             .str "recipient", .str "note"]),
    ("properties", .obj #[
      ("chainId",   chainIdProp),
      ("amountEth", tornadoDenominationEthProp),
      ("recipient", recipientProp),
      ("note",      tornadoNoteProp)
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match requireString "prepare_tornado_withdraw" "amountEth" args with
    | .error e => pure e
    | .ok amountEth =>
        match requireString "prepare_tornado_withdraw" "recipient" args with
        | .error e => pure e
        | .ok recipient =>
            match requireString "prepare_tornado_withdraw" "note" args with
            | .error e => pure e
            | .ok note =>
                let params : Json := .obj #[
                  ("amountEth", .str amountEth),
                  ("recipient", .str recipient),
                  ("note",      .str note)
                ]
                callDaemon cfg "prepare_tornado_withdraw"
                  "shielded.tornado.prepareWithdraw" params
}

/-- Railgun internal transfer (0zk → 0zk). ERC-20 only at the SDK
    level (tokenGuard). -/
def prepareRailgunTransfer : ToolDecl := {
  name := "prepare_railgun_transfer",
  description :=
    "Send an ERC-20 between two Railgun (0zk) addresses without \
     leaving the shielded set. The daemon signs + relays via the 4337 \
     bundler. Requires `tokenAddress` — native ETH transfers inside \
     Railgun are not supported by the SDK's tokenGuard.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required",
      .arr #[.str "chainId", .str "name", .str "recipient",
             .str "amountEth", .str "tokenAddress"]),
    ("properties", .obj #[
      ("chainId",      chainIdProp),
      ("name",         nameProp),
      ("recipient",    recipientProp),
      ("amountEth",    amountEthProp),
      ("tokenAddress", tokenAddressProp)
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match requireString "prepare_railgun_transfer" "name" args with
    | .error e => pure e
    | .ok name =>
        match requireString "prepare_railgun_transfer" "recipient" args with
        | .error e => pure e
        | .ok recipient =>
            match requireString "prepare_railgun_transfer" "amountEth" args with
            | .error e => pure e
            | .ok amountEth =>
                match requireString "prepare_railgun_transfer" "tokenAddress" args with
                | .error e => pure e
                | .ok tokenAddress =>
                    let params : Json := .obj #[
                      ("name",         .str name),
                      ("recipient",    .str recipient),
                      ("amountEth",    .str amountEth),
                      ("tokenAddress", .str tokenAddress)
                    ]
                    callDaemon cfg "prepare_railgun_transfer"
                      "shielded.railgun.transfer" params
}

end LeanCli.Agent.ToolDefs.Shielded
