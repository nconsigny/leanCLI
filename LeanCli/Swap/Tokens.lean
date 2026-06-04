/-!
# Token registry for the Uniswap V3 swap surface

A small static registry of tokens we know addresses for on mainnet (and,
where applicable, Sepolia). Lowercase 0x-prefixed addresses; sepolia is
`none` when no canonical or widely-trusted deployment is known to us.
We intentionally omit any token whose address we could not verify.
-/

namespace LeanCli.Swap.Tokens

inductive ChainId where
  | mainnet
  | sepolia
  deriving Repr, DecidableEq

def ChainId.toNat : ChainId → Nat
  | .mainnet => 1
  | .sepolia => 11155111

def ChainId.fromString? (s : String) : Option ChainId :=
  match s.toLower with
  | "mainnet"    => some .mainnet
  | "1"          => some .mainnet
  | "sepolia"    => some .sepolia
  | "11155111"   => some .sepolia
  | _            => none

structure Token where
  symbol : String
  /-- Mainnet (chainId 1) deployment, when one exists. `none` is used
  for tokens we deliberately do NOT track on mainnet — e.g. when the
  mainnet deployment exists but the wallet's curators do not want to
  surface it from the chat path. Lookups on `.mainnet` return `none`
  in that case and `token_lookup` answers `unknown_token`. -/
  addressMainnet : Option String
  addressSepolia : Option String
  decimals : Nat
  name : String
  deriving Repr

/-- Static registry. Addresses are lowercase, 0x-prefixed.
    Order: most CROPS (credibly neutral, decentralised, EF-aligned) at
    the top, least CROPS at the bottom. Native ETH is prepended by the
    daemon's balances handler, so this list starts at WETH. -/
def registry : List Token := [
  { symbol := "WETH",
    addressMainnet := some "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
    addressSepolia := some "0xfff9976782d46cc05630d1f6ebab18b2324d6b14",
    decimals := 18, name := "Wrapped Ether" },
  { symbol := "fxUSD",
    addressMainnet := some "0x085780639cc2cacd35e474e71f4d000e2405d8f6",
    -- f(x) Protocol's `fx-protocol-contracts` broadcast/ directory only
    -- carries chainId 1 (mainnet); the gitbook contracts page lists
    -- mainnet chains exclusively. No canonical Sepolia deployment found
    -- — leave `none` rather than guess.
    addressSepolia := none,
    decimals := 18, name := "f(x) Protocol fxUSD" },
  { symbol := "BOLD",
    -- Current Liquity v2 BOLD on mainnet. Etherscan labels the older
    -- 0xb01dd87B…F3D9aB98 as "Old Bold Token"; the deployer-2 deployment
    -- below is the canonical one in production.
    addressMainnet := some "0x6440f144b7e50d6a8439336510312d2f54beb01d",
    -- Sepolia BOLD as listed in Liquity's docs "technical-resources"
    -- page; source-verified on Sepolia Etherscan as
    -- "Bold Stablecoin" (18 decimals). Refresh if Liquity rotates the
    -- testnet deployment.
    addressSepolia := some "0x620ce1130f7c63457784cdfa31cfccbfb6be5029",
    decimals := 18, name := "Liquity BOLD" },
  { symbol := "MORPHO",
    addressMainnet := some "0x58d97b57bb95320f9a05dc918aef65434969c2b2",
    addressSepolia := none,
    decimals := 18, name := "Morpho Token" },
  { symbol := "ENS",
    addressMainnet := some "0xc18360217d8f7ab5e7c516566761ea12ce7f9d72",
    addressSepolia := none,
    decimals := 18, name := "Ethereum Name Service" },
  { symbol := "AAVE",
    addressMainnet := some "0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9",
    addressSepolia := none,
    decimals := 18, name := "Aave Token" },
  { symbol := "UNI",
    addressMainnet := some "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984",
    addressSepolia := some "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984",
    decimals := 18, name := "Uniswap" },
  { symbol := "rETH",
    addressMainnet := some "0xae78736cd615f374d3085123a210448e74fc6393",
    addressSepolia := none,
    decimals := 18, name := "Rocket Pool ETH" },
  { symbol := "wstETH",
    addressMainnet := some "0x7f39c581f595b53c5cb19bd0b3f8da6c935e2ca0",
    addressSepolia := some "0xb82381a3fbd3fafa77b3a7be693342618240067b",
    decimals := 18, name := "Wrapped liquid staked Ether" },
  { symbol := "stETH",
    addressMainnet := some "0xae7ab96520de3a18e5e111b5eaab095312d7fe84",
    addressSepolia := none,
    decimals := 18, name := "Lido Staked Ether" },
  { symbol := "crvUSD",
    -- Curve.Fi USD Stablecoin (crvUSD) on mainnet. Source-verified on
    -- Etherscan (Vyper 0.3.7), 18 decimals.
    addressMainnet := some "0xf939e0a03fb07f59a73314e73794be0e57ac1b4e",
    -- Curve's old `deployment-logs/sepolia-test.log` (referenced by
    -- third-party coverage) is no longer reachable, and the current
    -- docs list no Sepolia deployment. Leave `none` rather than guess.
    addressSepolia := none,
    decimals := 18, name := "Curve.Fi USD Stablecoin" },
  { symbol := "DAI",
    addressMainnet := some "0x6b175474e89094c44da98b954eedeac495271d0f",
    -- Sky/MakerDAO does not publish a canonical Sepolia DAI in the
    -- on-chain chainlog or current docs. Various third-party "Dai
    -- Stablecoin" test deployments exist on Sepolia (e.g.
    -- 0x3e622317…c620c5d6) but none are issuer-blessed — leave `none`.
    addressSepolia := none,
    decimals := 18, name := "Dai Stablecoin" },
  { symbol := "WBTC",
    addressMainnet := some "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599",
    addressSepolia := none,
    decimals := 8, name := "Wrapped BTC" },
  { symbol := "USDC",
    -- Mainnet USDC deliberately omitted at curator request — chat
    -- path can still resolve testnet USDC via the Sepolia entry, and
    -- a user wanting mainnet USDC can paste the raw 0x address.
    addressMainnet := none,
    addressSepolia := some "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238",
    decimals := 6, name := "USD Coin" },
  { symbol := "USDT",
    -- Mainnet USDT deliberately omitted at curator request. No
    -- canonical Sepolia USDT exists either, but the entry is kept so
    -- the symbol can be added later without re-tracing the registry.
    addressMainnet := none,
    addressSepolia := none,
    decimals := 6, name := "Tether USD" },
  { symbol := "GHO",
    addressMainnet := some "0x40d16fc0246ad3160ccc09b8d0d3a2cd28ae6c2f",
    addressSepolia := some "0xc4bf5cbdabe595361438f8c6a187bdc330539c60",
    decimals := 18, name := "GHO Stablecoin" },
  { symbol := "CRV",
    addressMainnet := some "0xd533a949740bb3306d119cc777fa900ba034cd52",
    addressSepolia := none,
    decimals := 18, name := "Curve DAO Token" },
  { symbol := "LUSD",
    addressMainnet := some "0x5f98805a4e8be255a32880fdec7f6728c6568ba0",
    addressSepolia := none,
    decimals := 18, name := "Liquity USD" },
  { symbol := "cbETH",
    addressMainnet := some "0xbe9895146f7af43049ca1c1ae358b0541ea49704",
    addressSepolia := none,
    decimals := 18, name := "Coinbase Wrapped Staked ETH" },
  { symbol := "sDAI",
    addressMainnet := some "0x83f20f44975d03b1b09e64809b757c47f942beea",
    addressSepolia := none,
    decimals := 18, name := "Savings DAI" },
  { symbol := "USDS",
    -- Sky's new DAI-successor stablecoin.
    addressMainnet := some "0xdc035d45d973e3ec169d2276ddab16f1e407384f",
    addressSepolia := none,
    decimals := 18, name := "Sky USDS" }
]

