# Own Protocol v2 — Security Audit Report

**Date**: March 31, 2026
**Auditor**: Claude Opus 4.6 (Automated Security Audit)
**Scope**: All 11 Solidity smart contracts in `src/`
**Solidity Version**: 0.8.28 (pinned)
**Framework**: Foundry (forge)
**Commit**: `44a4f8a` (branch: main)

---

## Executive Summary

This report presents findings from a comprehensive security audit of Own Protocol v2, a permissionless DeFi protocol for tokenized real-world assets (RWAs). The audit covered 11 smart contracts (~4,700 lines of Solidity) using multiple methodologies: manual line-by-line code review, automated static analysis, specification compliance verification, entry-point analysis, and Trail of Bits security tooling.

**Critical findings require immediate attention before mainnet deployment.** The most severe issue is unrestricted ERC-4626 `withdraw()`/`redeem()` functions that bypass the entire withdrawal queue system, allowing LPs to withdraw without wait periods or utilization checks.

### Findings Summary

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 5 |
| Medium | 8 |
| Low | 6 |
| Informational | 8 |
| **Total** | **28** |

---

## Scope & Methodology

### Contracts Audited

| Contract | Path | Lines |
|----------|------|-------|
| OwnMarket | `src/core/OwnMarket.sol` | 703 |
| OwnVault | `src/core/OwnVault.sol` | 1067 |
| EToken | `src/tokens/EToken.sol` | 237 |
| OracleVerifier | `src/core/OracleVerifier.sol` | 183 |
| PythOracleVerifier | `src/core/PythOracleVerifier.sol` | 189 |
| AssetRegistry | `src/core/AssetRegistry.sol` | 175 |
| FeeCalculator | `src/core/FeeCalculator.sol` | 115 |
| ProtocolRegistry | `src/core/ProtocolRegistry.sol` | 157 |
| VaultFactory | `src/core/VaultFactory.sol` | 53 |
| WETHRouter | `src/periphery/WETHRouter.sol` | 83 |
| WstETHRouter | `src/periphery/WstETHRouter.sol` | 124 |

### Methodology

1. **Entry-Point Analysis** — Mapped all state-changing functions by access level
2. **Deep Function Analysis** — Ultra-granular line-by-line review of critical functions
3. **Specification Compliance** — Compared `docs/protocol.md` against implementation
4. **Static Analysis** — Semgrep scans for known vulnerability patterns
5. **Trail of Bits Tooling** — Code maturity assessment, token integration analysis, guidelines review
6. **Manual Review** — Focus on order state machine, ERC-4626 accounting, oracle security, fee distribution

---

## Findings

---

### [C-01] Unrestricted `withdraw()` and `redeem()` Bypass Withdrawal Queue

**Severity**: Critical
**Contract**: OwnVault.sol
**Functions**: `withdraw()` (L994-1000), `redeem()` (L1002-1008)
**Status**: Open

#### Description

The `withdraw()` and `redeem()` functions are public with no access control modifiers — no `onlyVM`, no `nonReentrant`, no vault status check, and no utilization check. They delegate directly to OpenZeppelin's `super.withdraw()` / `super.redeem()`, which burn shares and transfer collateral to the caller.

This allows any LP to withdraw collateral **immediately** without:
- Using the async withdrawal queue (`requestWithdrawal` → `fulfillWithdrawal`)
- Waiting for the mandatory `_withdrawalWaitPeriod`
- Passing the utilization check that protects vault solvency
- Auto-claiming LP rewards before exit

#### Impact

- The entire withdrawal queue system is rendered meaningless — any LP can bypass it
- The `_maxUtilization` guard is circumvented, potentially draining collateral below safe levels while orders are outstanding
- LP rewards may be lost (no auto-claim on direct withdrawal)
- Undermines the protocol's risk management model where the VM manages withdrawal timing

#### Proof of Concept

```solidity
// LP directly calls withdraw, bypassing the entire queue
vault.withdraw(assets, receiver, owner);
// Or equivalently:
vault.redeem(shares, receiver, owner);
```

#### Recommendation

Add access control and safety checks to `withdraw()` and `redeem()`:

```solidity
function withdraw(uint256 assets, address receiver, address own)
    public override(ERC4626, IERC4626) onlyVM nonReentrant returns (uint256) {
    return super.withdraw(assets, receiver, own);
}

function redeem(uint256 shares, address receiver, address own)
    public override(ERC4626, IERC4626) onlyVM nonReentrant returns (uint256) {
    return super.redeem(shares, receiver, own);
}
```

Or if direct withdrawal should be fully disabled:

```solidity
function withdraw(...) public override returns (uint256) {
    revert("Use requestWithdrawal");
}
function redeem(...) public override returns (uint256) {
    revert("Use requestWithdrawal");
}
```

---

### [H-01] Open Redeem Order Force-Execute Can Release Untracked Collateral

**Severity**: High
**Contract**: OwnMarket.sol
**Functions**: `forceExecute()` (L297-362), `_forceExecuteAtSetPrice()` (L504-537)
**Status**: Open

#### Description

When an unclaimed (Open) redeem order is force-executed and the price is reachable, `_forceExecuteAtSetPrice()` calls `vaultContract.releaseCollateral()` to send collateral to the user. However, since the order was never claimed, `updateExposure()` was never called to increase the vault's exposure tracking. The exposure reduction at L349 is correctly skipped for open orders (`isClaimed` is false), but the collateral release at L532 still occurs.

