import LeanKohaku.Privacy.NetworkPolicy

/-!
# Provider/network operation model

This module is intentionally transport-only. It does not implement HTTP,
WebSockets, discovery, API keys, indexers, or analytics. It classifies the
small set of Ethereum JSON-RPC methods the wallet may eventually need.
-/

namespace LeanKohaku.Network.Provider

open LeanKohaku.Privacy.NetworkPolicy

inductive Backend where
  | localNode
  | lightClient
  | configuredNode
  deriving DecidableEq, Repr

inductive RpcMethod where
  | chainId
  | blockNumber
  | getBalance
  | getTransactionCount
  | getCode
  | call
  | estimateGas
  | gasPrice
  | maxPriorityFeePerGas
  | sendRawTransaction
  | getTransactionReceipt
  | getLogs
  deriving DecidableEq, Repr

def RpcMethod.asString : RpcMethod → String
  | .chainId => "eth_chainId"
  | .blockNumber => "eth_blockNumber"
  | .getBalance => "eth_getBalance"
  | .getTransactionCount => "eth_getTransactionCount"
  | .getCode => "eth_getCode"
  | .call => "eth_call"
  | .estimateGas => "eth_estimateGas"
  | .gasPrice => "eth_gasPrice"
  | .maxPriorityFeePerGas => "eth_maxPriorityFeePerGas"
  | .sendRawTransaction => "eth_sendRawTransaction"
  | .getTransactionReceipt => "eth_getTransactionReceipt"
  | .getLogs => "eth_getLogs"

def Backend.asString : Backend → String
  | .localNode => "local"
  | .lightClient => "light"
  | .configuredNode => "configured"

def RpcMethod.purpose : RpcMethod → Purpose
  | .sendRawTransaction => .broadcastTx
  | _ => .nodeRead

structure Config where
  backend   : Backend
  transport : Transport
  deriving Repr, DecidableEq

def Config.local : Config := { backend := .localNode, transport := .loopback }
def Config.lightClient : Config := { backend := .lightClient, transport := .loopback }
def Config.torConfigured : Config := { backend := .configuredNode, transport := .tor }

structure Operation where
  method : RpcMethod
  params : List String := []
  deriving Repr, DecidableEq

def peerFor (cfg : Config) : Peer :=
  match cfg.backend with
  | .localNode => .localNode
  | .lightClient => .localNode
  | .configuredNode => .configuredNode

def requestFor (cfg : Config) (op : Operation) : NetworkRequest :=
  { peer := peerFor cfg, purpose := op.method.purpose, transport := cfg.transport }

def permitted (policy : Policy) (cfg : Config) (op : Operation) : Bool :=
  policy (requestFor cfg op)

def parseBackend : String → Option Backend
  | "local" => some .localNode
  | "light" => some .lightClient
  | "configured" => some .configuredNode
  | _ => none

def parseRpcMethod : String → Option RpcMethod
  | "eth_chainId" => some .chainId
  | "eth_blockNumber" => some .blockNumber
  | "eth_getBalance" => some .getBalance
  | "eth_getTransactionCount" => some .getTransactionCount
  | "eth_getCode" => some .getCode
  | "eth_call" => some .call
  | "eth_estimateGas" => some .estimateGas
  | "eth_gasPrice" => some .gasPrice
  | "eth_maxPriorityFeePerGas" => some .maxPriorityFeePerGas
  | "eth_sendRawTransaction" => some .sendRawTransaction
  | "eth_getTransactionReceipt" => some .getTransactionReceipt
  | "eth_getLogs" => some .getLogs
  | _ => none

def backendNames : List String := ["local", "light", "configured"]

def rpcMethodNames : List String :=
  ["eth_chainId", "eth_blockNumber", "eth_getBalance", "eth_getTransactionCount",
    "eth_getCode", "eth_call", "eth_estimateGas", "eth_gasPrice",
    "eth_maxPriorityFeePerGas", "eth_sendRawTransaction",
    "eth_getTransactionReceipt", "eth_getLogs"]

end LeanKohaku.Network.Provider