/-- Disambiguate user-typed token variations into a canonical symbol
the registry can find.

Today's chain coverage is mainnet + sepolia, where there is exactly
one USDC and exactly one DAI; the L2-bridged variants (`USDC.e`,
`USDC-bridged`, `DAI.e`) don't have separate registry entries because
we don't track L2 addresses yet. Mapping them to the canonical
mainnet/sepolia symbol lets the chat path resolve the user's intent
to the closest-thing-on-the-target-chain rather than failing with
`unknown asset`.

When (and only when) we extend `Token` to carry per-L2 addresses,
this function will route to L2-specific variants per chain.

Other normalisations:
* `eth` ↔ `weth` — the chat path treats native ETH and WETH as
  near-equivalents; the *caller* (matcher / encoder) decides whether
  the operation is native (use ETH semantics) or wrapped (encode
  against WETH).
* `eth2` / `eth_2.0` / `eth-staking` → `ETH` (rare in user prompts
  but cheap to handle). -/
def disambiguateSymbol (sym : String) : String :=
  let s := sym.toLower
  if s = "usdc.e" || s = "usdc-e" || s = "bridged-usdc" || s = "usdc.bridged" then
    "USDC"
  else if s = "dai.e" || s = "dai-bridged" then
    "DAI"
  else if s = "weth.e" then
    "WETH"
  else if s = "eth2" || s = "eth_2.0" || s = "eth-staking" then
    "ETH"
  else
    sym

/-- Case-insensitive symbol lookup with `disambiguateSymbol` applied. -/
def findBySymbol (sym : String) : Option Token :=
  let target := (disambiguateSymbol sym).toLower
  registry.find? (fun t => t.symbol.toLower = target)

/-- Pick the token's address on the given chain. Returns `none` when no
    canonical deployment is registered for that chain. -/
def addressOn (t : Token) : ChainId → Option String
  | .mainnet => t.addressMainnet
  | .sepolia => t.addressSepolia

/-- Resolve a CLI / RPC string that is either a registered symbol, the
    pseudo-symbol `"ETH"` (mapped to `WETH`), or a 0x-prefixed address.
    Returns the token (when the input is a symbol) plus the resolved
    on-chain address. -/
def resolve (input : String) (chain : ChainId) :
    Option (Option Token × String) :=
  let s := input.trimAscii.toString
  if s.startsWith "0x" || s.startsWith "0X" then
    some (none, s.toLower)
  else
    let sym := if s.toLower = "eth" then "WETH" else s
    match findBySymbol sym with
    | some t => (addressOn t chain).map (fun a => (some t, a))
    | none => none

end LeanCli.Swap.Tokens
