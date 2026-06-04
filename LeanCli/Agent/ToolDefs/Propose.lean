import LeanCli.Agent.Tools
import LeanCli.Encoding.Json

/-!
# `propose_send` tool

The agent's final-answer shape for any transaction. **Never signs.**
**Never broadcasts.** Packages a `{to, value, data, chainId}` proposal
and returns it as a tool result; the upstream consumer
(`LeanCli.LlmAgent.Bridge` → `chat.draft` → `SendRawFlow`) walks
the user through the standard decode → simulate → ConfirmGate → sign
pipeline.

The trust separation is the load-bearing property of Phase 0: the
agent can recommend a transaction, but only the human at the
ConfirmGate can authorize it.
-/

namespace LeanCli.Agent.ToolDefs.Propose

open LeanCli.Agent
open LeanCli.Agent.Tools
open LeanCli.Encoding.Json

private def isHexString (s : String) : Bool :=
  s.startsWith "0x" &&
    (s.toList.drop 2).all (fun c =>
      c.isDigit || ('a' ≤ c ∧ c ≤ 'f') || ('A' ≤ c ∧ c ≤ 'F'))

private def is0x40 (s : String) : Bool :=
  isHexString s && s.length = 42 -- 0x + 40 hex chars (20 bytes)

private def validateArgs (cfg : AgentConfig) (args : Json) :
    Except String (Nat × String × Nat × String × Option String) := do
  let some chainJ := getField "chainId" args
    | .error "propose_send: missing 'chainId'"
  let some chainId := asNat chainJ
    | .error "propose_send: 'chainId' must be a non-negative integer"
  if !cfg.chainWhitelist.contains chainId then
    .error s!"propose_send: chainId {chainId} not in whitelist"
  else
  let some toJ := getField "to" args
    | .error "propose_send: missing 'to'"
  let some toStr := asString toJ
    | .error "propose_send: 'to' must be a string"
  if !is0x40 toStr then
    .error s!"propose_send: 'to' is not a 20-byte address: {toStr}"
  else
  let valueNat : Nat :=
    match getField "value" args with
    | some j => (asNat j).getD 0
    | none => 0
  let dataStr : String :=
    match getField "data" args with
    | some (.str s) => s
    | _ => "0x"
  if !isHexString dataStr then
    .error s!"propose_send: 'data' is not 0x-hex: {dataStr}"
  else
  -- Optional `sender` (a.k.a. "from"): when the agent already knows
  -- which wallet should sign, it should include this so the TUI's
  -- SendRawFlow can skip the wallet picker. Address-shaped; rejected
  -- if malformed rather than silently dropped so a typo is loud.
  let senderOpt : Except String (Option String) :=
    match getField "sender" args with
    | none => .ok none
    | some (.str "") => .ok none
    | some j =>
        match asString j with
        | some s =>
            if is0x40 s then .ok (some s)
            else .error s!"propose_send: 'sender' is not a 20-byte address: {s}"
        | none => .error "propose_send: 'sender' must be a string"
  match senderOpt with
  | .error e => .error e
  | .ok senderField =>
    .ok (chainId, toStr, valueNat, dataStr, senderField)

/-- `propose_send` — returns a draft transaction payload to the
    caller. This tool *never* contacts the daemon: it packages the
    arguments and emits them so the consumer can route the user
    through the standard pre-sign pipeline. -/
def proposeSend : ToolDecl := {
  name := "propose_send",
  description :=
    "Final-answer tool for a transaction. Returns the draft \
     {to, value, data, chainId} payload for the caller to send \
     through the standard decode → simulate → ConfirmGate → sign \
     pipeline. NEVER signs, NEVER broadcasts.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "chainId", .str "to"]),
    ("properties", .obj #[
      ("chainId", .obj #[("type", .str "integer")]),
      ("to",      .obj #[("type", .str "string"),
                         ("description", .str "20-byte 0x-prefixed address")]),
      ("value",   .obj #[("type", .str "integer"),
                         ("description", .str "Wei. Defaults to 0.")]),
      ("data",    .obj #[("type", .str "string"),
                         ("description", .str "0x-hex calldata. Defaults to 0x.")]),
      ("sender",  .obj #[("type", .str "string"),
                         ("description",
                           .str "OPTIONAL 20-byte 0x-prefixed address of the wallet that should sign. When set, the TUI skips the wallet picker. Always include this when slot_lookup resolved the sender for the user.")])
    ])
  ],
  classify := .propose,
  invoke := fun cfg args => do
    match validateArgs cfg args with
    | .error e => pure { ok := false, data := .obj #[("error", .str e)] }
    | .ok (chainId, to, valueNat, dataStr, senderOpt) =>
        let senderField : Array (String × Json) :=
          match senderOpt with
          | some s => #[("sender", .str s)]
          | none   => #[]
        let payload : Json := .obj <| #[
          ("kind",    .str "propose_send"),
          ("chainId", .num (Int.ofNat chainId)),
          ("to",      .str to),
          ("value",   .num (Int.ofNat valueNat)),
          ("data",    .str dataStr)
        ] ++ senderField
        let summaryText :=
          match senderOpt with
          | some s => s!"draft tx → {to} (chain {chainId}, value {valueNat} wei, signer {s})"
          | none   => s!"draft tx → {to} (chain {chainId}, value {valueNat} wei)"
        pure {
          ok := true,
          data := payload,
          summary := some summaryText
        }
}

end LeanCli.Agent.ToolDefs.Propose
