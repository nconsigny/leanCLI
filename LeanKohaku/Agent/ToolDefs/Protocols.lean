import LeanKohaku.Agent.Tools
import LeanKohaku.Agent.Skills
import LeanKohaku.Encoding.Json

/-!
# Protocol-knowledge lookup tools

Two read-only tools the agent can invoke once a skill has fired:

* `protocol_lookup` — given a skill name, return its overview +
  contracts + function index. Used when the model wants the full
  picture for a protocol whose triggers fired.
* `protocol_function_lookup` — given (skill, function), return the
  function-specific markdown body. Used when the model is drilling
  into a particular call.

Both tools read from a `Skills.Registry` passed in at construction
time. The registry is opened once at agent-daemon startup; the
`reload` op on the daemon socket re-walks it for SIGHUP-equivalent
behaviour (see `docs/PHASE1B_PLAN.md`).

Trust model: identical to the rest of the agent. Skills are
trusted-code-base content; their *consumption* by the LLM does not
relax the pre-sign pipeline. Nothing on this path signs.
-/

namespace LeanKohaku.Agent.ToolDefs.Protocols

open LeanKohaku.Agent
open LeanKohaku.Agent.Tools
open LeanKohaku.Encoding.Json

/-- Reference to the agent-daemon's skill registry. We use an
    `IO.Ref` so a `reload` from the daemon socket can swap a fresh
    registry under both tools at once. The registry itself is
    immutable per snapshot; only the ref is mutated. -/
abbrev RegistryRef := IO.Ref Skills.Registry

/-- Build a `protocol_lookup` tool bound to `regRef`. -/
def protocolLookup (regRef : RegistryRef) : ToolDecl := {
  name := "protocol_lookup",
  description :=
    "Return the canonical knowledge block for a protocol skill by \
     name (e.g. uniswap, aave, railgun, cowswap). Read-only. Use \
     this once a protocol's triggers have fired and you want the \
     full overview, contracts and function index.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "name"]),
    ("properties", .obj #[
      ("name", .obj #[
        ("type", .str "string"),
        ("description", .str "Skill name; matches the directory under skills/")
      ])
    ])
  ],
  classify := .read,
  invoke := fun _cfg args => do
    let some nameJ := getField "name" args
      | pure { ok := false,
               data := .obj #[("error", .str "protocol_lookup: missing required field 'name'")] }
    let some name := asString nameJ
      | pure { ok := false,
               data := .obj #[("error", .str "protocol_lookup: 'name' must be a string")] }
    let reg ← regRef.get
    match Skills.findSkill reg name with
    | none =>
        let known := reg.skills.toList.map (fun s => Json.str s.frontmatter.name)
        pure { ok := false,
               data := .obj #[
                 ("error", .str s!"protocol_lookup: unknown skill '{name}'"),
                 ("known", .arr known.toArray)
               ] }
    | some s =>
        let fnIndex : Array Json := (s.functions.toArray.map fun (n, _) => Json.str n)
        let payload : Json := .obj #[
          ("name",         .str s.frontmatter.name),
          ("version",      .str s.frontmatter.version),
          ("description",  .str s.frontmatter.description),
          ("overview",     .str s.overview),
          ("security",     .str s.security),
          ("interactions", .str s.interactions),
          ("contracts",    s.contracts),
          ("functions",    .arr fnIndex)
        ]
        pure { ok := true, data := payload,
               summary := some s!"skill {s.frontmatter.name} v{s.frontmatter.version}" }
}

/-- Build a `protocol_function_lookup` tool bound to `regRef`. -/
def protocolFunctionLookup (regRef : RegistryRef) : ToolDecl := {
  name := "protocol_function_lookup",
  description :=
    "Return the markdown body for a specific function inside a \
     protocol skill (e.g. uniswap → exactInputSingle). Read-only.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "name", .str "function"]),
    ("properties", .obj #[
      ("name",     .obj #[("type", .str "string")]),
      ("function", .obj #[("type", .str "string")])
    ])
  ],
  classify := .read,
  invoke := fun _cfg args => do
    let some nameJ := getField "name" args
      | pure { ok := false,
               data := .obj #[("error", .str "protocol_function_lookup: missing 'name'")] }
    let some name := asString nameJ
      | pure { ok := false,
               data := .obj #[("error", .str "protocol_function_lookup: 'name' must be a string")] }
    let some fnJ := getField "function" args
      | pure { ok := false,
               data := .obj #[("error", .str "protocol_function_lookup: missing 'function'")] }
    let some fn := asString fnJ
      | pure { ok := false,
               data := .obj #[("error", .str "protocol_function_lookup: 'function' must be a string")] }
    let reg ← regRef.get
    match Skills.findSkill reg name with
    | none =>
        pure { ok := false,
               data := .obj #[("error", .str s!"protocol_function_lookup: unknown skill '{name}'")] }
    | some s =>
        match Skills.findFunction reg name fn with
        | none =>
            let known := s.functions.toArray.map (fun (n, _) => Json.str n)
            pure { ok := false,
                   data := .obj #[
                     ("error", .str s!"protocol_function_lookup: skill '{name}' has no function '{fn}'"),
                     ("known", .arr known)
                   ] }
        | some body =>
            pure { ok := true,
                   data := .obj #[
                     ("name",     .str name),
                     ("function", .str fn),
                     ("body",     .str body)
                   ],
                   summary := some s!"{name}.{fn}" }
}

end LeanKohaku.Agent.ToolDefs.Protocols
