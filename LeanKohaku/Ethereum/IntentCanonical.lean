import LeanKohaku.Crypto.Hex
import LeanKohaku.Ethereum.Address
import LeanKohaku.Ethereum.Intent

/-!
# Canonical string rendering of an `Intent`

A pure, deterministic, version-stable `Intent → String` rendering that
gets shown to the user in the ConfirmGate **alongside** the simulated
effects. Vitalik's "deterministic representation" principle: the user
sees, in one form they can verify, exactly what is about to be signed.

## Why a separate rendering layer

The simulation block shows token movements (transfers in / out) which
is the most useful display 99% of the time. But the simulation can be
misleading in edge cases the user cannot spot — a malicious dApp could
construct calldata whose simulated effect on this block hides a future
effect (e.g. setting a hook). The canonical string is **structural**,
not behavioral: it describes the encoded *action*, not its outcome.
The two together close the gap.

## Format

One line per field, `key: value` shape, lowercase keys. Hex strings
lowercase `0x`-prefixed. No locale-sensitive formatting; the rendering
is identical on every machine.

```
action:    approve
chain:     1
token:     0x...
spender:   0x...
amount:    UNLIMITED
```

## Stability guarantee

Adding a new `Intent` constructor requires updating this function. The
existing renderings MUST NOT change — a user's mental fingerprint of
"what an approve text looks like" should be the same across releases.
Renaming a field key is a breaking change to the canonical form.
-/

namespace LeanKohaku.Ethereum.IntentCanonical

open LeanKohaku.Ethereum.Intent
open LeanKohaku.Ethereum.Address (Address)

private def addrHex (a : Address) : String :=
  LeanKohaku.Crypto.Hex.encode a.bytes

/-- Render `ApproveAmount` so the three meaningfully-different cases
are visually distinct in the confirm screen:
* `0` is rendered as `0 (REVOKE — sets allowance to zero)` — what
  looks like a small number is actually a destruction of permission.
* `UNLIMITED` is loud-and-unmissable.
* Any other exact amount renders as the bare decimal Nat. -/
private def renderApprove : ApproveAmount → String
  | .exact 0   => "0 (REVOKE — sets allowance to zero)"
  | .exact n   => toString n
  | .unlimited => "UNLIMITED"

