import LeanCli.Agent.Tools
import LeanCli.Agent.ToolDefs.Numeric
import LeanCli.Encoding.Json

/-!
# Approval-audit agent tools

`audit_approvals` and `check_allowance` — the LLM's window onto ERC-20
allowance state. Both are read-only and reach the chain only through
the daemon's policy-gated outbound layer.

## Why these exist

Without a dedicated tool the model has only the generic `chain_read`
(`eth_call`) primitive, so when a user asks "what approvals do I have?"
it *improvises*: it guesses a hardcoded spender list and hand-encodes
`allowance(owner,spender)` for each — getting the ABI encoding wrong,
querying mainnet spenders against a Sepolia wallet, and never actually
discovering anything. That is the opposite of how cross-dApp approval
discovery works.

`audit_approvals` forwards to the daemon RPC `daemon.approvals.list`,
which is the real discovery engine: it scans `Approval(owner=*, …)`
event logs across **all** token contracts (the Revoke.cash model),
dedupes per `(token, spender)`, and re-reads the live `allowance()` so
already-revoked pairs drop out. The model never invents a spender.

`check_allowance` answers the narrower "how much has X approved Y for
token T?" question. It builds the canonical `allowance(address,address)`
calldata *in Lean* and routes it through the existing `chain.ethCall`
RPC — so no per-pair daemon RPC is added (a generic `eth_call` suffices,
per repo policy), and the model is never left to hand-encode the
selector + word padding it kept getting wrong.

Neither tool signs or proposes; both are classified `.read`.
-/

namespace LeanCli.Agent.ToolDefs.Approvals

open LeanCli.Agent
open LeanCli.Agent.Tools
open LeanCli.Encoding.Json

/-- `2^256 - 1`, the conventional "unlimited" allowance sentinel. -/
private def maxUint256 : Nat := 2 ^ 256 - 1

/-- Selector for `allowance(address,address)` — `keccak256(...)[:4]`. -/
private def selAllowance : String := "0xdd62ed3e"

private def isHexChar (c : Char) : Bool :=
  ('0' ≤ c ∧ c ≤ '9') ∨ ('a' ≤ c ∧ c ≤ 'f') ∨ ('A' ≤ c ∧ c ≤ 'F')

/-- Left-pad a 20-byte address into a 32-byte ABI word (64 lowercase hex
    chars, no `0x`). Returns `none` unless `a` is a `0x`-prefixed,
    40-hex-char address — so the model gets a clean rejection instead of
    a malformed call when it passes a name like `mainEOA` it forgot to
    resolve first. -/
private def encodeAddrWord (a : String) : Option String :=
  let stripped := if a.startsWith "0x" ∨ a.startsWith "0X" then (a.drop 2).toString else a
  if stripped.length ≠ 40 then none
  else if ¬ stripped.toList.all isHexChar then none
  else some (String.ofList (List.replicate 24 '0') ++ stripped.toLower)

