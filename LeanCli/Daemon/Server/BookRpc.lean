import LeanCli.Daemon.Server.Core
import LeanCli.Daemon.Server.Helpers
import LeanCli.Daemon.Server.Endpoints
import LeanCli.Daemon.AddressBook
import LeanCli.Ethereum.Ens
import LeanCli.Keystore.Tpm2Runtime
import LeanCli.RPC.Server

/-!
# Daemon server: `book.*` RPC family

Address-book CRUD. Four methods: `book.list`, `book.add`, `book.remove`,
`book.lookup`. ENS-suffixed addresses in `book.add` are resolved through
the configured `ensRpcEndpoint` (mainnet) before being stored.

First per-family extraction validating the dispatch-by-prefix router
pattern: `Server.lean`'s `methodHandler` routes any `book.*` method to
`BookRpc.dispatch`, and the handler matches on the full method name
internally.
-/

namespace LeanCli.Daemon.Server.BookRpc

open LeanCli.Encoding.Json
open LeanCli.RPC.Server
open LeanCli.Daemon.Server

/-- Handle every `book.*` JSON-RPC method. Returns `methodNotFound` for
    any method outside the family — callers (the prefix-router in
    `Server.methodHandler`) are responsible for only routing matching
    methods here. -/
def dispatch (cfg : Config) (state : LeanCli.Daemon.State.Shared)
    (_notify : LeanCli.Keystore.Tpm2Runtime.Notifier)
    (req : Request) : IO (Except RpcError Json) := do
  match req.method with
  | "book.list" =>
      match ← LeanCli.Daemon.AddressBook.loadIO with
      | .error e => pure <| .error { code := -32020, message := e, data := none }
      | .ok entries =>
          let arr : Array Json := (entries.map (fun e =>
            .obj <| #[
              ("label",   .str e.label),
              ("address", .str e.address),
              ("source",  .str e.source),
              ("addedAt", .num (Int.ofNat e.addedAt))
            ]
            ++ (match e.ensName with | some n => #[("ensName", .str n)] | none => #[])
            ++ (match e.tag     with | some t => #[("tag",     .str t)] | none => #[])
          )).toArray
          pure <| .ok <| .obj #[("entries", .arr arr)]
  | "book.add" =>
      -- params: { label, address, source?, ensName?, tag? }. If address
      -- ends in .eth, daemon resolves it first via the same path
      -- chain.resolveName uses, and stores the resolved 0x address with
      -- ensName populated and source="ens".
      match paramString req.params "label",
            paramString req.params "address" with
      | .ok label, .ok addrOrEns =>
          let isEns := addrOrEns.endsWith ".eth"
          let now ← IO.monoMsNow
          let buildAndSave (resolvedAddr : String) (src : String) (ens? : Option String) : IO (Except String Unit) := do
            match ← LeanCli.Daemon.AddressBook.addIO {
              label := label,
              address := resolvedAddr,
              source := src,
              ensName := ens?,
              tag := getField "tag" req.params >>= asString,
              addedAt := now / 1000
            } with
            | .ok _ => pure (.ok ())
            | .error e => pure (.error e)
          if isEns then
            match cfg.ensRpcEndpoint with
            | none =>
                pure <| .error { code := -32030, message := "no ENS RPC configured; cannot resolve before adding", data := none }
            | some ensEp =>
                let viaEns? ← verifiedReadVia state 1 ensEp
                match ← LeanCli.Ethereum.Ens.resolveIO cfg.policy ensEp 1 addrOrEns viaEns? with
                | .error (code, msg) =>
                    pure <| .error { code := code, message := msg, data := none }
                | .ok r =>
                    match ← buildAndSave r.address "ens" (some addrOrEns) with
                    | .ok () =>
                        pure <| .ok <| .obj #[
                          ("ok", .bool true),
                          ("label", .str label),
                          ("address", .str r.address),
                          ("source", .str "ens"),
                          ("ensName", .str addrOrEns)
                        ]
                    | .error e => pure <| .error { code := -32603, message := e, data := none }
          else
            let src := (paramString req.params "source").toOption.getD "manual"
            match ← buildAndSave addrOrEns src none with
            | .ok () =>
                pure <| .ok <| .obj #[
                  ("ok", .bool true),
                  ("label", .str label),
                  ("address", .str addrOrEns),
                  ("source", .str src)
                ]
            | .error e => pure <| .error { code := -32603, message := e, data := none }
      | .error err, _ => pure (.error err)
      | _, .error err => pure (.error err)
  | "book.remove" =>
      match paramString req.params "label" with
      | .error err => pure (.error err)
      | .ok label =>
          match ← LeanCli.Daemon.AddressBook.removeIO label with
          | .error e => pure <| .error { code := -32603, message := e, data := none }
          | .ok (removed, _) =>
              pure <| .ok <| .obj #[("removed", .bool removed)]
  | "book.lookup" =>
      match paramString req.params "needle" with
      | .error err => pure (.error err)
      | .ok needle =>
          match ← LeanCli.Daemon.AddressBook.lookupIO needle with
          | .error e => pure <| .error { code := -32603, message := e, data := none }
          | .ok none => pure <| .ok <| .obj #[("entry", .null)]
          | .ok (some e) =>
              pure <| .ok <| .obj #[
                ("entry", .obj <| #[
                  ("label",   .str e.label),
                  ("address", .str e.address),
                  ("source",  .str e.source),
                  ("addedAt", .num (Int.ofNat e.addedAt))
                ] ++ (match e.ensName with | some n => #[("ensName", .str n)] | none => #[])
                  ++ (match e.tag     with | some t => #[("tag",     .str t)] | none => #[]))
              ]
  | m =>
      pure <| .error { code := -32601, message := s!"method not found: {m}", data := none }

end LeanCli.Daemon.Server.BookRpc
