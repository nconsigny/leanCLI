import LeanCli.Daemon.Server.Core
import LeanCli.Daemon.Server.Helpers
import LeanCli.Daemon.Server.Endpoints
import LeanCli.Daemon.State
import LeanCli.Ethereum.Address
import LeanCli.Ethereum.Multicall3
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
      -- Why: native `eth_getBalance` + every ERC-20 `balanceOf` across the
      -- swap registry filtered by chain. This is the data source for the
      -- TUI swap from-picker (per-token balance column) and the
      -- `leancli balances` CLI command. The ERC-20 reads are batched into a
      -- single Multicall3 `aggregate3` call so the whole fan-out is one
      -- round-trip regardless of token count — see below for why that
      -- matters on the verified path.
      --
      -- Trust model: balance reads are policy-gated by `Outbound.*`; the
      -- response is render-only data and never feeds a signing decision.
      -- Reads go through the selected provider via `via?` (consensus-
      -- verified by default), the same as every other chain read.
      --
      -- Fail-soft: a token whose `balanceOf` reverts comes back from
      -- `aggregate3` as `success = false` (`allowFailure := true`) and is
      -- dropped from the response, mirroring the trace tokenMeta prefetch
      -- policy. Other tokens still appear. ETH balance failure causes the
      -- whole call to error, since a valid address should always have a
      -- queryable native balance.
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
                      -- Verify ALL token balances through the mutex-guarded
                      -- verified client (State.verifyLock). Each verified
                      -- eth_call runs REVM against light-client state and the
                      -- single shared conn is mutex-serialized, so a serial
                      -- per-token loop (~5s × N) blew past the daemon timeout.
                      -- Instead we batch every `balanceOf` into ONE
                      -- Multicall3 `aggregate3` call: one verified round-trip
                      -- regardless of N. `allowFailure := true` keeps the
                      -- fail-soft rule — a reverting token comes back
                      -- `success = false` and is dropped, not fatal.
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
                              -- Canonical 0x-hex: helios returns a bare decimal
                              -- quantity; raw it renders ~2700× too large.
                              ("balance",  quantityJsonHex ethBal)
                            ]
                          ]
                          -- One batched `aggregate3` round-trip for every
                          -- ERC-20 `balanceOf`. Decode failures and per-token
                          -- reverts are soft-dropped (render-only surface);
                          -- ETH already succeeded above.
                          let batchData := LeanCli.Ethereum.Multicall3.encodeAggregate3 <|
                            candidates.map fun (_, addr) =>
                              { target := addr, allowFailure := true, callData := calldata }
                          match ← LeanCli.RPC.Outbound.ethCall cfg.policy ep
                                    LeanCli.Ethereum.Multicall3.address batchData "latest" via? with
                          | .ok ret =>
                              match (asString ret).bind LeanCli.Ethereum.Multicall3.decodeAggregate3 with
                              | some results =>
                                  for ((t, addr), (ok, bal)) in candidates.zip results do
                                    if ok then
                                      entries := entries.push <| .obj #[
                                        ("symbol",   .str t.symbol),
                                        ("name",     .str t.name),
                                        ("address",  .str addr),
                                        ("decimals", .num (Int.ofNat t.decimals)),
                                        ("balance",  .str bal)
                                      ]
                              | none => pure ()
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
                      let via? ← verifiedReadVia state chainId.toNat ep
                      -- Existence probe: ONE batched factory.getPool over
                      -- every candidate tier before quoting. Quoting a
                      -- nonexistent pool REVERTS, and a reverting read pays
                      -- a full EVM execution on the verified backend
                      -- (observed as 3 × ~30s tier probes for a pair with
                      -- no pools); getPool is a cheap mapping read that
                      -- never reverts. Also widens the tier set to include
                      -- 100 (0.01%, stable pairs) which the old
                      -- revert-probe loop never tried. Probe failure falls
                      -- back to the legacy tier list rather than erroring —
                      -- the probe is an optimization, not a gate.
                      let allFees : List Nat := [100, 500, 3000, 10000]
                      let factory := LeanCli.Swap.UniV3.factoryFor chainId
                      let poolProbe := LeanCli.Ethereum.Multicall3.encodeAggregate3 <|
                        allFees.map fun fee =>
                          { target := factory, allowFailure := true,
                            callData := LeanCli.Swap.UniV3.encodeGetPool tinAddr toutAddr fee }
                      let fees : List Nat ←
                        match ← LeanCli.RPC.Outbound.ethCall cfg.policy ep
                            LeanCli.Ethereum.Multicall3.address poolProbe "latest" via? with
                        | .ok ret =>
                            match (asString ret).bind LeanCli.Ethereum.Multicall3.decodeAggregate3 with
                            | some results =>
                                pure <| (allFees.zip results).filterMap fun (fee, ok, hex) =>
                                  match (if ok then LeanCli.Swap.UniV3.decodeWordAt hex 0 else none) with
                                  | some w => if w != 0 then some fee else none
                                  | none => none
                            | none => pure [500, 3000, 10000]
                        | .error _ => pure [500, 3000, 10000]
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
                          -- Distinguish "the pair has no pools at all" (probe
                          -- found nothing; fees was empty, loop was a no-op)
                          -- from "pools exist but every quote failed".
                          let msg :=
                            if fees.isEmpty then
                              s!"no Uniswap V3 pool exists for this pair on {chainName} (checked fee tiers 0.01% / 0.05% / 0.3% / 1%)"
                            else
                              "no Uniswap V3 pool returned a quote (all fee tiers reverted)"
                          pure <| .error { code := -32020, message := msg, data := none }
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
