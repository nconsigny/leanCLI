import LeanCli.Daemon.Server.Core
import LeanCli.Daemon.Server.Helpers
import LeanCli.Daemon.Server.Endpoints
import LeanCli.Daemon.State
import LeanCli.Ethereum.Address
import LeanCli.Invariants.Swap
import LeanCli.Keystore.Tpm2Runtime
import LeanCli.RPC.Outbound
import LeanCli.RPC.Server
import LeanCli.Swap.Prepare
import LeanCli.Swap.Tokens
import LeanCli.Swap.UniV3

/-!
# Daemon server: `swap.*` RPC family

Five methods for the Uniswap V3 swap flow:
  swap.tokens.list, swap.balances, swap.uniV3.quote, swap.uniV3.build,
  swap.prepareUniswapV3

All chain reads route through `RPC.Outbound.ethCall` (policy-gated);
calldata produced by `swap.uniV3.build` / `swap.prepareUniswapV3`
still flows through `decodeIntent → simulate → ConfirmGate` before
any signature.
-/

namespace LeanCli.Daemon.Server.SwapRpc

open LeanCli.Encoding.Json
open LeanCli.RPC.Server
open LeanCli.Daemon.Server

/-- Handle every `swap.*` JSON-RPC method. Returns `methodNotFound` for
    any method outside the family. -/
