// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title DeployTeamVestingRobinhood — Team token vesting on OpenZeppelin VestingWallet
/// @notice Deploys one unmodified OpenZeppelin `VestingWallet` (v5.6.1, covered by OpenZeppelin's
///         release audits under lib/openzeppelin-contracts/audits) per team member and funds it
///         from the deployer. Each wallet vests its full balance linearly, per second, from
///         `start` to `start + DURATION` (6 × 30 days). No custom vesting logic.
///         Anyone can call `release(token)` on a wallet; funds only ever go to the beneficiary.
///
/// @dev Properties of VestingWallet worth knowing before funding:
///        - No clawback. Once funded, the tokens are irrevocably the beneficiary's on schedule.
///        - The beneficiary owns the wallet (`Ownable`) and can transfer ownership, i.e. sell the
///          unvested claim. OpenZeppelin documents this as inherent to the design.
///        - Any tokens sent to a wallet later vest on the same curve.
///        - Vesting accrues from `start` with no cliff: a small amount is releasable right after
///          start. Swap in `VestingWalletCliff` if nothing should be releasable for the first month.
///
/// @dev Post-deploy checklist:
///        1. Record the wallet addresses in docs/contracts-robinhood.md.
///        2. Verify on Blockscout: `owner()` is the beneficiary, `start()`/`end()` match the
///           logged timestamps, `releasable(token)` grows linearly.
///        3. Beneficiaries call `release(token)` on their wallet whenever they like.
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD   — must hold the sum of all allocations
///      VESTING_TOKEN_ROBINHOOD          — ERC-20 being vested (no fee-on-transfer / rebasing)
///      VESTING_BENEFICIARIES_ROBINHOOD  — comma-separated addresses (the 5 team members)
///      VESTING_AMOUNTS_ROBINHOOD        — comma-separated allocations in raw token units, same order
///      VESTING_START_ROBINHOOD          — optional unix timestamp vesting starts from
///                                         (defaults to the deploy block timestamp)
///
/// Usage:
///   forge script script/robinhood/DeployTeamVestingRobinhood.s.sol --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
contract DeployTeamVestingRobinhood is Script {
    using SafeERC20 for IERC20;

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

    /// @notice Validates `cfg`, deploys and funds one wallet per beneficiary, then re-reads each on-chain.
    function runWith(
        Config memory cfg
    ) public {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");

        address deployer = vm.addr(cfg.deployerKey);
        require(address(cfg.token).code.length > 0, "token is not a contract");
        require(cfg.beneficiaries.length > 0, "no beneficiaries");
        require(cfg.beneficiaries.length == cfg.amounts.length, "beneficiaries/amounts length mismatch");
        require(cfg.start >= block.timestamp, "start is in the past");
        require(cfg.start <= type(uint64).max - DURATION, "start does not fit uint64");
        uint64 start = uint64(cfg.start);
        uint64 endAt = start + DURATION;

        uint256 total;
        for (uint256 i = 0; i < cfg.beneficiaries.length; i++) {
            require(cfg.beneficiaries[i] != address(0), "zero beneficiary");
            require(cfg.amounts[i] > 0, "zero amount");
            for (uint256 j = 0; j < i; j++) {
                require(cfg.beneficiaries[i] != cfg.beneficiaries[j], "duplicate beneficiary");
            }
            total += cfg.amounts[i];
        }
        require(cfg.token.balanceOf(deployer) >= total, "deployer lacks vesting tokens");

        vm.startBroadcast(cfg.deployerKey);
        delete wallets;
        for (uint256 i = 0; i < cfg.beneficiaries.length; i++) {
            // Deploy and fund in the same broadcast so no wallet is ever left empty between txs.
            VestingWallet wallet = new VestingWallet(cfg.beneficiaries[i], start, DURATION);
            cfg.token.safeTransfer(address(wallet), cfg.amounts[i]);
            wallets.push(wallet);
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
            require(cfg.token.balanceOf(address(wallet)) == cfg.amounts[i], "funding mismatch");
            require(wallet.released(address(cfg.token)) == 0, "nothing may be released at deploy");

            console.log("--- beneficiary", i);
            console.log("  address:   ", cfg.beneficiaries[i]);
            console.log("  allocation:", cfg.amounts[i]);
            console.log("  wallet:    ", address(wallet));
        }
    }
}
