# morpho — interaction recipes

## Recipe: open a borrow position on Morpho Blue

Goal: deposit `collateralAmount` of `collateralToken`, borrow
`loanAmount` of `loanToken` from the market
`(loanToken, collateralToken, oracle, irm, lltv)`.

1. Compute `id = keccak256(abi.encode(marketParams))` locally.
2. Verify the market exists: `chain_read({to: MorphoBlue, data:
   encode("idToMarketParams(bytes32)", id)})` → tuple. Confirm it
   matches.
3. Verify `oracle` and `irm` are on the user's trust list.
4. Allowance dance for `collateralToken` to MorphoBlue (use
   `bridge/clearsign/registry/erc20.json` decoder).
5. Step 1 of borrow: build
   `supplyCollateral(marketParams, collateralAmount,
   onBehalf=msg.sender, data=0x)`.
6. `tx.simulate` → `propose_send`.
7. **Pre-borrow guard**: read `position(id, msg.sender)` and
   `market(id)`. Compute post-borrow collateralisation:
   `(collateral * oraclePrice) / (totalBorrowAssets * (borrowShares
   + newShares) / totalBorrowShares) ≥ 1.05× LLTV`. Refuse otherwise.
8. Step 2 of borrow: build
   `borrow(marketParams, loanAmount, 0, onBehalf=msg.sender,
   receiver=msg.sender)`.
9. `tx.simulate` → `propose_send`.

## Recipe: repay and close a Blue position

1. Compute `id` and read `position(id, msg.sender)` → owed shares.
2. Allowance dance for `loanToken` to MorphoBlue.
3. Build `repay(marketParams, 0, borrowShares, onBehalf=msg.sender,
   data=0x)`. (Use `shares` to repay exactly the full debt; use
   `assets` for a partial repay denominated in the loan asset.)
4. `tx.simulate` → `propose_send`.
5. Build `withdrawCollateral(marketParams, collateralAmount,
   onBehalf=msg.sender, receiver=msg.sender)`. Read `position(id,
   user)` to size `collateralAmount` to the full collateral.
6. `tx.simulate` → `propose_send`.

## Recipe: supply loan asset to earn yield

Goal: deposit `assets` of `loanToken` to earn from borrowers'
interest.

1. Compute `id` and verify market.
2. Allowance dance for `loanToken` to MorphoBlue.
3. Build `supply(marketParams, assets, 0, onBehalf=msg.sender,
   data=0x)`.
4. `tx.simulate` → `propose_send`.
5. To exit: build `withdraw(marketParams, 0, supplyShares,
   onBehalf=msg.sender, receiver=msg.sender)`. Note that withdrawing
   when borrowers have pulled all liquidity reverts; surface the
   market's utilization first.

## Recipe: deposit into a MetaMorpho vault

A MetaMorpho vault is an ERC-4626. The wallet treats it as a
standard 4626 deposit:

1. Allowance dance for the vault's underlying asset to the vault.
2. Build `vault.deposit(assets, receiver=msg.sender)`.
3. `tx.simulate` → `propose_send`.

The wallet should also surface the vault's `curator`, `guardian`,
`timelock`, and the list of allocated markets (via the vault's
allocator events / view methods) before depositing. That is
out-of-band from the on-chain calldata.

## Recipe: deploy a new MetaMorpho vault

1. Build `MetaMorphoFactory.createMetaMorpho(initialOwner,
   initialTimelock, asset, name, symbol, salt)`.
2. **Refuse if `initialTimelock = 0`** (or below 1 day, depending
   on user policy).
3. `tx.simulate` → `propose_send`.
4. Post-deploy: surface the new vault's deterministic CREATE2
   address.

## Refusal triggers

* `oracle` or `irm` not on user's trusted list.
* Post-borrow / post-withdraw position below 1.05× LLTV.
* Non-empty `data` field on any Blue user call from an EOA.
* `setAuthorizationWithSig` whose typed-data does not fully
  decode in the ConfirmGate.
* MetaMorpho `createMetaMorpho` with `initialTimelock = 0`.

## Cross-reference

* `bridge/clearsign/registry/erc20.json` — every allowance leg.
* No dedicated 7730 descriptor for Morpho Blue yet. The wallet
  falls back to ABI-decoded view; that descriptor would be worth
  adding upstream.