/-- The canonical multi-line string rendering. -/
def toCanonicalString : Intent → String
  | .nativeTransfer chainId to amountWei =>
      String.intercalate "\n" [
        "action:     nativeTransfer",
        s!"chain:      {chainId}",
        s!"to:         {addrHex to}",
        s!"valueWei:   {amountWei}"
      ]
  | .erc20Transfer chainId token decimals to amount =>
      String.intercalate "\n" [
        "action:     erc20Transfer",
        s!"chain:      {chainId}",
        s!"token:      {addrHex token}",
        s!"decimals:   {decimals}",
        s!"to:         {addrHex to}",
        s!"amount:     {amount}"
      ]
  | .erc20Approve chainId token spender amount =>
      String.intercalate "\n" [
        "action:     erc20Approve",
        s!"chain:      {chainId}",
        s!"token:      {addrHex token}",
        s!"spender:    {addrHex spender}",
        s!"amount:     {renderApprove amount}"
      ]
  | .uniswapV3SwapSingle chainId tokenIn tokenOut amountIn fee minAmountOut recipient deadline =>
      String.intercalate "\n" [
        "action:     uniswapV3SwapSingle",
        s!"chain:      {chainId}",
        s!"tokenIn:    {addrHex tokenIn}",
        s!"tokenOut:   {addrHex tokenOut}",
        s!"amountIn:   {amountIn}",
        s!"fee:        {fee}",
        s!"minOut:     {minAmountOut}",
        s!"recipient:  {addrHex recipient}",
        s!"deadline:   {deadline}"
      ]
  | .aaveV3Supply chainId asset amount onBehalfOf =>
      String.intercalate "\n" [
        "action:     aaveV3Supply",
        s!"chain:      {chainId}",
        s!"asset:      {addrHex asset}",
        s!"amount:     {amount}",
        s!"onBehalfOf: {addrHex onBehalfOf}"
      ]
  | .aaveV3Withdraw chainId asset amount recipient =>
      String.intercalate "\n" [
        "action:     aaveV3Withdraw",
        s!"chain:      {chainId}",
        s!"asset:      {addrHex asset}",
        s!"amount:     {amount}",
        s!"recipient:  {addrHex recipient}"
      ]
  | .rawCall chainId to valueWei data rationale =>
      String.intercalate "\n" [
        "action:     rawCall",
        s!"chain:      {chainId}",
        s!"to:         {addrHex to}",
        s!"valueWei:   {valueWei}",
        s!"data:       {LeanKohaku.Crypto.Hex.encode data}",
        s!"rationale:  {rationale}"
      ]
  | .shieldedDeposit chainId amountWei =>
      String.intercalate "\n" [
        "action:     shielded.deposit",
        s!"chain:      {chainId}",
        s!"amountWei:  {amountWei}",
        "note:       deposit enters the Privacy Pool contract; withdrawal must go to a never-used address to break the on-chain link"
      ]
  | .shieldedWithdraw chainId amountWei recipient viaRelayer =>
      String.intercalate "\n" [
        "action:     shielded.withdraw",
        s!"chain:      {chainId}",
        s!"amountWei:  {amountWei}",
        s!"recipient:  {addrHex recipient}",
        s!"viaRelayer: {viaRelayer}",
        "note:       recipient should be a FRESH address with no link to the deposit source"
      ]
  | .railgunShield chainId amountWei =>
      String.intercalate "\n" [
        "action:     shielded.railgun.shield",
        s!"chain:      {chainId}",
        s!"amountWei:  {amountWei}",
        "note:       deposit enters Railgun under your viewing/spending keys; spendable after POI tree updates (minutes to hours)"
      ]
  | .railgunUnshield chainId amountWei recipient =>
      String.intercalate "\n" [
        "action:     shielded.railgun.unshield",
        s!"chain:      {chainId}",
        s!"amountWei:  {amountWei}",
        s!"recipient:  {addrHex recipient}",
        "note:       recipient should be a FRESH address; Railgun handles relayer selection internally"
      ]
  | .tornadoDeposit chainId denominationWei =>
      String.intercalate "\n" [
        "action:     shielded.tornado.deposit",
        s!"chain:      {chainId}",
        s!"denomWei:   {denominationWei}",
        "note:       fixed-denomination mixer (0.1 / 1 / 10 / 100 ETH); the bridge sidecar returns your spending note — SAVE IT, the wallet cannot recover from this commitment alone"
      ]
  | .tornadoWithdraw chainId denominationWei recipient note =>
      -- The deposit note is the spending secret. Show only the
      -- format-prefix (`tornado-note-eth-<denom>-`) so a screenshot of
      -- ConfirmGate doesn't leak the secret bytes. The user supplied
      -- the note themselves and knows what's behind the elision.
      -- Char-list slicing avoids the v4.29.1 `String.Slice` churn from
      -- the new `String.take` API.
      let elidedNote : String :=
        if note.length ≤ 16 then "<note elided>"
        else String.ofList (note.toList.take 16) ++ "…<elided>"
      String.intercalate "\n" [
        "action:     shielded.tornado.withdraw",
        s!"chain:      {chainId}",
        s!"denomWei:   {denominationWei}",
        s!"recipient:  {addrHex recipient}",
        s!"note:       {elidedNote}",
        "note:       recipient should be a FRESH address with no deposit-side link; this is the only chance to break anonymity if you mis-pick"
      ]
  | .approvalsAudit chainId wallet =>
      let walletStr : String :=
        match wallet with
        | some a => addrHex a
        | none   => "(default wallet)"
      String.intercalate "\n" [
        "action:     approvals.audit",
        s!"chain:      {chainId}",
        s!"wallet:     {walletStr}",
        "note:       READ-ONLY; no signing"
      ]
  | .ensRegister chainId name owner durationSeconds =>
      String.intercalate "\n" [
        "action:     ens.register",
        s!"chain:      {chainId}",
        s!"name:       {name}",
        s!"owner:      {addrHex owner}",
        s!"durationS:  {durationSeconds}",
        "note:       SECOND leg of commit/reveal; the commit tx must already be on-chain and past the commit-age gate"
      ]
  | .ensRenew chainId name durationSeconds =>
      String.intercalate "\n" [
        "action:     ens.renew",
        s!"chain:      {chainId}",
        s!"name:       {name}",
        s!"durationS:  {durationSeconds}"
      ]
  | .freshAddress chainId kind label deployImmediately =>
      let labelStr := label.getD "(unnamed)"
      String.intercalate "\n" [
        "action:     address.fresh",
        s!"chain:      {chainId}",
        s!"kind:       {WalletKind.toString kind}",
        s!"label:      {labelStr}",
        s!"deploy:     {deployImmediately}",
        "note:       LOCAL wallet creation; no chain interaction yet"
      ]

/-- The action tag alone, useful for one-liner badges. -/
def actionTag : Intent → String
  | .nativeTransfer _ _ _              => "nativeTransfer"
  | .erc20Transfer  _ _ _ _ _          => "erc20Transfer"
  | .erc20Approve   _ _ _ _            => "erc20Approve"
  | .uniswapV3SwapSingle _ _ _ _ _ _ _ _ => "uniswapV3SwapSingle"
  | .aaveV3Supply   _ _ _ _            => "aaveV3Supply"
  | .aaveV3Withdraw _ _ _ _            => "aaveV3Withdraw"
  | .rawCall        _ _ _ _ _          => "rawCall"
  | .shieldedDeposit  _ _              => "shielded.deposit"
  | .shieldedWithdraw _ _ _ _          => "shielded.withdraw"
  | .railgunShield    _ _              => "shielded.railgun.shield"
  | .railgunUnshield  _ _ _            => "shielded.railgun.unshield"
  | .tornadoDeposit   _ _              => "shielded.tornado.deposit"
  | .tornadoWithdraw  _ _ _ _          => "shielded.tornado.withdraw"
  | .approvalsAudit   _ _              => "approvals.audit"
  | .ensRegister      _ _ _ _          => "ens.register"
  | .ensRenew         _ _ _            => "ens.renew"
  | .freshAddress     _ _ _ _          => "address.fresh"

end LeanKohaku.Ethereum.IntentCanonical