This means the vault releases collateral without it ever being tracked as exposure, creating untracked collateral outflow.

#### Impact

- Vault collateral decreases without corresponding exposure tracking
- Utilization calculations become inaccurate (understated)
- LP share price decreases without the vault's health metrics reflecting it

#### Proof of Concept

1. User places a redeem order (Open status)
2. No VM claims it within `claimThreshold`
3. User calls `forceExecute()` with valid price proofs showing price was reachable
4. `_forceExecuteAtSetPrice()` calls `releaseCollateral()` — collateral leaves the vault
5. But no exposure was ever tracked or reduced for this order

#### Recommendation

For open redeem orders force-executed at set price, either:
1. Track the exposure temporarily before releasing collateral, or
2. Add a dedicated code path that accounts for the collateral outflow in the vault's health metrics

---

### [H-02] Payment Token Can Equal Vault Collateral Asset Causing Double-Counting

**Severity**: High
**Contract**: OwnVault.sol
**Functions**: `setPaymentToken()` (L841-853), `depositFees()` (L713-738)
**Status**: Open

#### Description

There is no check preventing `_paymentToken` from being set to the same address as `asset()` (the vault's collateral token). When `_paymentToken == asset()`, fee deposits via `depositFees()` increase the vault's `IERC20(asset()).balanceOf(address(this))`, which is included in `totalAssets()`. This causes:

1. **Share price inflation**: Fee deposits increase `totalAssets()`, raising the share price for all LPs
2. **Double-counting of LP rewards**: LPs benefit from both share price appreciation (via increased totalAssets) AND the `_lpRewardsPerShare` accumulator

The LP share of fees is effectively counted twice — once through the ERC-4626 share price mechanism and once through the separate LP reward accumulator.

#### Impact

- LP rewards are overestimated when `_paymentToken == asset()`
- The vault may not have sufficient tokens to pay out all claimed LP rewards plus all share redemptions
- Protocol accounting becomes inconsistent

#### Recommendation

Add a check in `setPaymentToken()`:

```solidity
function setPaymentToken(address token) external onlyVM {
    if (token == address(0)) revert ZeroAddress();
    if (token == asset()) revert PaymentTokenCannotBeCollateral();
    // ... rest of function
}
```

---

### [H-03] ERC-4626 Inflation Attack — Weak Virtual Offset

**Severity**: High
**Contract**: OwnVault.sol
**Status**: Open

#### Description

OwnVault does not override `_decimalsOffset()`, so it returns 0 (OZ ERC4626 default). The OpenZeppelin v5 conversion formulas use `totalSupply() + 10^offset` = `totalSupply() + 1` and `totalAssets() + 1`. This provides minimal protection against the classic first-depositor inflation attack.

With a virtual offset of just 1:
- An attacker deposits 1 wei, gets 1 share
- Attacker donates X tokens directly to the vault, making `totalAssets = X + 1`, `totalSupply = 1`
- Next depositor of Y assets gets `Y * 2 / (X + 2)` shares
- For large X, the victim loses approximately half their deposit

While the async deposit mode (`_requireDepositApproval = true`) mitigates this by having the VM gate deposits, when `_requireDepositApproval = false`, the vault is vulnerable.

#### Impact

- First depositor can steal up to ~50% of the second depositor's funds
- Particularly dangerous for vaults using 6-decimal tokens (USDC, aUSDC) where the attack cost is lower

#### Recommendation

Override `_decimalsOffset()` to return a meaningful value:

```solidity
function _decimalsOffset() internal pure override returns (uint8) {
    return 6; // or higher for stronger protection
}
```

Or ensure `_requireDepositApproval` is always true initially and the VM seeds the vault with a minimum deposit.

---

### [H-04] Utilization Check Bypassed When Collateral Oracle Not Configured

**Severity**: High
**Contract**: OwnVault.sol
**Function**: `fulfillWithdrawal()` (L365-404)
**Status**: Open

#### Description

The utilization check in `fulfillWithdrawal()` at L382 has the condition:
```solidity
if (_totalExposureUSD > 0 && _collateralValueUSD > 0) {
```

If `_collateralValueUSD == 0` (which occurs when `_collateralOracleAsset` is not configured or `_refreshCollateralValue()` never finds a valid oracle), the entire utilization check is skipped for ALL withdrawals. This means:

1. If the admin doesn't set `_collateralOracleAsset`, utilization is never enforced on withdrawals
2. Even if exposure exists, withdrawals proceed unchecked

Combined with [C-01], this means all withdrawal paths can bypass utilization.

#### Impact

- Vault collateral can be drained below safe levels while exposure is outstanding
- Protocol solvency is at risk if large withdrawals occur during high utilization

#### Recommendation

Either:
1. Require `_collateralOracleAsset` to be set before the vault can accept deposits/orders, or
2. Block withdrawals when `_collateralValueUSD == 0` and exposure exists:
```solidity
if (_totalExposureUSD > 0 && _collateralValueUSD == 0) {
    revert CollateralValueNotInitialized();
}
```

---

### [H-05] Force Execution Charges Fees — Spec Mandates Zero Fees (VM Penalty)

**Severity**: High
**Contract**: OwnMarket.sol
**Functions**: `_forceExecuteAtSetPrice()` (L504-537), `_forceExecuteRedeemAtHaltPrice()` (L558-573)
**Status**: Open

#### Description

The protocol specification (`docs/protocol.md`, Section 7) explicitly states: *"When an order is force-executed, no fees are charged"* — this is intended as a VM penalty for failing to confirm within the grace period.

However, the implementation charges full fees during force execution:
- **Mint force-execute** (L512-518): Deposits the escrowed mint fee to the vault via `depositFees()`
- **Redeem force-execute** (L526-536): Calculates `feeBps` via `getRedeemFee()` and deducts `feeCollateral` from payout
- **Halt redeem force-execute** (L558-573): Also charges redeem fees

This is a direct contradiction of the specification.

#### Impact

- Users are unfairly penalized during force execution — they already suffer from VM non-performance
- The "VM penalty" mechanism described in the spec is not implemented
- Economic incentives are misaligned: force execution should disincentivize VM failure, but currently the user bears the cost

#### Recommendation

Either update the code to waive fees during force execution:
```solidity
// In _forceExecuteAtSetPrice for mints:
if (feeAmount > 0) {
    _escrowedMintFees[order.orderId] = 0;
    // Return fee to user instead of depositing to vault
    IERC20(paymentToken).safeTransfer(order.user, feeAmount);
}
```
Or update the spec to document that fees are charged on force execution and explain the rationale.

---

### [M-07] `confirmOrder()` Enforces Expiry on Claimed Orders — Not in Spec

**Severity**: Medium
**Contract**: OwnMarket.sol
**Function**: `confirmOrder()` (L194-225)
**Status**: Open

#### Description

`confirmOrder()` at L201 checks `if (block.timestamp > order.expiry) revert OrderExpiredError(orderId)`. The spec's state machine shows `CLAIMED → CONFIRMED` without any expiry condition — expiry is intended for unclaimed orders only.

This means if a VM claims an order near its expiry and needs time to hedge off-chain, the order may expire before confirmation. The user's funds are then stuck in a claimed-but-expired state, resolvable only via `closeOrder` or `forceExecute`.

#### Impact

- VM may lose the ability to confirm orders even after properly hedging
- Creates a race condition between hedging completion and order expiry
- May strand user funds requiring force execution

#### Recommendation

Either remove the expiry check for claimed orders or extend it by the grace period:
```solidity
if (order.status != OrderStatus.Claimed) revert InvalidOrderStatus(orderId, order.status);
// Remove: if (block.timestamp > order.expiry) revert OrderExpiredError(orderId);
```

---

### [M-08] No Paused → Halted Transition — Emergency Escalation Requires Two Steps

**Severity**: Medium
**Contract**: OwnVault.sol
**Functions**: `pause()` (L431-437), `haltVault()` (L470-474)
**Status**: Open

#### Description

Both `pause()` and `haltVault()` require the vault to be in `Active` status. There is no direct `Paused → Halted` transition. To escalate from Paused to Halted during an emergency, the admin must first call `unpause()` (Paused → Active) then `haltVault()` (Active → Halted).

During the brief window between unpause and halt, the vault is in Active status and all operations (including new orders) are permitted.

#### Impact

- In emergency scenarios, the two-step process creates a window where paused operations temporarily resume
- An attacker monitoring the mempool could front-run the `haltVault()` call with new orders during this window

#### Recommendation

Allow direct escalation from Paused to Halted:
```solidity
function haltVault() external onlyAdmin {
    if (_vaultStatus != VaultStatus.Active && _vaultStatus != VaultStatus.Paused) {
        revert InvalidStatusTransition();
    }
    _vaultStatus = VaultStatus.Halted;
    emit VaultHalted();
}
```

---

### [M-01] `depositFees()` Lacks `nonReentrant` Guard

**Severity**: Medium
**Contract**: OwnVault.sol
**Function**: `depositFees()` (L713-738)
**Status**: Open

#### Description

`depositFees()` performs an external `safeTransferFrom` call at L717 before updating state variables at L727-L735. While the function has an `onlyMarket` modifier, the payment token itself could have callbacks (e.g., ERC-777 tokens) that could re-enter the vault.

The function reads `totalSupply()` at L731 and `registry.protocolShareBps()` at L720 — both could return different values if state changes occur during the callback.

#### Impact

Limited in practice because:
- `onlyMarket` restricts the caller to the trusted Market contract
- Standard stablecoins (USDC, USDT) don't have transfer callbacks

However, the protocol supports arbitrary payment tokens set by the VM.

#### Recommendation

Add `nonReentrant` to `depositFees()` or move the `safeTransferFrom` to after state updates (CEI pattern).

---

### [M-02] `verifyPrice()` Has No Staleness or Deviation Checks

**Severity**: Medium
**Contract**: OracleVerifier.sol
**Function**: `verifyPrice()` (L122-136)
**Status**: Open

#### Description

Unlike `updatePrice()` which enforces staleness and deviation bounds, `verifyPrice()` only checks the ECDSA signature and non-zero price. An authorized signer could produce a valid signature for any historical price at any timestamp, and `verifyPrice()` would accept it.

The OwnMarket's `_verifyPriceRange()` function does check that proof timestamps fall within the [windowStart, block.timestamp] window, but does not enforce the oracle's per-asset `maxStaleness` or `maxDeviation` bounds.

#### Impact

During force execution, a user could submit oracle proofs with extreme prices (within the time window) that benefit them, as long as those prices were legitimately signed. A compromised signer could sign arbitrary historical prices.

#### Recommendation

Consider adding minimal staleness checks to `verifyPrice()`, or document clearly that callers must independently enforce time bounds. The time window check in `_verifyPriceRange()` partially mitigates this but should be reviewed for completeness.

---

### [M-03] Escrowed Withdrawal Shares Dilute LP Rewards

**Severity**: Medium
**Contract**: OwnVault.sol
**Functions**: `depositFees()` (L731), `_update()` (L882-890)
**Status**: Open

#### Description

When LPs request withdrawals, their shares are transferred to `address(this)`. The `_update()` override explicitly excludes `address(this)` from LP reward settlement (L883, L886), meaning these escrowed shares never accrue rewards.

However, `totalSupply()` still includes these escrowed shares. When `depositFees()` computes `_lpRewardsPerShare` at L735:
```solidity
_lpRewardsPerShare += lpAmount.mulDiv(PRECISION, supply);
```

The `supply` includes escrowed shares. The LP reward increment is diluted by shares that can never claim those rewards. These "phantom rewards" are permanently locked in the contract.

#### Impact

- LP rewards are systematically underpaid relative to the intended distribution
- The longer shares are escrowed (long wait periods), the more rewards are lost
- Lost rewards accumulate in the contract as unclaimable dust

#### Recommendation

Use effective supply (excluding escrowed shares) for reward distribution:
```solidity
uint256 effectiveSupply = totalSupply() - _pendingWithdrawalShares;
if (effectiveSupply == 0) {
    _protocolFees += lpAmount;
} else if (lpAmount > 0) {
    _lpRewardsPerShare += lpAmount.mulDiv(PRECISION, effectiveSupply);
}
```

---

### [M-04] No Deadline or Price Protection on Async Deposit Requests

**Severity**: Medium
**Contract**: OwnVault.sol
**Functions**: `requestDeposit()` (L234-256), `acceptDeposit()` (L259-273)
**Status**: Open

#### Description

When an LP requests a deposit via `requestDeposit()`, there is no deadline parameter and no minimum shares guarantee. The VM controls when (or if) to call `acceptDeposit()`. Between request and acceptance, the share price can change due to:
- Other deposits being accepted
- `releaseCollateral()` decreasing totalAssets (from force executions)
- Fee deposits changing totalAssets (if `_paymentToken == asset()`)
- Token donations

The depositor has no recourse if the share price moves significantly before acceptance.

#### Impact

- Depositors may receive fewer shares than expected
- A malicious or negligent VM could delay acceptance until after unfavorable price movements
- No timeout mechanism — deposits can remain pending indefinitely

#### Recommendation

Add deadline and minimum shares parameters to `requestDeposit()`:
```solidity
function requestDeposit(
    uint256 assets,
    address receiver,
    uint256 minShares,
    uint256 deadline
) external ...
```

And validate in `acceptDeposit()`:
```solidity
if (block.timestamp > req.deadline) revert DepositRequestExpired(requestId);
if (shares < req.minShares) revert InsufficientShares(shares, req.minShares);
```

---

### [M-05] `forceExecute()` Sweeps All Pre-Existing ETH to Caller

**Severity**: Medium
**Contract**: OwnMarket.sol
**Function**: `forceExecute()` (L356-361)
**Status**: Open

#### Description

At the end of `forceExecute()`, the contract sweeps its entire ETH balance to the caller:
```solidity
uint256 remaining = address(this).balance;
if (remaining > 0) {
    (bool ok,) = payable(msg.sender).call{value: remaining}("");
}
```

Any ETH that was previously in the contract (from selfdestructs, coinbase rewards, accidental transfers, or prior failed refunds) is swept to the next `forceExecute` caller.

#### Impact

- ETH sent to OwnMarket by any means (including accidental transfers) can be claimed by any user who calls `forceExecute`
- While amounts are likely small, this is unintended behavior

#### Recommendation

Track ETH received per call and only refund the excess:
```solidity
uint256 ethBefore = address(this).balance - msg.value; // snapshot before
// ... execution logic ...
uint256 remaining = address(this).balance - ethBefore;
if (remaining > 0) { ... refund ... }
```

---

### [M-06] `closeOrder()` Requires VM to Re-Approve Stablecoins After Spending

**Severity**: Medium
**Contract**: OwnMarket.sol
**Function**: `closeOrder()` (L228-263)
**Status**: Open

#### Description

When a VM closes a claimed mint order (returning funds to user), `closeOrder()` uses `safeTransferFrom(msg.sender, order.user, order.amount - feeAmount)` at L247. This requires:
1. The VM still holds the stablecoins (received during claim)
2. The VM has approved OwnMarket to spend them

In the normal flow, the VM receives stablecoins at claim time and immediately uses them for off-chain hedging. If the VM spent the stablecoins, `closeOrder` will revert. The user's only recourse is `forceExecute()`, which takes collateral from the vault instead.

While this is by design, it creates a confusing UX where `closeOrder` appears available but is not functional when the VM has already hedged.

#### Impact

- `closeOrder` for mint orders is effectively a cooperative path that only works when the VM hasn't spent the stablecoins
- Users may attempt `closeOrder` and waste gas before falling back to `forceExecute`
- The function signature doesn't communicate this limitation

#### Recommendation

Document this behavior clearly in the interface. Consider adding a view function `canCloseOrder(uint256 orderId)` that checks if the VM has sufficient balance and approval.

---

### [L-01] OracleVerifier `verifyPrice()` Traps ETH

**Severity**: Low
**Contract**: OracleVerifier.sol
**Function**: `verifyPrice()` (L122-136)
**Status**: Open

#### Description

`verifyPrice()` is `payable` (to satisfy the `IOracleVerifier` interface shared with PythOracleVerifier), but the in-house oracle never uses ETH. Any ETH sent to this function is permanently locked in the contract, as there is no withdrawal mechanism.

#### Impact

Minor ETH loss if callers send ETH to the wrong oracle implementation.

#### Recommendation

Add a check:
```solidity
if (msg.value > 0) revert NoETHRequired();
```

---

### [L-02] `updatePrice()` Silent Return Masks Failed Batch Updates

**Severity**: Low
**Contract**: OracleVerifier.sol
**Function**: `updatePrice()` (L57-93)
**Status**: Open

#### Description

When the submitted price timestamp is not newer than the existing one (L76), the function returns silently — no revert, no event. In batch updates via Multicall, some prices may be silently dropped without the caller knowing.

#### Impact

Keeper implementations may not detect that their submitted prices were ignored, leading to stale cached prices.

#### Recommendation

Emit an event on the silent return path:
```solidity
if (existing.timestamp > 0 && timestamp <= existing.timestamp) {
    emit PriceUpdateSkipped(asset, timestamp, existing.timestamp);
    return;
}
```

---

### [L-03] PythOracleVerifier Extreme Exponent Handling

**Severity**: Low
**Contract**: PythOracleVerifier.sol
**Function**: `_normalizePythPrice()` (L172-188)
**Status**: Open

#### Description

1. **Positive exponents**: If `expo >= 0`, the function computes `rawPrice * 10^(18 + expo)`. For `expo > 59`, this overflows uint256 and reverts. While not realistic for current Pyth feeds, it's an unhandled edge case.
2. **Large negative exponents**: If `absExpo > 18`, the function divides `rawPrice / 10^(absExpo - 18)`. For very large `absExpo`, this truncates to zero. Neither `getPrice()` nor `verifyPrice()` check for zero returns from `_normalizePythPrice`.
3. **`expo == type(int32).min`**: The `-expo` operation at L181 would cause int32 overflow, reverting.

#### Impact

Unlikely in practice with legitimate Pyth feeds, but edge cases could cause unexpected reverts or zero-price returns.

#### Recommendation

Add range validation:
```solidity
if (expo > 18 || expo < -36) revert ExponentOutOfRange(expo);
```

---

### [L-04] `releaseCollateral()` Emits No Event

**Severity**: Low
**Contract**: OwnVault.sol
**Function**: `releaseCollateral()` (L984-988)
**Status**: Open

#### Description

The `releaseCollateral()` function transfers collateral tokens out of the vault but emits no event. While the calling OwnMarket contract emits its own events, the vault-side collateral release is silent, making it harder to audit asset flows from vault events alone.

#### Impact

Reduced observability for monitoring systems that track vault collateral movements.

#### Recommendation

Add an event:
```solidity
event CollateralReleased(address indexed to, uint256 amount);
```

---

### [L-05] `ProtocolRegistry.setProtocolShareBps()` Uses String Revert

**Severity**: Low
**Contract**: ProtocolRegistry.sol
**Function**: `setProtocolShareBps()` (L94-99)
**Status**: Open

#### Description

This function uses `require(shareBps <= 10_000, "ProtocolRegistry: share > 100%")` — a string-based require — while the rest of the protocol consistently uses custom errors. This is inconsistent and slightly more expensive in gas.

#### Impact

Minor gas inefficiency and style inconsistency.

#### Recommendation

Replace with a custom error:
```solidity
if (shareBps > BPS) revert ShareTooHigh(shareBps, BPS);
```

---

### [I-01] EToken Double Settlement in `mint()` and `burn()` Wastes Gas

**Severity**: Informational
**Contract**: EToken.sol
**Functions**: `mint()` (L118-126), `burn()` (L129-136)
**Status**: Open

#### Description

Both `mint()` and `burn()` explicitly call `_settleRewards()` before calling `_mint()`/`_burn()`. However, `_mint()`/`_burn()` trigger `_update()` which also calls `_settleRewards()`. The second call is always a no-op (owed = 0 since checkpoint was just updated), wasting ~2,600 gas per operation.

#### Recommendation

Remove the explicit `_settleRewards()` calls from `mint()` and `burn()`, relying on the `_update()` override.

---

### [I-02] EToken `_settleRewards()` Contains Dead Code Branch

**Severity**: Informational
**Contract**: EToken.sol
**Function**: `_settleRewards()` (L225-236)
**Status**: Open

#### Description

The `else if` at L233 (`_userRewardsPerSharePaid[account] != _rewardsPerShare`) is unreachable. When `owed == 0` (the `if` at L229 is false), by definition `_rewardsPerShare == _userRewardsPerSharePaid[account]`, making the `else if` condition always false.

#### Recommendation

Remove the dead branch for clarity:
```solidity
function _settleRewards(address account) private {
    uint256 owed = _rewardsPerShare - _userRewardsPerSharePaid[account];
    if (owed > 0) {
        _accruedRewards[account] += balanceOf(account).mulDiv(owed, PRECISION);
        _userRewardsPerSharePaid[account] = _rewardsPerShare;
    }
}
```

---

### [I-03] EToken `depositRewards()` Uses String Require Instead of Custom Error

**Severity**: Informational
**Contract**: EToken.sol
**Function**: `depositRewards()` (L170)
**Status**: Open

#### Description

`require(supply > 0, "EToken: no supply")` uses a string-based require while the rest of the contract uses custom errors. Inconsistent style and slightly higher gas cost.

#### Recommendation

Replace with: `if (supply == 0) revert NoSupply();`

---

### [I-04] Small Reward Deposits Can Silently Produce Zero Accumulator Increment

**Severity**: Informational
**Contract**: EToken.sol
**Function**: `depositRewards()` (L175)
**Status**: Open

#### Description

The accumulator increment `amount.mulDiv(PRECISION, supply)` truncates to zero when `amount * PRECISION < supply`. For a token with `totalSupply = 1e27` (1 billion at 18 decimals), any USDC reward deposit below ~1,000 USDC would produce a zero increment. The tokens are transferred but become permanently unclaimable dust.

#### Recommendation

Add a minimum effective deposit check:
```solidity
uint256 increment = amount.mulDiv(PRECISION, supply);
if (increment == 0) revert DepositTooSmall();
```

---

### [I-05] `executeTimelock()` in ProtocolRegistry Is Permissionless

**Severity**: Informational
**Contract**: ProtocolRegistry.sol
**Function**: `executeTimelock()` (L127-139)
**Status**: Open

#### Description

`executeTimelock()` has no `onlyOwner` modifier — anyone can execute a pending timelock after the delay expires. This is a common pattern (the security comes from the propose step, not the execute step), but it means a malicious proposed change that was not cancelled in time can be executed by anyone.

#### Recommendation

This is an accepted design pattern. Ensure monitoring is in place to detect and cancel unwanted proposals before the timelock expires.

---

## Entry Point Summary

### Public (Unrestricted) — 14 functions

| Function | Contract | Notes |
|----------|----------|-------|
| `placeMintOrder()` | OwnMarket | Escrows stablecoins |
| `placeRedeemOrder()` | OwnMarket | Escrows eTokens |
| `cancelOrder()` | OwnMarket | Only order owner |
| `forceExecute()` | OwnMarket | Only order owner, after grace period |
| `expireOrder()` | OwnMarket | Anyone, after expiry |
| `requestDeposit()` | OwnVault | LP deposits collateral |
| `cancelDeposit()` | OwnVault | Only depositor |
| `requestWithdrawal()` | OwnVault | LP escrows shares |
| `cancelWithdrawal()` | OwnVault | Only request owner |
| `fulfillWithdrawal()` | OwnVault | Anyone, after wait period |
| `deposit()` | OwnVault | ERC-4626 (when approval not required) |
| `withdraw()` / `redeem()` | OwnVault | **UNRESTRICTED** [C-01] |
| `claimProtocolFees()` | OwnVault | Anyone can trigger (sends to treasury) |
| `claimLPRewards()` | OwnVault | Claims caller's own rewards |
| `depositRewards()` | EToken | Anyone can deposit dividends |
| `claimRewards()` | EToken | Claims caller's own rewards |
| `updatePrice()` | OracleVerifier | Requires valid signature |
| `updateAssetValuation()` | OwnVault | Permissionless oracle refresh |
| `updateCollateralValuation()` | OwnVault | Permissionless oracle refresh |

### VM-Restricted — 8 functions

| Function | Contract | Restriction |
|----------|----------|-------------|
| `claimOrder()` | OwnMarket | `vault.vm() == msg.sender` |
| `confirmOrder()` | OwnMarket | `order.vm == msg.sender` |
| `closeOrder()` | OwnMarket | `order.vm == msg.sender` |
| `acceptDeposit()` | OwnVault | `onlyVM` |
| `rejectDeposit()` | OwnVault | `onlyVM` |
| `claimVMFees()` | OwnVault | `onlyVM` |
| `setVMShareBps()` | OwnVault | `onlyVM` |
| `enableAsset()` / `disableAsset()` | OwnVault | `onlyVM` |
| `setPaymentToken()` | OwnVault | `onlyVM` |

### Admin-Restricted — 18 functions

| Function | Contract | Restriction |
|----------|----------|-------------|
| `pause()` / `unpause()` | OwnVault | `onlyAdmin` |
| `haltVault()` / `unhalt()` | OwnVault | `onlyAdmin` |
| `pauseAsset()` / `unpauseAsset()` | OwnVault | `onlyAdmin` |
| `haltAsset()` / `unhaltAsset()` | OwnVault | `onlyAdmin` |
| `setMaxUtilization()` | OwnVault | `onlyAdmin` |
| `setWithdrawalWaitPeriod()` | OwnVault | `onlyAdmin` |
| `setGracePeriod()` / `setClaimThreshold()` | OwnVault | `onlyAdmin` |
| `setCollateralOracleAsset()` | OwnVault | `onlyAdmin` |
| `setRequireDepositApproval()` | OwnVault | `onlyAdmin` |
| `addAsset()` / `deactivateAsset()` / `migrateToken()` | AssetRegistry | `onlyOwner` |
| `setMintFee()` / `setRedeemFee()` | FeeCalculator | `onlyOwner` |
| `addSigner()` / `removeSigner()` | OracleVerifier | `onlyOwner` |
| `setAddress()` / `proposeAddress()` | ProtocolRegistry | `onlyOwner` |
| `createVault()` | VaultFactory | `onlyOwner` |

### Market-Only — 3 functions

| Function | Contract | Restriction |
|----------|----------|-------------|
| `updateExposure()` | OwnVault | `onlyMarket` |
| `depositFees()` | OwnVault | `onlyMarket` |
| `releaseCollateral()` | OwnVault | `onlyMarket` |

---

## Positive Observations

The following security practices are well-implemented:

1. **CEI Pattern**: Generally followed across the codebase with `nonReentrant` guards on most state-changing functions
2. **SafeERC20**: All token transfers use OpenZeppelin's SafeERC20 wrapper
3. **Custom Errors**: Gas-efficient error handling throughout (with minor exceptions noted)
4. **Pinned Solidity Version**: 0.8.28 with native overflow protection
5. **Oracle Domain Separation**: ECDSA signatures include chainId and contract address, preventing cross-chain/cross-contract replay
6. **Timelock Governance**: Critical protocol parameter changes require a 2-day delay
7. **Monotonic Timestamps**: Oracle price updates enforce strictly increasing timestamps
8. **Fee Cap Enforcement**: FeeCalculator enforces a maximum 500 BPS (5%) cap
9. **Per-Share Accumulators**: Both EToken rewards and LP fee rewards use mathematically sound rewards-per-share patterns
10. **Comprehensive Test Suite**: 26 test files across unit, integration, and invariant categories

---

## Recommendations Summary

### Immediate (Pre-Deployment)

1. **[C-01]** Restrict or disable `withdraw()` and `redeem()` on OwnVault
2. **[H-01]** Fix untracked collateral release for open redeem force-execution
3. **[H-02]** Prevent `_paymentToken == asset()`
4. **[H-03]** Increase `_decimalsOffset()` for inflation attack protection
5. **[H-04]** Enforce collateral oracle configuration or block withdrawals when unset
6. **[H-05]** Resolve force execution fee charging vs spec's zero-fee mandate

### Short-Term

7. **[M-01]** Add `nonReentrant` to `depositFees()`
8. **[M-03]** Use effective supply for LP reward distribution
9. **[M-04]** Add deadline and minimum shares to deposit requests
10. **[M-05]** Track ETH per-call in `forceExecute()`
11. **[M-07]** Review expiry enforcement on claimed orders
12. **[M-08]** Allow direct Paused → Halted transition

### Maintenance

10. Clean up dead code in `_settleRewards()` [I-02]
11. Remove redundant `_settleRewards()` calls in `mint()`/`burn()` [I-01]
12. Standardize error handling (replace string reverts) [I-03], [L-05]
13. Add events to `releaseCollateral()` [L-04]
14. Add minimum deposit check to `depositRewards()` [I-04]

---

---

### [L-06] OwnMarket Lacks `receive()` — Pyth ETH Refunds May Fail

**Severity**: Low
**Contract**: OwnMarket.sol
**Status**: Open

#### Description

OwnMarket has no `receive()` or `fallback()` function. While `forceExecute()` is `payable` (accepting ETH from the caller), if the Pyth oracle or any intermediary attempts to refund excess ETH to the OwnMarket contract, the transfer would revert.

The current code pre-calculates exact fees via `verifyFee()` before each `verifyPrice{value: fee}()` call, so in practice the exact amount is forwarded. However, if Pyth's behavior changes or if rounding causes a mismatch, ETH refunds to OwnMarket would fail.

#### Recommendation

Add a minimal `receive()`:
```solidity
receive() external payable {}
```

The existing ETH sweep at the end of `forceExecute()` would then handle any refunded ETH.

---

### [I-06] Missing Events on Admin Parameter Changes

**Severity**: Informational (but important for monitoring)
**Contracts**: OwnVault.sol, AssetRegistry.sol, OracleVerifier.sol
**Status**: Open

#### Description

Several admin setter functions do not emit events, creating monitoring blind spots:

| Function | File | Line |
|----------|------|------|
| `setMaxUtilization()` | OwnVault.sol | 553 |
| `setWithdrawalWaitPeriod()` | OwnVault.sol | 662 |
| `setGracePeriod()` | OwnVault.sol | 678 |
| `setClaimThreshold()` | OwnVault.sol | 690 |
| `setCollateralOracleAsset()` | OwnVault.sol | 702 |
| `setOracleConfig()` | AssetRegistry.sol | 144 |
| `setAssetOracleConfig()` | OracleVerifier.sol | 179 |

A compromised or malicious admin could silently change critical protocol parameters without any on-chain trace.

#### Recommendation

Add events to all admin setters that modify protocol parameters.

---

### [I-07] Unbounded `_userOrders` Array Is Append-Only

**Severity**: Informational
**Contract**: OwnMarket.sol
**Line**: 98
**Status**: Open

#### Description

Unlike `_openOrders` which uses swap-and-pop removal, `_userOrders[user]` only grows (pushed at L98, never cleaned up). Over time, `getUserOrders()` becomes unusable for active users as the array grows without bound.

#### Recommendation

Either implement removal on order finalization, or remove the on-chain array and rely on event indexing for historical queries.

---

### [I-08] PythOracleVerifier Has 0% Test Coverage

**Severity**: Informational (but critical for production readiness)
**Contract**: PythOracleVerifier.sol
**Status**: Open

#### Description

The Trail of Bits guidelines assessment found that PythOracleVerifier has **zero** test coverage — no unit or integration tests. This contract handles real-money oracle price verification, and any bug in `_normalizePythPrice()` or `verifyPrice()` could lead to incorrect minting/redemption amounts.

#### Recommendation

Write a full unit test suite covering: negative exponents, extreme prices, zero-price rejection, feed-not-configured scenarios, and normalization edge cases. Add fork tests against real Pyth on Base.

---

## Appendix A: Code Maturity Assessment (Trail of Bits Framework)

**Overall Score: 2.6 / 4.0 (Moderate-to-Satisfactory)**

| Category | Score | Notes |
|----------|-------|-------|
| **Arithmetic** | 3/4 | Consistent `Math.mulDiv`, documented rounding, Solidity 0.8 overflow protection |
| **Access Controls** | 3/4 | Clear role modifiers (`onlyAdmin`, `onlyVM`, `onlyMarket`), timelock governance |
| **Documentation** | 3/4 | Comprehensive protocol docs (482 lines), developer guide (608 lines), NatSpec coverage |
| **Testing** | 3/4 | 440 passing tests, 11 invariants with ghost variables, integration coverage |
| **Low-Level Code** | 4/4 | No assembly, no delegatecall, only one justified `.call` for ETH refund |
| **Complexity** | 2/4 | OwnVault.sol at 1,067 LOC handles too many responsibilities |
| **Decentralization** | 2/4 | Single oracle signer (MVP), no on-chain multisig enforcement, admin halt power |
| **MEV** | 2/4 | Escrow model helps, but no commit-reveal for orders, no VM-MEV protection |
| **Auditing** | 1/4 | No prior external audit, no Slither CI integration, no monitoring infrastructure |

### Top 5 Pre-Mainnet Actions

1. Professional security audit from an established firm
2. Integrate Slither into CI pipeline
3. Build monitoring and incident response infrastructure
4. Fork tests against real Base mainnet tokens (USDC, WETH, wstETH)
5. Migrate to multi-signer oracle architecture

---

## Appendix B: Static Analysis Results (Semgrep)

**Tool**: Semgrep v1.156.0
**Mode**: Important only (high-confidence security vulnerabilities)
**Rulesets**: `p/security-audit`, `p/smart-contracts`, `p/owasp-top-ten`, `p/trailofbits`, `r/solidity`, `r/solidity.security`

### Security Vulnerabilities Found: 0

No high-confidence security vulnerabilities (ERROR/WARNING severity) were detected by any ruleset.

### Informational Findings: 51

| Rule | Count | Description |
|------|-------|-------------|
| `use-ownable2step` | 6 | Recommend `Ownable2Step` over `Ownable` for safer ownership transfers |
| `non-payable-constructor` | 11 | Payable constructors save deployment gas |
| `use-nested-if` | 10 | Nested `if` cheaper than `&&` in conditionals |
| `state-variable-read-in-a-loop` | 8 | Cache state variables outside loops in OwnVault |
| `inefficient-state-variable-increment` | 7 | `x = x + y` cheaper than `x += y` for state vars |
| `use-custom-error-not-require` | 6 | Custom errors more gas-efficient than `require` strings |
| `use-short-revert-string` | 2 | Revert strings should fit in 32 bytes |
| `array-length-outside-loop` | 1 | Cache array length before loop in AssetRegistry |

**Recommendation**: Consider migrating all 6 `Ownable` contracts to `Ownable2Step` to prevent accidental ownership transfer to an incorrect address.

---

## Appendix C: Test Coverage

| Contract | Line % | Branch % | Function % |
|----------|--------|----------|------------|
| OwnMarket.sol | 91.69% | 75.61% | 96.15% |
| OwnVault.sol | 93.12% | 61.02% | 89.01% |
| EToken.sol | 98.53% | 86.67% | 100.00% |
| OracleVerifier.sol | 89.80% | 63.64% | 77.78% |
| AssetRegistry.sol | 93.10% | 53.33% | 92.31% |
| FeeCalculator.sol | 100.00% | 100.00% | 100.00% |
| ProtocolRegistry.sol | 100.00% | 88.89% | 100.00% |
| **PythOracleVerifier.sol** | **0.00%** | **0.00%** | **0.00%** |
| VaultFactory.sol | 84.62% | 0.00% | 75.00% |
| WETHRouter.sol | 100.00% | 100.00% | 100.00% |
| WstETHRouter.sol | 84.38% | 80.00% | 80.00% |

**Key gaps**: PythOracleVerifier at 0%, OwnVault branch coverage at 61%, AssetRegistry branch coverage at 53%.

---

*This report was generated using automated security analysis tools and manual code review. It should be used as supplementary input for a professional security audit. The findings represent the auditor's assessment at the time of review and may not cover all potential vulnerabilities.*
