import LeanCli.Daemon.Server.Core
import LeanCli.Daemon.Server.Helpers
import LeanCli.Daemon.Server.Endpoints
import LeanCli.Daemon.Server.Journal
import LeanCli.Crypto.Hex
import LeanCli.Daemon.PpDestinations
import LeanCli.Daemon.State
import LeanCli.Daemon.TokenMeta
import LeanCli.Encoding.Json
import LeanCli.Network.Policy
import LeanCli.Ethereum.Address
import LeanCli.Ethereum.Ens
import LeanCli.Keystore.Tpm2Runtime
import LeanCli.RPC.Outbound
import LeanCli.RPC.Server
import LeanCli.Wallet.EoaStore

/-!
# Daemon server: `chain.*` RPC family

Chain reads + raw broadcast. Fourteen arms covering the read-side of
the EVM JSON-RPC surface, plus the bare-bytes broadcast path:

  chain.balance / nonce / gasPrice / maxPriorityFeePerGas / estimateGas
  chain.ethCall              — generic policy-gated eth_call
  chain.tokenBalance         — ERC-20 balanceOf via cached calldata
  chain.sendRawTransaction   — bare-bytes broadcast (TUI raw-tx path)
  chain.resolveName          — ENS forward resolution
  chain.addressFreshness     — first-tx age, used by NetworkPolicy
  chain.history / scanTransfers — agent-side wallet history projections
  chain.cancel               — replace-by-fee replacement (cancellation tx)
  chain.indexerHistory       — Etherscan-style indexer aggregation

All reads go through `RPC.Outbound.*` (policy-gated).
-/

namespace LeanCli.Daemon.Server.ChainRpc

open LeanCli.Encoding.Json
open LeanCli.Keystore.Tpm2Runtime
open LeanCli.Network.Policy
open LeanCli.RPC.Server
open LeanCli.Daemon.Server