/-- Shared `{kind, error}` rejection envelope. -/
private def errResult (kind err : String) : ToolResult :=
  { ok := false, data := .obj #[("kind", .str kind), ("error", .str err)] }

/-- Require a whitelisted `chainId` field, mirroring `Chain.chainGuard`
    so the active-chain pin is enforced before any daemon round-trip. -/
private def chainGuard (toolName : String) (cfg : AgentConfig) (args : Json) :
    Except String Nat := do
  let some chainJ := getField "chainId" args
    | .error s!"{toolName}: missing required field 'chainId'"
  let some chainId := asNat chainJ
    | .error s!"{toolName}: 'chainId' must be a non-negative integer"
  if cfg.chainWhitelist.contains chainId then .ok chainId
  else .error s!"{toolName}: chainId {chainId} not in whitelist"

/-- `audit_approvals` — list every active outgoing ERC-20 allowance for a
    wallet, discovered across all dApps via `Approval` event logs. -/
def auditApprovals : ToolDecl := {
  name := "audit_approvals",
  description :=
    "List every active outgoing approval a wallet currently has, discovered \
     across ALL contracts and dApps by scanning event logs (not a guessed \
     spender list). Covers three surfaces, each re-read live so revoked/zero \
     entries are dropped: ERC-20 allowances, ERC-721/1155 ApprovalForAll \
     operator grants, and Uniswap Permit2 grants. Use this for any 'what \
     approvals/allowances do I have', 'audit my approvals', or 'what can pull \
     my tokens/NFTs' question — never hand-pick spenders yourself. Returns \
     {approvals:[{token,spender,amount,amountHuman,tokenSymbol,spenderLabel,\
     lastSeenBlock}], nftApprovals:[{token,operator,approved,operatorLabel}], \
     permit2Approvals:[{token,spender,amount,amountHuman,expiration,\
     spenderLabel}], fromBlock, toBlock, implemented, note}. Read-only.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "chainId"]),
    ("properties", .obj #[
      ("chainId", .obj #[("type", .str "integer")]),
      ("wallet", .obj #[
        ("type", .str "string"),
        ("description",
          .str "0x address of the wallet to audit. Resolve names to 0x first \
                (slot_lookup / ens_resolve). Omit to use the active default wallet.")
      ]),
      ("lookback", .obj #[
        ("type", .str "integer"),
        ("description",
          .str "Optional block window to scan back over. Omit for the default; \
                raise it against an indexed provider for deeper history.")
      ])
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match chainGuard "audit_approvals" cfg args with
    | .error e => pure (errResult "bad_request" e)
    | .ok _ => daemonCall cfg "daemon.approvals.list" args
}

/-- `check_allowance` — current `allowance(owner, spender)` for one token.
    Builds the calldata in Lean, routes through `chain.ethCall`, decodes
    the uint256 result, and flags the unlimited sentinel. -/
def checkAllowance : ToolDecl := {
  name := "check_allowance",
  description :=
    "Read the current ERC-20 allowance(owner, spender) for one token — i.e. \
     how much `spender` may pull of `token` from `owner`. Use this for a \
     SPECIFIC pair (e.g. 'how much USDC has X approved Y for'); use \
     audit_approvals to discover allowances you don't already know the \
     spender of. All three addresses must be 0x (resolve names first). \
     Returns {allowance:<decimal string>, allowanceHex, unlimited:<bool>}. \
     Read-only.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "chainId", .str "token", .str "owner", .str "spender"]),
    ("properties", .obj #[
      ("chainId", .obj #[("type", .str "integer")]),
      ("token",   .obj #[("type", .str "string"),
        ("description", .str "ERC-20 contract address (0x).")]),
      ("owner",   .obj #[("type", .str "string"),
        ("description", .str "Address that granted the approval (0x).")]),
      ("spender", .obj #[("type", .str "string"),
        ("description", .str "Address allowed to spend (0x).")])
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match chainGuard "check_allowance" cfg args with
    | .error e => pure (errResult "bad_request" e)
    | .ok chainId =>
      let some token := getField "token" args >>= asString
        | pure (errResult "bad_request" "check_allowance: missing 'token'")
      let some owner := getField "owner" args >>= asString
        | pure (errResult "bad_request" "check_allowance: missing 'owner'")
      let some spender := getField "spender" args >>= asString
        | pure (errResult "bad_request" "check_allowance: missing 'spender'")
      match encodeAddrWord owner, encodeAddrWord spender with
      | none, _ =>
          pure (errResult "bad_address"
            s!"check_allowance: 'owner' is not a 0x 20-byte address: {owner}")
      | _, none =>
          pure (errResult "bad_address"
            s!"check_allowance: 'spender' is not a 0x 20-byte address: {spender}")
      | some ownerWord, some spenderWord =>
          let data := selAllowance ++ ownerWord ++ spenderWord
          let callParams : Json := .obj #[
            ("chainId", .num (Int.ofNat chainId)),
            ("to",      .str token),
            ("data",    .str data)
          ]
          let res ← daemonCall cfg "chain.ethCall" callParams
          if ¬ res.ok then
            pure res
          else
            match getField "returnData" res.data >>= asString with
            | none =>
                pure (errResult "bad_response"
                  "check_allowance: chain.ethCall returned no returnData")
            | some retHex =>
                match Numeric.hexToNat retHex with
                | none =>
                    pure (errResult "bad_response"
                      s!"check_allowance: allowance() returned malformed data: {retHex}")
                | some amt =>
                    let unlimited := amt = maxUint256
                    pure {
                      ok := true,
                      data := .obj #[
                        ("allowance",    .str (toString amt)),
                        ("allowanceHex", .str retHex),
                        ("unlimited",    .bool unlimited)
                      ],
                      summary := some
                        (if unlimited then
                          s!"{owner} → {spender}: UNLIMITED allowance"
                         else
                          s!"{owner} → {spender}: allowance {amt}")
                    }
}

/-- Selector for `approve(address,uint256)`. -/
private def selApprove : String := "0x095ea7b3"

/-- Parse a non-empty ASCII decimal string into a `Nat`. -/
private def parseDecNat (s : String) : Option Nat := Id.run do
  if s.isEmpty then return none
  let mut acc : Nat := 0
  for c in s.toList do
    if '0' ≤ c ∧ c ≤ '9' then acc := acc * 10 + (c.toNat - '0'.toNat)
    else return none
  return some acc

/-- Approve amount: a base-units decimal string, `"max"`/`"MAX"` (the
`2^256-1` unlimited sentinel), or a `0x`-hex quantity. -/
private def parseAmount (s : String) : Option Nat :=
  match s.toLower with
  | "max" => some maxUint256
  | t =>
      if t.startsWith "0x" then Numeric.hexToNat t else parseDecNat s

/-- Left-pad a `Nat` to a 32-byte ABI word (64 lowercase hex, no `0x`).
`none` if it exceeds `uint256`. -/
private def uint256Word (n : Nat) : Option String :=
  let body := ((Numeric.natToHex n).drop 2).toString  -- strip the 0x
  if body.length > 64 then none
  else some (String.ofList (List.replicate (64 - body.length) '0') ++ body)

