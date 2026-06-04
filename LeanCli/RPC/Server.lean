import LeanCli.Encoding.Json

/-!
# Inbound JSON-RPC 2.0 server skeleton

This module parses newline-delimited JSON-RPC requests and produces structured
JSON-RPC responses. Transport and daemon method implementations live above this
layer.
-/

namespace LeanCli.RPC.Server

open LeanCli.Encoding.Json

structure Request where
  method : String
  params : Json
  id     : Json
  deriving Repr

structure RpcError where
  code    : Int
  message : String
  data    : Option Json := none
  deriving Repr

def parseError : RpcError := { code := -32700, message := "Parse error" }
def invalidRequest : RpcError := { code := -32600, message := "Invalid Request" }
def methodNotFound : RpcError := { code := -32601, message := "Method not found" }
def invalidParams : RpcError := { code := -32602, message := "Invalid params" }
def internalError : RpcError := { code := -32603, message := "Internal error" }

def errorJson (err : RpcError) : Json :=
  let base := #[
    ("code", .num err.code),
    ("message", .str err.message)
  ]
  match err.data with
  | none => .obj base
  | some data => .obj (base.push ("data", data))

def successResponse (id result : Json) : Json :=
  .obj #[
    ("jsonrpc", .str "2.0"),
    ("result", result),
    ("id", id)
  ]

def errorResponse (id : Json) (err : RpcError) : Json :=
  .obj #[
    ("jsonrpc", .str "2.0"),
    ("error", errorJson err),
    ("id", id)
  ]

def parseRequestJson : Json → Except RpcError Request
  | .obj fields =>
      let obj := Json.obj fields
      match getField "jsonrpc" obj, getField "method" obj, getField "params" obj, getField "id" obj with
      | some (.str "2.0"), some (.str method), some params, some id =>
          .ok { method := method, params := params, id := id }
      | some (.str "2.0"), some (.str method), none, some id =>
          .ok { method := method, params := .arr #[], id := id }
      | _, _, _, _ => .error invalidRequest
  | _ => .error invalidRequest

def parseRequest (line : String) : Except RpcError Request := do
    match parse line with
  | .error err => .error { parseError with data := some (.str err) }
  | .ok json => parseRequestJson json

abbrev Handler := Request → IO (Except RpcError Json)

def dispatch (handler : Handler) (req : Request) : IO Json := do
  match ← handler req with
  | .ok result => pure (successResponse req.id result)
  | .error err => pure (errorResponse req.id err)

def handleLine (handler : Handler) (line : String) : IO String := do
  let response ←
    match parseRequest line with
    | .error err => pure (errorResponse .null err)
    | .ok req => dispatch handler req
  pure (compact response)

end LeanCli.RPC.Server
