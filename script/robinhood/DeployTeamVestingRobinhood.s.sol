// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeployTeamVestingRobinhood — Team token vesting on OpenZeppelin VestingWallet
/// @notice Deploys one unmodified OpenZeppelin `VestingWallet` (v5.6.1, covered by OpenZeppelin's
///         release audits under lib/openzeppelin-contracts/audits) per team member. Each wallet
///         vests whatever it holds linearly, per second, from `start` to `start + DURATION`
///         (6 × 30 days). No custom vesting logic.
///
///         The wallets are deployed EMPTY. The tokens sit in the Safe, which funds each wallet with
///         a plain ERC-20 `transfer` afterwards — the script prints that batch (target + calldata)
///         ready to paste into the Safe. The deployer never touches the tokens and holds no role
///         on any wallet: the only owner is the beneficiary, and `release(token)` pays them alone.
///
/// @dev Properties of VestingWallet worth knowing before funding:
///        - No clawback. Once funded, the tokens are irrevocably the beneficiary's on schedule.
///        - The beneficiary owns the wallet (`Ownable`) and can transfer ownership, i.e. sell the
///          unvested claim. OpenZeppelin documents this as inherent to the design.
///        - The schedule is anchored to `start`, not to the funding time. Tokens that arrive after
///          `start` are treated as if locked from `start`, so the elapsed share is releasable at
///          once. Fund before `start` for a clean linear curve.
///        - Vesting accrues from `start` with no cliff: a small amount is releasable right after
///          start. Swap in `VestingWalletCliff` if nothing should be releasable for the first month.
///
/// @dev Post-deploy checklist:
///        1. Verify on Blockscout: `owner()` is the beneficiary, `start()`/`end()` match the log.
///        2. Execute the printed Safe batch (one `transfer(wallet, amount)` per beneficiary) and
///           confirm each wallet's balance equals its allocation.
///        3. Record the wallet addresses in docs/contracts-robinhood.md.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD   — pays gas only
///      VESTING_TOKEN_ROBINHOOD          — ERC-20 being vested (no fee-on-transfer / rebasing)
///      VESTING_BENEFICIARIES_ROBINHOOD  — comma-separated addresses (the 5 team members)
///      VESTING_AMOUNTS_ROBINHOOD        — comma-separated allocations in raw token units, same
///                                         order; used only for the printed Safe batch
///      VESTING_START_ROBINHOOD          — optional unix timestamp vesting starts from
///                                         (defaults to the deploy block timestamp)
///
/// Usage:
///   forge script script/robinhood/DeployTeamVestingRobinhood.s.sol --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeployTeamVestingRobinhood is Script {
    uint256 public constant ROBINHOOD_CHAIN_ID = 4663;

    /// @notice Linear vesting window: 6 months of 30 days.
    uint64 public constant DURATION = 180 days;

    struct Config {
        uint256 deployerKey;
        IERC20 token;
        address[] beneficiaries;
        uint256[] amounts;
        uint256 start;
    }

    /// @notice Wallets created by the last run, in beneficiary order.
    VestingWallet[] public wallets;

    function run() external {
        Config memory cfg;
        cfg.deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD");
        cfg.token = IERC20(vm.envAddress("VESTING_TOKEN_ROBINHOOD"));
        cfg.beneficiaries = vm.envAddress("VESTING_BENEFICIARIES_ROBINHOOD", ",");
        cfg.amounts = vm.envUint("VESTING_AMOUNTS_ROBINHOOD", ",");
        cfg.start = vm.envOr("VESTING_START_ROBINHOOD", block.timestamp);
        runWith(cfg);
    }

    /// @notice Validates `cfg`, deploys one empty wallet per beneficiary, re-reads each on-chain and
    ///         prints the Safe funding batch.
    function runWith(
        Config memory cfg
    ) public {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");

        require(address(cfg.token).code.length > 0, "token is not a contract");
        require(cfg.beneficiaries.length > 0, "no beneficiaries");
        require(cfg.beneficiaries.length == cfg.amounts.length, "beneficiaries/amounts length mismatch");
        require(cfg.start >= block.timestamp, "start is in the past");
        require(cfg.start <= type(uint64).max - DURATION, "start does not fit uint64");
        uint64 start = uint64(cfg.start);
        uint64 endAt = start + DURATION;

        for (uint256 i = 0; i < cfg.beneficiaries.length; i++) {
            require(cfg.beneficiaries[i] != address(0), "zero beneficiary");
            require(cfg.amounts[i] > 0, "zero amount");
            for (uint256 j = 0; j < i; j++) {
                require(cfg.beneficiaries[i] != cfg.beneficiaries[j], "duplicate beneficiary");
            }
        }

        vm.startBroadcast(cfg.deployerKey);
        delete wallets;
        for (uint256 i = 0; i < cfg.beneficiaries.length; i++) {
            wallets.push(new VestingWallet(cfg.beneficiaries[i], start, DURATION));
        }
        vm.stopBroadcast();

        console.log("Token:        ", address(cfg.token));
        console.log("Start:        ", start);
        console.log("Fully vested: ", endAt);
        for (uint256 i = 0; i < wallets.length; i++) {
            VestingWallet wallet = wallets[i];
            require(wallet.owner() == cfg.beneficiaries[i], "wallet owner is not the beneficiary");
            require(wallet.start() == start, "wallet start mismatch");
            require(wallet.duration() == DURATION, "wallet duration mismatch");
            require(wallet.end() == endAt, "wallet end mismatch");
            require(cfg.token.balanceOf(address(wallet)) == 0, "wallet must be deployed empty");

            console.log("--- beneficiary", i);
            console.log("  address:   ", cfg.beneficiaries[i]);
            console.log("  wallet:    ", address(wallet));
            console.log("  allocation:", cfg.amounts[i]);
        }

        // Funding is done from the Safe: one plain ERC-20 transfer per wallet.
        console.log("=== Safe batch: fund the wallets ===");
        for (uint256 i = 0; i < wallets.length; i++) {
            console.log("target:", address(cfg.token));
            console.log("  transfer(wallet, amount) calldata:");
            console.logBytes(abi.encodeCall(IERC20.transfer, (address(wallets[i]), cfg.amounts[i])));
        }
    }
}