/-- Handle every `chain.*` JSON-RPC method. -/
def dispatch (cfg : Config) (state : LeanCli.Daemon.State.Shared)
    (notify : LeanCli.Keystore.Tpm2Runtime.Notifier)
    (req : Request) : IO (Except RpcError Json) := do
  match req.method with
  | "chain.balance" =>
      match paramString req.params "address" with
      | .error err => pure (.error err)
      | .ok address =>
          match LeanCli.Ethereum.Address.fromHex address with
          | none => pure (.error invalidParams)
          | some _ =>
              let block := paramStringD req.params "block" "latest"
              -- Honor an optional `chain` selector (e.g. "mainnet"/"sepolia")
              -- so the TUI wallet list can query each row on its actual
              -- network — TPM/R1 slots are sepolia-only, while EOAs default
              -- to whatever the daemon's primary chain is. Falls back to
              -- `cfg.rpcEndpoint` when omitted, matching prior behavior.
              let chain? := getField "chain" req.params >>= asString
              match endpointForChain cfg chain? with
              | .error err =>
                  pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
              | .ok ep =>
                  -- Balance reads are display-only — mirror `swap.balances`
                  -- and skip the Colibri verifier so a stale or slow light
                  -- client can't poison the wallets hub with dust amounts /
                  -- intermittent failures. Soundness still comes from
                  -- `cfg.policy` gating; the result is never used for signing.
                  let via? : Option LeanCli.RPC.Outbound.VerifyVia := none
                  match ← LeanCli.RPC.Outbound.getBalance cfg.policy ep address block via? with
                  | .ok balance =>
                      pure <| .ok <| .obj #[
                        ("address", .str address),
                        ("block", .str block),
                        ("balance", balance),
                        ("chain", .str (chain?.getD (
                          if cfg.chainId = 1 then "mainnet"
                          else if cfg.chainId = 11155111 then "sepolia"
                          else "default")))
                      ]
                  | .error err =>
                      pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | "chain.nonce" =>
      match paramString req.params "address" with
      | .error err => pure (.error err)
      | .ok address =>
          match LeanCli.Ethereum.Address.fromHex address with
          | none => pure (.error invalidParams)
          | some _ =>
              let block := paramStringD req.params "block" "pending"
              -- Per-call chain override mirrors `eoa.send`. The TUI's
              -- unstick flow queries `latest` + `pending` nonces on a
              -- specific chain, which may differ from daemon default.
              let chainName? := getField "chain" req.params >>= asString
              let cfgEff : Config :=
                match chainName? with
                | none => cfg
                | some name =>
                    match endpointForChain cfg (some name) with
                    | .error _ => cfg
                    | .ok ep =>
                        let cid := (LeanCli.RPC.Outbound.chainNameToId name).getD cfg.chainId
                        { cfg with rpcEndpoint := ep, chainId := cid }
              let via? ← verifiedReadVia state cfgEff.chainId cfgEff.rpcEndpoint
              match ← LeanCli.RPC.Outbound.getTransactionCount cfgEff.policy cfgEff.rpcEndpoint address block via? with
              | .ok nonce =>
                  pure <| .ok <| .obj #[
                    ("address", .str address),
                    ("block", .str block),
                    ("nonce", nonce)
                  ]
              | .error err =>
                  pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | "chain.addressFreshness" =>
      -- Why: the wallets-hub TUI green-marks "0-link" rows so users
      -- can pick an unshield destination without leaking on-chain
      -- linkage. "0 link" here = nonce 0 (pending tag) AND no ERC-20
      -- Transfer event in/out within the lookback window. The window
      -- is bounded (default 5000 blocks ≈ 17 h on mainnet) because
      -- public RPCs cap eth_getLogs ranges; this is a best-effort
      -- signal, never used for signing decisions — the TUI degrades
      -- to "unknown" (no green) when either getLogs call fails.
      match paramString req.params "address" with
      | .error err => pure (.error err)
      | .ok address =>
          match LeanCli.Ethereum.Address.fromHex address with
          | none => pure (.error invalidParams)
          | some _ =>
              let chain? := getField "chain" req.params >>= asString
              match endpointForChain cfg chain? with
              | .error err =>
                  pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
              | .ok ep =>
                  -- Freshness is a best-effort display signal — never used
                  -- for signing decisions (see handler-level comment).
                  -- Match `chain.balance` / `swap.balances` and skip Colibri
                  -- so stale light-client state can't flip 0-link tags.
                  let via? : Option LeanCli.RPC.Outbound.VerifyVia := none
                  let lookback := paramNatD req.params "lookback" 5000
                  -- Nonce (pending) — primary "did this account ever send a tx" signal.
                  let nonceRes ← LeanCli.RPC.Outbound.getTransactionCount cfg.policy ep address "pending" via?
                  match nonceRes with
                  | .error err =>
                      pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
                  | .ok nonceJ =>
                      let nonceN := (asString nonceJ >>= parseHexQuantity).getD 0
                      -- Local-knowledge signal: did we ever unshield to
                      -- this address from this daemon? The TUI uses it
                      -- to keep the green tag on PP-funded receivers
                      -- whose only inbound value came from us via the
                      -- relayer. False otherwise — we never try to read
                      -- the chain to claim a third-party-PP-funded
                      -- address is fresh (the Withdrawn event's
                      -- indexed topic is the relayer, not the recipient,
                      -- so we can't tell cheaply).
                      let ppFunded ← LeanCli.Daemon.PpDestinations.contains address
                      -- Head block — bound the getLogs window.
                      let headRes ← LeanCli.RPC.Outbound.blockNumber cfg.policy ep via?
                      match headRes with
                      | .error _ =>
                          pure <| .ok <| .obj #[
                            ("address", .str address),
                            ("nonce", .num (Int.ofNat nonceN)),
                            ("ppFunded", .bool ppFunded),
                            ("available", .bool false),
                            ("reason", .str "eth_blockNumber failed")
                          ]
                      | .ok headJ =>
                          let head := (asString headJ >>= parseHexQuantity).getD 0
                          let fromBlock := if head ≤ lookback then 0 else head - lookback
                          let fromHex := natQuantityHex fromBlock
                          let toHex := natQuantityHex head
                          let paddedSelf := "0x" ++ LeanCli.Swap.UniV3.encodeAddress address
                          -- Two scans: address as Transfer.from (topic1), address as Transfer.to (topic2).
                          -- No `address` filter on the eth_getLogs query so any ERC-20
                          -- contract matches; that's the heavier query, hence "best-effort".
                          let outTopics : Array Json := #[.str transferEventTopic, .str paddedSelf, .null]
                          let inTopics  : Array Json := #[.str transferEventTopic, .null, .str paddedSelf]
                          let outRes ← LeanCli.RPC.Outbound.getLogsAnyAddress cfg.policy ep fromHex toHex outTopics via?
                          let inRes  ← LeanCli.RPC.Outbound.getLogsAnyAddress cfg.policy ep fromHex toHex inTopics  via?
                          let countOpt? : Json → Option Nat := fun j =>
                            (asArray j).map (fun a => a.size)
                          match outRes, inRes with
                          | .ok oj, .ok ij =>
                              let oc := (countOpt? oj).getD 0
                              let ic := (countOpt? ij).getD 0
                              pure <| .ok <| .obj #[
                                ("address", .str address),
                                ("nonce", .num (Int.ofNat nonceN)),
                                ("erc20OutCount", .num (Int.ofNat oc)),
                                ("erc20InCount", .num (Int.ofNat ic)),
                                ("ppFunded", .bool ppFunded),
                                ("fromBlock", .num (Int.ofNat fromBlock)),
                                ("toBlock", .num (Int.ofNat head)),
                                ("available", .bool true)
                              ]
                          | _, _ =>
                              pure <| .ok <| .obj #[
                                ("address", .str address),
                                ("nonce", .num (Int.ofNat nonceN)),
                                ("ppFunded", .bool ppFunded),
                                ("fromBlock", .num (Int.ofNat fromBlock)),
                                ("toBlock", .num (Int.ofNat head)),
                                ("available", .bool false),
                                ("reason", .str "eth_getLogs unavailable on this RPC")
                              ]
  | "chain.gasPrice" =>
      let via? ← verifiedReadVia state cfg.chainId cfg.rpcEndpoint
      match ← LeanCli.RPC.Outbound.gasPrice cfg.policy cfg.rpcEndpoint via? with
      | .ok gasPrice =>
          pure <| .ok <| .obj #[("gasPrice", gasPrice)]
      | .error err =>
          pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | "chain.maxPriorityFeePerGas" =>
      let via? ← verifiedReadVia state cfg.chainId cfg.rpcEndpoint
      match ← LeanCli.RPC.Outbound.maxPriorityFeePerGas cfg.policy cfg.rpcEndpoint via? with
      | .ok maxPriorityFeePerGas =>
          pure <| .ok <| .obj #[("maxPriorityFeePerGas", maxPriorityFeePerGas)]
      | .error err =>
          pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | "chain.estimateGas" =>
      match paramTxRequest req.params with
      | .error err => pure (.error err)
      | .ok tx =>
          let block := paramStringD req.params "block" "latest"
          let via? ← verifiedReadVia state cfg.chainId cfg.rpcEndpoint
          match ← LeanCli.RPC.Outbound.estimateGas cfg.policy cfg.rpcEndpoint tx block via? with
          | .ok gas =>
              pure <| .ok <| .obj #[
                ("tx", tx),
                ("block", .str block),
                ("gas", gas)
              ]
          | .error err =>
              pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | "chain.ethCall" =>
      -- Why: a general policy-gated `eth_call` for any contract method.
      -- Used by the LLM agent's tool layer (Aave health factor, future
      -- Uniswap V3 Quoter, etc.) to read contract state without each
      -- protocol getting its own daemon RPC. The daemon does no decoding
      -- of the return value — that's the caller's responsibility, since
      -- this is a general-purpose primitive.
      match paramString req.params "to", paramString req.params "data" with
      | .ok to, .ok data =>
          match LeanCli.Ethereum.Address.fromHex to with
          | none => pure (.error invalidParams)
          | some _ =>
              let block := paramStringD req.params "block" "latest"
              let chain? := getField "chain" req.params >>= asString
              match endpointForChain cfg chain? with
              | .error err =>
                  pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
              | .ok ep =>
                  let chainIdParam :=
                    ((getField "chainId" req.params) >>= asNat).getD cfg.chainId
                  let via? ← verifiedReadVia state chainIdParam ep
                  match ← LeanCli.RPC.Outbound.ethCall cfg.policy ep to data block via? with
                  | .ok ret =>
                      pure <| .ok <| .obj #[
                        ("to", .str to),
                        ("data", .str data),
                        ("block", .str block),
                        ("returnData", ret)
                      ]
                  | .error err =>
                      pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
      | _, _ => pure (.error invalidParams)
  | "chain.tokenBalance" =>
      match paramString req.params "token", paramString req.params "owner" with
      | .ok token, .ok owner =>
          match LeanCli.Ethereum.Address.fromHex token, LeanCli.Ethereum.Address.fromHex owner with
          | some _, some ownerAddr =>
              let block := paramStringD req.params "block" "latest"
              let data := erc20BalanceOfData ownerAddr
              let via? ← verifiedReadVia state cfg.chainId cfg.rpcEndpoint
              match ← LeanCli.RPC.Outbound.ethCall cfg.policy cfg.rpcEndpoint token data block via? with
              | .ok balance =>
                  pure <| .ok <| .obj #[
                    ("token", .str token),
                    ("owner", .str owner),
                    ("block", .str block),
                    ("balance", balance)
                  ]
              | .error err =>
                  pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
          | _, _ => pure (.error invalidParams)
      | _, _ => pure (.error invalidParams)
  | "chain.sendRawTransaction" =>
      match paramString req.params "raw" with
      | .error err => pure (.error err)
      | .ok raw =>
          match LeanCli.Crypto.Hex.decode raw with
          | none => pure (.error invalidParams)
          | some bytes =>
              if bytes.isEmpty then
                pure (.error invalidParams)
              else
                match ← LeanCli.RPC.Outbound.sendRawTransaction cfg.policy cfg.rpcEndpoint raw with
                | .ok txHash =>
                    pure <| .ok <| .obj #[
                      ("raw", .str raw),
                      ("txHash", txHash)
                    ]
                | .error err =>
                    pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | "chain.resolveName" =>
      match paramString req.params "name" with
      | .error err => pure (.error err)
      | .ok name =>
          -- Why: ENS names are canonical on mainnet; the wallet's operating
          -- chainId is irrelevant for resolution. Always query mainnet (chainId 1)
          -- against the user-configured ENS RPC; no fallback to cfg.rpcEndpoint.
          match cfg.ensRpcEndpoint with
          | none =>
              pure <| .error {
                code := -32030,
                message :=
                  "no ENS RPC configured: set LEANCLI_ENS_RPC_URL or 'ens_rpc_url' in daemon.json (mainnet RPC required for ENS resolution)",
                data := none }
          | some ensEndpoint =>
              -- ENS is mainnet (chainId 1), independent of cfg.chainId.
              let viaEns? ← verifiedReadVia state 1 ensEndpoint
              match ← LeanCli.Ethereum.Ens.resolveIO cfg.policy ensEndpoint 1 name viaEns? with
              | .ok r =>
                  pure <| .ok <| .obj #[
                    ("name", .str r.name),
                    ("address", .str r.address),
                    ("chainId", .num (Int.ofNat r.chainId)),
                    ("resolver", .str r.resolver)
                  ]
              | .error (code, msg) =>
                  pure <| .error { code := code, message := msg, data := none }
  | "chain.history" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          let limit? : Option Nat := getField "limit" req.params >>= asNat
          let raw ← LeanCli.Daemon.TxJournal.read name limit?
          -- Overlay sphincs.inclusion records onto matching sphincs.userOp
          -- entries (by userOpHash) so the UI can show the L1 tx hash
          -- instead of the bundler's userOpHash. The inclusion record is
          -- a separate "kind"=sphincs.inclusion entry written by the poll
          -- RPC once the bundler returns a receipt.
          let isInclusion (j : Json) : Bool :=
            (getField "kind" j >>= asString) = some "sphincs.inclusion"
          -- Build a lookup userOpHash → (inclusionTxHash, blockNumber?, success?)
          -- as an Array (linear scan; lists here are bounded by the
          -- page limit, so O(n²) merge is fine). Later inclusion
          -- records override earlier ones for the same userOp because
          -- `find?` returns the LAST inserted match — we walk back to
          -- front below.
          let inclusionList : Array (String × String × Option String × Option Bool) :=
            raw.filterMap fun j =>
              if isInclusion j then
                match getField "userOpHash" j >>= asString,
                      getField "inclusionTxHash" j >>= asString with
                | some uoh, some itx =>
                    let blk := getField "blockNumber" j >>= asString
                    let succ : Option Bool := match getField "success" j with
                      | some (.bool b) => some b
                      | _ => none
                    some (uoh, itx, blk, succ)
                | _, _ => none
              else none
          let lookupInclusion (uoh : String) :
              Option (String × Option String × Option Bool) :=
            -- Reverse scan so the latest inclusion record wins.
            let rec go (i : Nat) : Option (String × Option String × Option Bool) :=
              if i = 0 then none
              else
                let j := i - 1
                if h : j < inclusionList.size then
                  let (k, itx, blk, succ) := inclusionList[j]
                  if k = uoh then some (itx, blk, succ) else go j
                else go j
            go inclusionList.size
          -- Walk entries; drop the bare inclusion records (they were
          -- consumed into the map) and decorate entries whose
          -- userOpHash matches.
          let decorated : Array Json := raw.filterMap fun j =>
            if isInclusion j then none
            else
              match getField "userOpHash" j >>= asString with
              | none => some j
              | some uoh =>
                  match lookupInclusion uoh with
                  | none => some j
                  | some (itx, blk?, succ?) =>
                      let base : Array (String × Json) := match j with
                        | .obj kvs => kvs
                        | _ => #[]
                      let withItx := base.push ("inclusionTxHash", .str itx)
                      let withBlk := match blk? with
                        | none => withItx
                        | some b => withItx.push ("inclusionBlockNumber", .str b)
                      let withSucc := match succ? with
                        | none => withBlk
                        | some s => withBlk.push ("inclusionSuccess", .bool s)
                      some (.obj withSucc)
          pure (.ok (.arr decorated))
  | "chain.scanTransfers" =>
      -- Why: chunked eth_getLogs. The 32-byte-padded address goes in topic1
      -- (out) and topic2 (in); two queries per chunk merged & deduped.
      match getField "addresses" req.params >>= asArray with
      | none => pure (.error invalidParams)
      | some arr =>
          -- Why: pick endpoint at call time so users can scan history on a
          -- chain other than the one the daemon's default RPC points at.
          -- Fail closed when the requested chain has no configured endpoint.
          let chain? := getField "chain" req.params >>= asString
          match endpointForChain cfg chain? with
          | .error msg =>
              pure (.error { code := -32602, message := msg, data := none })
          | .ok scanEndpoint =>
              let addresses := arr.filterMap asString
              let chunkSize ← do
                match getField "chunkSize" req.params >>= asNat with
                | some n => pure n
                | none =>
                    match ← IO.getEnv "LEANCLI_GETLOGS_MAX_BLOCK_SPAN" with
                    | some s => pure (s.toNat?.getD 5000)
                    | none => pure 5000
              let chainIdForScan :=
                ((getField "chainId" req.params) >>= asNat).getD cfg.chainId
              let viaScan? ← verifiedReadVia state chainIdForScan scanEndpoint
              -- Resolve fromBlock/toBlock.
              let fromBlock ← do
                match getField "fromBlock" req.params >>= asNat with
                | some n => pure n
                | none => pure 0
              let toBlock ← do
                match getField "toBlock" req.params >>= asNat with
                | some n => pure n
                | none =>
                    match ← LeanCli.RPC.Outbound.blockNumber cfg.policy scanEndpoint viaScan? with
                    | .ok j =>
                        pure ((asString j >>= parseHexQuantity).getD 0)
                    | .error _ => pure 0
              let topic0 := "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
              let padAddr (a : String) : String :=
                let raw := stripHexPrefix a |>.toLower
                "0x" ++ String.ofList (List.replicate (64 - raw.length) '0') ++ raw
              -- Reset cancellation flag for this scan. Why: `chain.cancel`
              -- sets it to `true`; if a previous run set it and was never
              -- consumed, we'd abort before doing any work.
              LeanCli.Daemon.State.beginScan state
              -- Wall-clock cap: timeout is orthogonal to user-initiated cancel.
              -- Default 5 min; overridable via env or per-call `maxMs` param.
              -- Reject 0/negative — fall back to default to avoid an instantly
              -- expiring scan or a non-terminating loop on a parse error.
              let defaultMaxMs : Nat := 300000
              let envMaxMs : Nat ← do
                match ← IO.getEnv "LEANCLI_SCAN_MAX_MS" with
                | some s =>
                    match s.toNat? with
                    | some n => if n = 0 then pure defaultMaxMs else pure n
                    | none => pure defaultMaxMs
                | none => pure defaultMaxMs
              let maxMs : Nat :=
                match getField "maxMs" req.params >>= asNat with
                | some n => if n = 0 then envMaxMs else n
                | none => envMaxMs
              let started ← IO.monoMsNow
              let mut events : Array Json := #[]
              let mut seen : Array String := #[]
              let mut errAcc : Option String := none
              let mut cancelled : Bool := false
              let mut timedOut : Bool := false
              let mut lastScanned : Nat := fromBlock
              for addr in addresses do
                if cancelled || timedOut then pure ()
                else
                  let topicAddr := padAddr addr
                  let mut cur := fromBlock
                  -- Bound the chunk loop; chunkSize=0 would loop forever.
                  let span := if chunkSize = 0 then 5000 else chunkSize
                  let mut fuel := 5000
                  while cur ≤ toBlock && fuel > 0 && !cancelled && !timedOut do
                    let chunkTo := if cur + span > toBlock then toBlock else cur + span
                    let fromHex := natQuantityHex cur
                    let toHex := natQuantityHex chunkTo
                    -- Outbound (from = topic1)
                    let topicsOut : Array Json :=
                      #[.str topic0, .str topicAddr, .null]
                    -- Inbound (to = topic2)
                    let topicsIn : Array Json :=
                      #[.str topic0, .null, .str topicAddr]
                    for topicsArr in [topicsOut, topicsIn] do
                      if cancelled || timedOut then pure ()
                      else
                        -- Check cancel flag before each outbound call so the
                        -- second of the two queries can be skipped too.
                        if (← LeanCli.Daemon.State.isScanCancelled state) then
                          cancelled := true
                        else
                          match ← LeanCli.RPC.Outbound.call cfg.policy scanEndpoint
                              .getLogs (.arr #[.obj #[
                                ("fromBlock", .str fromHex),
                                ("toBlock", .str toHex),
                                ("topics", .arr topicsArr)
                              ]]) viaScan? with
                          | .error e => errAcc := some e
                          | .ok logsJson =>
                              match asArray logsJson with
                              | none => pure ()
                              | some logs =>
                                  for log in logs do
                                    let txHash := (getField "transactionHash" log >>= asString).getD ""
                                    let logIdx := (getField "logIndex" log >>= asString).getD ""
                                    let key := txHash ++ "#" ++ logIdx
                                    if seen.contains key then pure ()
                                    else
                                      seen := seen.push key
                                      events := events.push log
                    lastScanned := chunkTo
                    cur := chunkTo + 1
                    fuel := fuel - 1
                    -- Re-check after the chunk so the next chunk is skipped
                    -- promptly when cancellation arrives.
                    if !cancelled && (← LeanCli.Daemon.State.isScanCancelled state) then
                      cancelled := true
                    -- Wall-clock check: orthogonal to cancel; surfaces as
                    -- `timedOut` in the result so the CLI can prompt resume.
                    if !timedOut then
                      let nowMs ← IO.monoMsNow
                      if nowMs - started ≥ maxMs then
                        timedOut := true
              -- Persist last-scanned-block for at least one address (the first).
              -- If we cancelled mid-scan, persist the last fully-attempted
              -- chunk boundary so the next run can resume.
              let persistedTo :=
                if cancelled || timedOut then lastScanned else toBlock
              if let some firstSlot := getField "slotName" req.params >>= asString then
                LeanCli.Daemon.TxJournal.writeScanState firstSlot persistedTo
              let resultJson : Json := .obj #[
                ("events", .arr events),
                ("fromBlock", .num (Int.ofNat fromBlock)),
                ("toBlock", .num (Int.ofNat toBlock)),
                ("cancelled", .bool cancelled),
                ("timedOut", .bool timedOut),
                ("maxMs", .num (Int.ofNat maxMs)),
                ("lastScannedBlock", .num (Int.ofNat persistedTo))
              ]
              match errAcc with
              | none => pure (.ok resultJson)
              | some _ => pure (.ok resultJson)
  | "chain.cancel" =>
      -- Idempotent: signal any in-flight `chain.scanTransfers` to abort at
      -- the next chunk boundary. Safe to call when no scan is running.
      LeanCli.Daemon.State.cancelScan state
      pure <| .ok <| .obj #[("ok", .bool true)]
  | "chain.indexerHistory" =>
      -- Why: opt-in third-party history lookup. The daemon refuses unless
      -- the indexer is allow-listed in daemon.json, *and* the network
      -- policy permits indexerLookup. Strict mode rejects.
      match paramString req.params "address", paramString req.params "indexer" with
      | .ok address, .ok indexerName =>
          match cfg.indexers.find? (fun e => e.name = indexerName) with
          | none =>
              pure <| .error
                { code := -32030,
                  message := s!"indexer '{indexerName}' not enabled — run 'leancli network allow-indexer {indexerName}'",
                  data := none }
          | some entry =>
              let polReq : NetworkRequest :=
                { peer := .thirdPartyApi, purpose := .indexerLookup,
                  transport := .direct }
              if !(cfg.policy polReq) then
                pure <| .error
                  { code := -32031,
                    message := "network policy denies indexer lookup (strict mode)",
                    data := none }
              else
                let envKey := "LEANCLI_" ++ indexerName.toUpper ++ "_KEY"
                let apiKey ← IO.getEnv envKey
                let key := apiKey.getD ""
                let url1 := s!"{entry.url}?chainid={cfg.chainId}&module=account&action=txlist&address={address}&apikey={key}"
                let url2 := s!"{entry.url}?chainid={cfg.chainId}&module=account&action=tokentx&address={address}&apikey={key}"
                let fetch (u : String) : IO Json := do
                  try
                    let out ← IO.Process.output
                      { cmd := "curl", args := #["-sS", u] }
                    if out.exitCode != 0 then pure .null
                    else
                      match parse out.stdout with
                      | .ok j => pure j
                      | .error _ => pure .null
                  catch _ => pure .null
                let txList ← fetch url1
                let tokenTx ← fetch url2
                pure <| .ok <| .obj #[
                  ("indexer", .str indexerName),
                  ("address", .str address),
                  ("txlist", txList),
                  ("tokentx", tokenTx)
                ]
      | _, _ => pure (.error invalidParams)
  | m =>
      pure <| .error { code := -32601, message := s!"method not found: {m}", data := none }

end LeanCli.Daemon.Server.ChainRpc
