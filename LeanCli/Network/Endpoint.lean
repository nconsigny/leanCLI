import LeanCli.Network.Policy

/-!
# Endpoint hygiene

Endpoint configuration is modeled separately from request policy so we can
forbid API-key hosted services and hidden third-party dependencies before
transport code exists.
-/

namespace LeanCli.Network.Endpoint

open LeanCli.Network.Policy

inductive EndpointKind where
  | local
  | configured
  | thirdParty
  deriving DecidableEq, Repr

inductive Scheme where
  | ipc
  | http
  | onion
  deriving DecidableEq, Repr

structure Endpoint where
  kind        : EndpointKind
  scheme      : Scheme
  transport   : Transport
  credentialed : Bool := false
  deriving Repr, DecidableEq

def Endpoint.defaultLocal : Endpoint :=
  { kind := .local, scheme := .http, transport := .loopback, credentialed := false }

def Endpoint.localIpc : Endpoint :=
  { kind := .local, scheme := .ipc, transport := .loopback, credentialed := false }

def Endpoint.configuredTor : Endpoint :=
  { kind := .configured, scheme := .onion, transport := .tor, credentialed := false }

def acceptedStrict : Endpoint → Bool
  | { kind := .local, transport := .loopback, credentialed := false, .. } => true
  | _ => false

def acceptedTor : Endpoint → Bool
  | { kind := .local, transport := .loopback, credentialed := false, .. } => true
  | { kind := .configured, transport := .tor, credentialed := false, .. } => true
  | _ => false

def EndpointKind.asString : EndpointKind → String
  | .local => "local"
  | .configured => "configured"
  | .thirdParty => "third-party"

def Scheme.asString : Scheme → String
  | .ipc => "ipc"
  | .http => "http"
  | .onion => "onion"

def parseEndpointKind : String → Option EndpointKind
  | "local" => some .local
  | "configured" => some .configured
  | "third-party" => some .thirdParty
  | _ => none

def parseScheme : String → Option Scheme
  | "ipc" => some .ipc
  | "http" => some .http
  | "onion" => some .onion
  | _ => none

def parseBool : String → Option Bool
  | "true" => some true
  | "false" => some false
  | _ => none

def kindNames : List String := ["local", "configured", "third-party"]
def schemeNames : List String := ["ipc", "http", "onion"]

end LeanCli.Network.Endpoint