/-- `prepare_erc20_approve` — build the approve calldata daemon-side so the
    model never hand-lays the address/amount words (where a transposed
    nibble silently approves the wrong spender). -/
def prepareErc20Approve : ToolDecl := {
  name := "prepare_erc20_approve",
  description :=
    "Build an ERC-20 approve(spender, amount) transaction. The encoder lays \
     out the calldata for you so you NEVER hand-write the address/amount \
     words — a single transposed nibble there silently approves a DIFFERENT \
     spender, and neither the user nor simulate can catch it. Provide \
     chainId, token (0x), spender (0x — resolve names via slot_lookup FIRST, \
     never retype an address from memory), and amount as a base-units decimal \
     string (or \"max\" for unlimited). Returns {status:\"ready\", \
     action:{to,value,data,chainId}}; pass action.to/value/data/chainId \
     verbatim to propose_send (include the owner as propose_send's sender). \
     Read-only; signing still terminates at ConfirmGate.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "chainId", .str "token", .str "spender"]),
    ("properties", .obj #[
      ("chainId", .obj #[("type", .str "integer")]),
      ("token",   .obj #[("type", .str "string"),
        ("description", .str "ERC-20 contract address (0x).")]),
      ("spender", .obj #[("type", .str "string"),
        ("description", .str "Address being granted the allowance (0x). Resolve names first.")]),
      ("amountRef", .obj #[("type", .str "string"),
        ("description", .str "PREFERRED: a handle from the `amounts` table (e.g. \"amt1\"). The daemon already converted the user's amount — reference it, never type a magnitude.")]),
      ("amount",  .obj #[("type", .str "string"),
        ("description", .str "Use \"max\" for unlimited approval (a fixed sentinel, always allowed). A concrete magnitude here is REJECTED when an `amounts` table is present — use `amountRef` instead.")])
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match chainGuard "prepare_erc20_approve" cfg args with
    | .error e => pure (errResult "bad_request" e)
    | .ok chainId =>
      let some token := getField "token" args >>= asString
        | pure (errResult "bad_request" "prepare_erc20_approve: missing 'token'")
      let some spender := getField "spender" args >>= asString
        | pure (errResult "bad_request" "prepare_erc20_approve: missing 'spender'")
      -- Allowance amount is Lean's authority. Prefer the `amountRef`
      -- handle; "max"/unlimited is a fixed sentinel (not a model-chosen
      -- magnitude) so it stays a literal. A concrete literal is rejected
      -- when a table is present. No table (one-shot CLI) keeps the legacy
      -- decimal/0x path.
      let amountRes : Except String Nat :=
        match getField "amountRef" args >>= asString with
        | some ref =>
            match findAmount cfg.amountTable ref with
            | some e => .ok e.base
            | none   => .error s!"prepare_erc20_approve: unknown amountRef '{ref}'; reference one from `amounts`"
        | none =>
            match getField "amount" args >>= asString with
            | some s =>
                if s.toLower == "max" then .ok maxUint256
                else if cfg.amountTable.isEmpty then
                  match parseAmount s with
                  | some n => .ok n
                  | none   => .error s!"prepare_erc20_approve: 'amount' is not a decimal/max/0x value: {s}"
                else .error "prepare_erc20_approve: pass the amount via `amountRef` (a handle from `amounts`), or \"max\" for unlimited; do not type a magnitude"
            | none => .error "prepare_erc20_approve: provide `amountRef` (or amount:\"max\" for unlimited)"
      if (encodeAddrWord token).isNone then
        pure (errResult "bad_address"
          s!"prepare_erc20_approve: 'token' is not a 0x 20-byte address: {token}")
      else
      match encodeAddrWord spender, amountRes with
      | none, _ =>
          pure (errResult "bad_address"
            s!"prepare_erc20_approve: 'spender' is not a 0x 20-byte address: {spender}")
      | _, .error e =>
          pure (errResult "bad_amount" e)
      | some spenderWord, .ok amount =>
          match uint256Word amount with
          | none => pure (errResult "bad_amount" "prepare_erc20_approve: 'amount' exceeds uint256")
          | some amountWord =>
              let data := selApprove ++ spenderWord ++ amountWord
              let human := if amount = maxUint256 then "unlimited (max uint256)" else toString amount
              pure {
                ok := true,
                data := .obj #[
                  ("status", .str "ready"),
                  ("action", .obj #[
                    ("to",      .str token),
                    ("value",   .num 0),
                    ("data",    .str data),
                    ("chainId", .num (Int.ofNat chainId))
                  ]),
                  ("summaryForConfirm",
                    .str s!"approve {human} of {token} to spender {spender}")
                ],
                summary := some s!"approve {human} → {spender} (pass action to propose_send)"
              }
}

end LeanCli.Agent.ToolDefs.Approvals
