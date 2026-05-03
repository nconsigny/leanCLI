/-!
# Network privacy policy

All network-capable wallet code must classify a request before transport
code can send it. The policy is deny-by-default: only explicitly modeled
local daemon, local node, and configured-node traffic can be accepted.
-/

namespace LeanKohaku.Privacy.NetworkPolicy

inductive Peer where
  | localDaemon
  | localNode
  | configuredNode
  | thirdPartyApi
  deriving DecidableEq, Repr

inductive Purpose where
  | daemonControl
  | nodeRead
  | broadcastTx
  | peerDiscovery
  | analytics
  | priceQuote
  | metadataLookup
  | fiatOnramp
  | crashReport
  | shieldedRead
  | shieldedBroadcast
  -- Why: third-party block-explorer / indexer history lookups (e.g.
  -- Etherscan v2 txlist/tokentx). This is a deliberate privacy tradeoff:
  -- the watch-address(es) are leaked to the indexer. Strict policies must
  -- reject this purpose; opt-in only via `indexerEnabled` or `dev`.
  | indexerLookup
  deriving DecidableEq, Repr

inductive Transport where
  | loopback
  | tor
  | direct
  deriving DecidableEq, Repr

structure NetworkRequest where
  peer      : Peer
  purpose   : Purpose
  transport : Transport
  deriving Repr, DecidableEq

def Policy := NetworkRequest → Bool

/-- CLI code may only speak to the local daemon over local transport. -/
def strictCliPolicy : Policy
  | { peer := .localDaemon, purpose := .daemonControl, transport := .loopback } => true
  | _ => false

/--
Default daemon policy:
* local node reads are allowed over loopback;
* transaction broadcast is allowed to a local node over loopback;
* configured-node traffic is denied unless Tor mode is explicitly selected;
* all third-party APIs and metadata-style services are denied.
-/
def strictDaemonPolicy : Policy
  | { peer := .localNode, purpose := .nodeRead, transport := .loopback } => true
  | { peer := .localNode, purpose := .broadcastTx, transport := .loopback } => true
  | _ => false

/--
Tor daemon policy:
* local node traffic remains loopback-only;
* configured-node reads and broadcasts may use Tor;
* direct configured-node reads remain denied.
-/
def torDaemonPolicy : Policy
  | { peer := .localNode, purpose := .nodeRead, transport := .loopback } => true
  | { peer := .localNode, purpose := .broadcastTx, transport := .loopback } => true
  | { peer := .configuredNode, purpose := .nodeRead, transport := .tor } => true
  | { peer := .configuredNode, purpose := .broadcastTx, transport := .tor } => true
  | { peer := .configuredNode, purpose := .shieldedRead, transport := .tor } => true
  | { peer := .configuredNode, purpose := .shieldedBroadcast, transport := .tor } => true
  | _ => false

/--
Dev/testnet policy:
* all local node and configured-node reads and broadcasts are allowed over any transport;
* intended for Sepolia dev only — never use on mainnet.
-/
def devDaemonPolicy : Policy
  | { peer := .localNode, .. } => true
  | { peer := .configuredNode, purpose := .nodeRead, .. } => true
  | { peer := .configuredNode, purpose := .broadcastTx, .. } => true
  | { peer := .configuredNode, purpose := .shieldedRead, .. } => true
  | { peer := .configuredNode, purpose := .shieldedBroadcast, .. } => true
  | _ => false

/--
Indexer-enabled policy: extends `strictDaemonPolicy` with a single
allowed third-party purpose, `indexerLookup`. This is opt-in only — the
user must run `kohaku network allow-indexer <name>` to enable it. Strict
mode never grants this purpose. Privacy tradeoff: the watch-address(es)
are revealed to the indexer.
-/
def indexerEnabledPolicy : Policy
  | { peer := .localNode, purpose := .nodeRead, transport := .loopback } => true
  | { peer := .localNode, purpose := .broadcastTx, transport := .loopback } => true
  | { peer := .thirdPartyApi, purpose := .indexerLookup, .. } => true
  | _ => false

/-- Deny-by-default helper for future features that have not been classified. -/
def denyByDefault : Policy := fun _ => false

def thirdPartyPurpose : Purpose → Bool
  | .peerDiscovery => true
  | .analytics => true
  | .priceQuote => true
  | .metadataLookup => true
  | .fiatOnramp => true
  | .crashReport => true
  | .indexerLookup => true
  | _ => false

def Peer.asString : Peer → String
  | .localDaemon => "local-daemon"
  | .localNode => "local-node"
  | .configuredNode => "configured-node"
  | .thirdPartyApi => "third-party-api"

def Purpose.asString : Purpose → String
  | .daemonControl => "daemon-control"
  | .nodeRead => "node-read"
  | .broadcastTx => "broadcast-tx"
  | .peerDiscovery => "peer-discovery"
  | .analytics => "analytics"
  | .priceQuote => "price-quote"
  | .metadataLookup => "metadata-lookup"
  | .fiatOnramp => "fiat-onramp"
  | .crashReport => "crash-report"
  | .shieldedRead => "shielded-read"
  | .shieldedBroadcast => "shielded-broadcast"
  | .indexerLookup => "indexer-lookup"

def Transport.asString : Transport → String
  | .loopback => "loopback"
  | .tor => "tor"
  | .direct => "direct"

def parsePeer : String → Option Peer
  | "local-daemon" => some .localDaemon
  | "local-node" => some .localNode
  | "configured-node" => some .configuredNode
  | "third-party-api" => some .thirdPartyApi
  | _ => none

def parsePurpose : String → Option Purpose
  | "daemon-control" => some .daemonControl
  | "node-read" => some .nodeRead
  | "broadcast-tx" => some .broadcastTx
  | "peer-discovery" => some .peerDiscovery
  | "analytics" => some .analytics
  | "price-quote" => some .priceQuote
  | "metadata-lookup" => some .metadataLookup
  | "fiat-onramp" => some .fiatOnramp
  | "crash-report" => some .crashReport
  | "shielded-read" => some .shieldedRead
  | "shielded-broadcast" => some .shieldedBroadcast
  | "indexer-lookup" => some .indexerLookup
  | _ => none

def parseTransport : String → Option Transport
  | "loopback" => some .loopback
  | "tor" => some .tor
  | "direct" => some .direct
  | _ => none

def parsePolicy : String → Option Policy
  | "cli" => some strictCliPolicy
  | "strict" => some strictDaemonPolicy
  | "tor" => some torDaemonPolicy
  | "dev" => some devDaemonPolicy
  | "indexer" => some indexerEnabledPolicy
  | "deny" => some denyByDefault
  | _ => none

def policyNames : List String := ["cli", "strict", "tor", "dev", "indexer", "deny"]
def peerNames : List String := ["local-daemon", "local-node", "configured-node", "third-party-api"]
def purposeNames : List String :=
  ["daemon-control", "node-read", "broadcast-tx", "peer-discovery", "analytics",
    "price-quote", "metadata-lookup", "fiat-onramp", "crash-report",
    "shielded-read", "shielded-broadcast", "indexer-lookup"]
def transportNames : List String := ["loopback", "tor", "direct"]

end LeanKohaku.Privacy.NetworkPolicy
