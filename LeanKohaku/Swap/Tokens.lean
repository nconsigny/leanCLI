/-!
# Token registry for the Uniswap V3 swap surface

A small static registry of tokens we know addresses for on mainnet (and,
where applicable, Sepolia). Lowercase 0x-prefixed addresses; sepolia is
`none` when no canonical or widely-trusted deployment is known to us.
We intentionally omit any token whose address we could not verify.
-/

namespace LeanKohaku.Swap.Tokens

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
  addressMainnet : String
  addressSepolia : Option String
  decimals : Nat
  name : String
  deriving Repr

/-- Static registry. Addresses are lowercase, 0x-prefixed. -/
def registry : List Token := [
  { symbol := "WETH",
    addressMainnet := "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
    addressSepolia := some "0xfff9976782d46cc05630d1f6ebab18b2324d6b14",
    decimals := 18, name := "Wrapped Ether" },
  { symbol := "USDC",
    addressMainnet := "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
    addressSepolia := some "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238",
    decimals := 6, name := "USD Coin" },
  { symbol := "WBTC",
    addressMainnet := "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599",
    addressSepolia := none,
    decimals := 8, name := "Wrapped BTC" },
  { symbol := "stETH",
    addressMainnet := "0xae7ab96520de3a18e5e111b5eaab095312d7fe84",
    addressSepolia := none,
    decimals := 18, name := "Lido Staked Ether" },
  { symbol := "wstETH",
    addressMainnet := "0x7f39c581f595b53c5cb19bd0b3f8da6c935e2ca0",
    addressSepolia := some "0xb82381a3fbd3fafa77b3a7be693342618240067b",
    decimals := 18, name := "Wrapped liquid staked Ether" },
  { symbol := "rETH",
    addressMainnet := "0xae78736cd615f374d3085123a210448e74fc6393",
    addressSepolia := none,
    decimals := 18, name := "Rocket Pool ETH" },
  { symbol := "weETH",
    addressMainnet := "0xcd5fe23c85820f7b72d0926fc9b05b43e359b7ee",
    addressSepolia := none,
    decimals := 18, name := "ether.fi Wrapped ETH" },
  { symbol := "USDe",
    addressMainnet := "0x4c9edd5852cd905f086c759e8383e09bff1e68b3",
    addressSepolia := none,
    decimals := 18, name := "Ethena USDe" },
  { symbol := "fxUSD",
    addressMainnet := "0x085780639cc2cacd35e474e71f4d000e2405d8f6",
    addressSepolia := none,
    decimals := 18, name := "f(x) Protocol fxUSD" },
  -- BOLD (Liquity v2): mainnet address could not be verified with high
  -- confidence at the time of writing; intentionally OMITTED rather than
  -- shipping a wrong address. Add it when a canonical deployment is
  -- confirmed against the Liquity v2 docs.
  { symbol := "AAVE",
    addressMainnet := "0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9",
    addressSepolia := none,
    decimals := 18, name := "Aave Token" },
  { symbol := "MORPHO",
    addressMainnet := "0x58d97b57bb95320f9a05dc918aef65434969c2b2",
    addressSepolia := none,
    decimals := 18, name := "Morpho Token" },
  { symbol := "UNI",
    addressMainnet := "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984",
    addressSepolia := some "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984",
    decimals := 18, name := "Uniswap" },
  { symbol := "ENS",
    addressMainnet := "0xc18360217d8f7ab5e7c516566761ea12ce7f9d72",
    addressSepolia := none,
    decimals := 18, name := "Ethereum Name Service" }
]

/-- Case-insensitive symbol lookup. -/
def findBySymbol (sym : String) : Option Token :=
  let target := sym.toLower
  registry.find? (fun t => t.symbol.toLower = target)

/-- Pick the token's address on the given chain. Returns `none` when no
    canonical deployment is registered for that chain. -/
def addressOn (t : Token) : ChainId → Option String
  | .mainnet => some t.addressMainnet
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

end LeanKohaku.Swap.Tokens