def dispatch (cfg : Config) (state : LeanCli.Daemon.State.Shared)
    (_notify : LeanCli.Keystore.Tpm2Runtime.Notifier)
    (req : Request) : IO (Except RpcError Json) := do
  match req.method with
  | "swap.tokens.list" =>
      -- Read-only exposure of `LeanCli.Swap.Tokens.registry` filtered by
      -- the requested chain. The TUI consumes this so it does not duplicate
      -- the registry in TypeScript. No policy gate: the data is static and
      -- contains nothing chain-derived.
      let chainStr := paramStringD req.params "chainId" "mainnet"
      match LeanCli.Swap.Tokens.ChainId.fromString? chainStr with
      | none =>
          pure <| .error { code := -32602,
                           message := "unknown chainId for swap.tokens.list",
                           data := some (.str chainStr) }
      | some chainId =>
          let mut entries : Array Json := #[]
          for t in LeanCli.Swap.Tokens.registry do
            match LeanCli.Swap.Tokens.addressOn t chainId with
            | some addr =>
                entries := entries.push <| .obj #[
                  ("symbol",   .str t.symbol),
                  ("name",     .str t.name),
                  ("address",  .str addr),
                  ("decimals", .num (Int.ofNat t.decimals))
                ]
            | none => pure ()
          pure <| .ok <| .obj #[
            ("chainId", .num (Int.ofNat chainId.toNat)),
            ("tokens",  .arr entries)
          ]
  | "swap.balances" =>
      -- Why: fan out ERC-20 `balanceOf` + native `eth_getBalance` across the
      -- swap registry filtered by chain. This is the data source for the
      -- TUI swap from-picker (per-token balance column) and the
      -- `leancli balances` CLI command. Concurrency is load-bearing: a
      -- sequential loop over ~10 tokens against a public RPC adds ~1s of
      -- wall time. We spawn one `IO.asTask` per call and join them so the
      -- whole response is bounded by the slowest single eth_call.
      --
      -- Trust model: balance reads are policy-gated by `Outbound.*`; the
      -- response is render-only data. `via? := none` is intentional —
      -- balance fan-out goes direct RPC to keep latency predictable and
      -- avoid serializing through Colibri's UDS for every token.
      --
      -- Fail-soft: a single token whose `balanceOf` reverts (rare, e.g.
      -- self-destructed contract) is silently dropped from the response,
      -- mirroring the trace tokenMeta prefetch policy. Other tokens still
      -- appear. ETH balance failure causes the whole call to error, since
      -- a valid address should always have a queryable native balance.
      let chainStr := paramStringD req.params "chainId" "mainnet"
      match LeanCli.Swap.Tokens.ChainId.fromString? chainStr with
      | none =>
          pure <| .error { code := -32602,
                           message := "unknown chainId for swap.balances",
                           data := some (.str chainStr) }
      | some chainId =>
          match paramString req.params "address" with
          | .error err => pure (.error err)
          | .ok address =>
              match LeanCli.Ethereum.Address.fromHex address with
              | none => pure (.error invalidParams)
              | some ownerAddr =>
                  let chainName : String :=
                    match chainId with | .mainnet => "mainnet" | .sepolia => "sepolia"
                  match endpointForChain cfg (some chainName) with
                  | .error err =>
                      pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
                  | .ok ep =>
                      -- Route ALL balance reads through the active verifier
                      -- (helios/colibri) — no direct bypass. The verified
                      -- client is a single serial UDS connection, so we read
                      -- SEQUENTIALLY (the old concurrent IO.asTask fan-out
                      -- would interleave on that one conn and corrupt the
                      -- wire). Slower than the burst, but every balance is
                      -- verified; balance-poll frequency is cut on the TUI
                      -- side to keep the sequential cost bounded, and token
                      -- discovery only runs on the wallet-hub screen.
                      let via? ← verifiedReadVia state chainId.toNat ep
                      let calldata := erc20BalanceOfData ownerAddr
                      let candidates :
                          List (LeanCli.Swap.Tokens.Token × String) :=
                        LeanCli.Invariants.Swap.balancesCandidates chainId
                      match ← LeanCli.RPC.Outbound.getBalance cfg.policy ep address "latest" via? with
                      | .error err =>
                          pure <| .error { code := -32020,
                                           message := "chain RPC failed (eth balance)",
                                           data := some (.str err) }
                      | .ok ethBal =>
                          let mut entries : Array Json := #[
                            .obj #[
                              ("symbol",   .str "ETH"),
                              ("name",     .str "Ether"),
                              ("address",  .null),
                              ("decimals", .num 18),
                              ("balance",  ethBal)
                            ]
                          ]
                          for (t, addr) in candidates do
                            match ← LeanCli.RPC.Outbound.ethCall cfg.policy ep addr calldata "latest" via? with
                            | .ok bal =>
                                entries := entries.push <| .obj #[
                                  ("symbol",   .str t.symbol),
                                  ("name",     .str t.name),
                                  ("address",  .str addr),
                                  ("decimals", .num (Int.ofNat t.decimals)),
                                  ("balance",  bal)
                                ]
                            | _ => pure ()
                          pure <| .ok <| .obj #[
                            ("chain",    .str chainName),
                            ("chainId",  .num (Int.ofNat chainId.toNat)),
                            ("address",  .str address),
                            ("balances", .arr entries)
                          ]
  | "swap.uniV3.quote" =>
      -- Why: try fee tiers [500, 3000, 10000] via QuoterV2.quoteExactInputSingle
      -- and return the first (and largest amountOut) that doesn't revert.
      let chainStr := paramStringD req.params "chainId" "mainnet"
      match LeanCli.Swap.Tokens.ChainId.fromString? chainStr with
      | none => pure <| .error { code := -32602, message := "unknown chainId for swap.uniV3.quote", data := some (.str chainStr) }
      | some chainId =>
          let chainName : String :=
            match chainId with | .mainnet => "mainnet" | .sepolia => "sepolia"
          match endpointForChain cfg (some chainName) with
          | .error err => pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
          | .ok ep =>
              match paramString req.params "tokenIn", paramString req.params "tokenOut", getField "amountIn" req.params >>= asNat with
              | .ok tinRaw, .ok toutRaw, some amountIn =>
                  match LeanCli.Swap.Tokens.resolve tinRaw chainId, LeanCli.Swap.Tokens.resolve toutRaw chainId with
                  | some (_, tinAddr), some (_, toutAddr) =>
                      let quoter := LeanCli.Swap.UniV3.quoterFor chainId
                      let router := LeanCli.Swap.UniV3.routerFor chainId
                      let fees : List Nat := [500, 3000, 10000]
                      let via? ← verifiedReadVia state chainId.toNat ep
                      let mut best : Option (Nat × Nat) := none
                      for fee in fees do
                        let data := LeanCli.Swap.UniV3.encodeQuoteExactInputSingle
                          { tokenIn := tinAddr, tokenOut := toutAddr,
                            amountIn := amountIn, fee := fee }
                        match ← LeanCli.RPC.Outbound.ethCall cfg.policy ep quoter data "latest" via? with
                        | .ok ret =>
                            match asString ret with
                            | some hex =>
                                match LeanCli.Swap.UniV3.decodeQuoteAmountOut hex with
                                | some amt =>
                                    match best with
                                    | none => best := some (amt, fee)
                                    | some (b, _) =>
                                        if amt > b then best := some (amt, fee)
                                | none => pure ()
                            | none => pure ()
                        | .error _ => pure ()
                      match best with
                      | none =>
                          pure <| .error { code := -32020, message := "no Uniswap V3 pool returned a quote (all fee tiers reverted)", data := none }
                      | some (amt, fee) =>
                          pure <| .ok <| .obj #[
                            ("amountOut", .num (Int.ofNat amt)),
                            ("fee", .num (Int.ofNat fee)),
                            ("quoter", .str quoter),
                            ("router", .str router),
                            ("tokenIn", .str tinAddr),
                            ("tokenOut", .str toutAddr),
                            ("chainId", .num (Int.ofNat chainId.toNat))
                          ]
                  | _, _ =>
                      pure <| .error { code := -32602, message := "could not resolve tokenIn/tokenOut for chain", data := none }
              | _, _, _ => pure (.error invalidParams)
  | "swap.uniV3.build" =>
      let chainStr := paramStringD req.params "chainId" "mainnet"
      match LeanCli.Swap.Tokens.ChainId.fromString? chainStr with
      | none => pure <| .error { code := -32602, message := "unknown chainId for swap.uniV3.build", data := some (.str chainStr) }
      | some chainId =>
          let chainName : String :=
            match chainId with | .mainnet => "mainnet" | .sepolia => "sepolia"
          match endpointForChain cfg (some chainName) with
          | .error err => pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
          | .ok ep =>
              match paramString req.params "fromAddress",
                    paramString req.params "tokenIn",
                    paramString req.params "tokenOut",
                    getField "amountIn" req.params >>= asNat,
                    getField "amountOutMin" req.params >>= asNat,
                    getField "fee" req.params >>= asNat with
              | .ok fromAddr, .ok tinRaw, .ok toutRaw, some amountIn, some amountOutMin, some fee =>
                  let recipient := paramStringD req.params "recipient" fromAddr
                  let isEthIn :=
                    let s := tinRaw.trimAscii.toString.toLower
                    s = "eth"
                  let isEthOut :=
                    let s := toutRaw.trimAscii.toString.toLower
                    s = "eth"
                  if isEthIn && isEthOut then
                    pure <| .error { code := -32602, message := "ETH→ETH is not a swap", data := none }
                  else
                    match LeanCli.Swap.Tokens.resolve tinRaw chainId,
                          LeanCli.Swap.Tokens.resolve toutRaw chainId with
                    | some (_, tinAddr), some (_, toutAddr) =>
                        let router := LeanCli.Swap.UniV3.routerFor chainId
                        if isEthIn then
                          let exactCall :=
                            LeanCli.Swap.UniV3.encodeExactInputSingle
                              { tokenIn := tinAddr, tokenOut := toutAddr,
                                fee := fee, recipient := recipient,
                                amountIn := amountIn,
                                amountOutMinimum := amountOutMin }
                          let refund := LeanCli.Swap.UniV3.encodeRefundETH
                          let mc := LeanCli.Swap.UniV3.encodeMulticall [exactCall, refund]
                          pure <| .ok <| .obj #[
                            ("kind", .str "ethToToken"),
                            ("tx", .obj #[
                              ("to", .str router),
                              ("value", .num (Int.ofNat amountIn)),
                              ("data", .str mc)
                            ]),
                            ("router", .str router),
                            ("tokenIn", .str tinAddr),
                            ("tokenOut", .str toutAddr),
                            ("approval", .null)
                          ]
                        else if isEthOut then
                          let exactCall :=
                            LeanCli.Swap.UniV3.encodeExactInputSingle
                              { tokenIn := tinAddr, tokenOut := toutAddr,
                                fee := fee,
                                recipient := LeanCli.Swap.UniV3.addressThis,
                                amountIn := amountIn,
                                amountOutMinimum := amountOutMin }
                          let unwrapCall :=
                            LeanCli.Swap.UniV3.encodeUnwrapWETH9 amountOutMin recipient
                          let mc :=
                            LeanCli.Swap.UniV3.encodeMulticall [exactCall, unwrapCall]
                          let allowanceData :=
                            LeanCli.Swap.UniV3.encodeAllowance fromAddr router
                          let via? ← verifiedReadVia state chainId.toNat ep
                          let approval ←
                            (do
                              match ← LeanCli.RPC.Outbound.ethCall cfg.policy ep tinAddr allowanceData "latest" via? with
                              | .ok ret =>
                                  match asString ret with
                                  | some hex =>
                                      match LeanCli.Swap.UniV3.decodeWordAt hex 0 with
                                      | some current =>
                                          if current ≥ amountIn then pure Json.null
                                          else
                                            let approveData :=
                                              LeanCli.Swap.UniV3.encodeApprove
                                                router LeanCli.Swap.UniV3.maxUint256
                                            pure <| Json.obj #[
                                              ("to", .str tinAddr),
                                              ("value", .num 0),
                                              ("data", .str approveData),
                                              ("currentAllowance", .num (Int.ofNat current))
                                            ]
                                      | none => pure Json.null
                                  | none => pure Json.null
                              | .error _ =>
                                  let approveData :=
                                    LeanCli.Swap.UniV3.encodeApprove
                                      router LeanCli.Swap.UniV3.maxUint256
                                  pure <| Json.obj #[
                                    ("to", .str tinAddr),
                                    ("value", .num 0),
                                    ("data", .str approveData),
                                    ("currentAllowance", .null)
                                  ])
                          pure <| .ok <| .obj #[
                            ("kind", .str "tokenToEth"),
                            ("tx", .obj #[
                              ("to", .str router),
                              ("value", .num 0),
                              ("data", .str mc)
                            ]),
                            ("router", .str router),
                            ("tokenIn", .str tinAddr),
                            ("tokenOut", .str toutAddr),
                            ("approval", approval)
                          ]
                        else
                          let data :=
                            LeanCli.Swap.UniV3.encodeExactInputSingle
                              { tokenIn := tinAddr, tokenOut := toutAddr,
                                fee := fee, recipient := recipient,
                                amountIn := amountIn,
                                amountOutMinimum := amountOutMin }
                          let allowanceData :=
                            LeanCli.Swap.UniV3.encodeAllowance fromAddr router
                          let via? ← verifiedReadVia state chainId.toNat ep
                          let approval ←
                            (do
                              match ← LeanCli.RPC.Outbound.ethCall cfg.policy ep tinAddr allowanceData "latest" via? with
                              | .ok ret =>
                                  match asString ret with
                                  | some hex =>
                                      match LeanCli.Swap.UniV3.decodeWordAt hex 0 with
                                      | some current =>
                                          if current ≥ amountIn then pure Json.null
                                          else
                                            let approveData :=
                                              LeanCli.Swap.UniV3.encodeApprove
                                                router LeanCli.Swap.UniV3.maxUint256
                                            pure <| Json.obj #[
                                              ("to", .str tinAddr),
                                              ("value", .num 0),
                                              ("data", .str approveData),
                                              ("currentAllowance", .num (Int.ofNat current))
                                            ]
                                      | none => pure Json.null
                                  | none => pure Json.null
                              | .error _ =>
                                  let approveData :=
                                    LeanCli.Swap.UniV3.encodeApprove
                                      router LeanCli.Swap.UniV3.maxUint256
                                  pure <| Json.obj #[
                                    ("to", .str tinAddr),
                                    ("value", .num 0),
                                    ("data", .str approveData),
                                    ("currentAllowance", .null)
                                  ])
                          pure <| .ok <| .obj #[
                            ("kind", .str "tokenToToken"),
                            ("tx", .obj #[
                              ("to", .str router),
                              ("value", .num 0),
                              ("data", .str data)
                            ]),
                            ("router", .str router),
                            ("tokenIn", .str tinAddr),
                            ("tokenOut", .str toutAddr),
                            ("approval", approval)
                          ]
                    | _, _ =>
                        pure <| .error { code := -32602, message := "could not resolve tokenIn/tokenOut for chain", data := none }
              | _, _, _, _, _, _ => pure (.error invalidParams)
  | "swap.prepareUniswapV3" =>
      -- Why: single-call replacement for the agent's old multi-step
      -- "read allowance → quote → multiply → encode → maybe approve"
      -- prose-orchestrated workflow. Reads pass through `Outbound.ethCall`
      -- (same policy gate as `chain.ethCall`), and the resulting calldata
      -- still flows through `decodeIntent → simulate → ConfirmGate` before
      -- any signature. No new trust surface.
      let chainIdParam :=
        ((getField "chainId" req.params) >>= asNat).getD cfg.chainId
      match paramString req.params "sender",
            paramString req.params "tokenIn",
            paramString req.params "tokenOut",
            getField "amountIn" req.params >>= asNat with
      | .ok sender, .ok tokenIn, .ok tokenOut, some amountIn =>
          let recipient := paramStringD req.params "recipient" sender
          let fee := paramNatD req.params "fee" 3000
          let slippageProvided := (getField "slippageBps" req.params >>= asNat).isSome
          let slippageBps := paramNatD req.params "slippageBps" 50
          let deadlineSeconds := paramNatD req.params "deadlineSeconds" 1200
          let chainName : Option String :=
            if chainIdParam = 1 then some "mainnet"
            else if chainIdParam = 11155111 then some "sepolia"
            else getField "chain" req.params >>= asString
          match endpointForChain cfg chainName with
          | .error err =>
              pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
          | .ok ep =>
              let shim : LeanCli.Swap.Prepare.ChainEthCallShim :=
                fun to data chainIdForCall => do
                  let via? ← verifiedReadVia state chainIdForCall ep
                  match ← LeanCli.RPC.Outbound.ethCall cfg.policy ep to data "latest" via? with
                  | .ok ret =>
                      match asString ret with
                      | some hex => pure (.ok hex)
                      | none => pure (.error "non-string return from eth_call")
                  | .error e => pure (.error e)
              let request : LeanCli.Swap.Prepare.SwapRequest :=
                { chainId := chainIdParam,
                  sender := sender,
                  recipient := recipient,
                  tokenIn := tokenIn,
                  tokenOut := tokenOut,
                  amountIn := amountIn,
                  fee := fee,
                  slippageBps := slippageBps,
                  slippageWasDefault := !slippageProvided,
                  deadlineSeconds := deadlineSeconds }
              let result ← LeanCli.Swap.Prepare.prepareUniswapV3Swap request shim
              pure <| .ok (LeanCli.Swap.Prepare.PrepareResult.toJson result)
      | _, _, _, _ => pure (.error invalidParams)
  | m =>
      pure <| .error { code := -32601, message := s!"method not found: {m}", data := none }

end LeanCli.Daemon.Server.SwapRpc
