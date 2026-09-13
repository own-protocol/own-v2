// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin-v5.3.0/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-v5.3.0/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISablierLockup} from "@sablier/lockup/src/interfaces/ISablierLockup.sol";
import {Lockup} from "@sablier/lockup/src/types/Lockup.sol";
import {LockupLinear} from "@sablier/lockup/src/types/LockupLinear.sol";

/// @title CreateTeamVestingRobinhood — Team vesting streams on Sablier Lockup (Robinhood Chain)
/// @notice Creates one Sablier Lockup Linear stream per team member with the schedule:
///           - nothing before month 1,
///           - 30% of the allocation unlocks at month 1 (the cliff), and
///           - the remaining 70% streams linearly, per second, over the following 6 months.
///         "Month" is fixed at 30 days: cliff = start + 30d, end = cliff + 180d.
///         Uses only the audited `createWithTimestampsLL` entry point with `unlockAmounts.cliff`;
///         no custom vesting code. Each stream is an ERC-721 owned by the beneficiary; they call
///         `withdrawMax(streamId, to)` on the Lockup whenever they like (no fee — see the deploy).
///
/// @dev Stream policy (env-overridable):
///        - cancelable = true  → the `sender` can cancel a stream (e.g. a departure); the recipient
///          keeps everything streamed so far and the rest is refunded to the sender. Set false for
///          irrevocable grants.
///        - transferable = false → the beneficiary cannot sell/transfer the stream NFT.
///        The `sender` defaults to the deployer; set it to the Safe so cancel rights sit with
///        governance. Funding always comes from the deployer (msg.sender of the create call).
///
/// Env: DEPLOYER_PRIVATE_KEY_ROBINHOOD   — funder; must hold the sum of all allocations
///      SABLIER_LOCKUP_ROBINHOOD         — SablierLockup from script/sablier/DeploySablierLockupRobinhood.s.sol
///      VESTING_TOKEN_ROBINHOOD          — ERC-20 being vested (no fee-on-transfer / rebasing)
///      VESTING_BENEFICIARIES_ROBINHOOD  — comma-separated addresses (the 5 team members)
///      VESTING_AMOUNTS_ROBINHOOD        — comma-separated allocations in raw token units, same order
///      VESTING_START_ROBINHOOD          — optional unix timestamp the schedule is anchored to
///                                         (defaults to the current block timestamp)
///      VESTING_SENDER_ROBINHOOD         — optional address with cancel rights (defaults to deployer)
///      VESTING_CANCELABLE_ROBINHOOD     — optional bool (default true)
///      VESTING_TRANSFERABLE_ROBINHOOD   — optional bool (default false)
///
/// Usage:
///   FOUNDRY_PROFILE=sablier forge script script/sablier/CreateTeamVestingRobinhood.s.sol --rpc-url robinhood --broadcast
contract CreateTeamVestingRobinhood is Script {
    using SafeERC20 for IERC20;

    uint256 public constant ROBINHOOD_CHAIN_ID = 4663;

    /// @notice Share of each allocation unlocked at the cliff (30%).
    uint256 public constant UPFRONT_BPS = 3000;
    uint256 public constant BPS = 10_000;

    /// @notice Month 1: nothing vests before this offset from `start`.
    uint40 public constant CLIFF = 30 days;
    /// @notice The remaining 70% streams linearly over 6 months after the cliff.
    uint40 public constant LINEAR_DURATION = 180 days;
    /// @notice Per-second streaming.
    uint40 public constant GRANULARITY = 1 seconds;

    struct Config {
        uint256 deployerKey;
        ISablierLockup lockup;
        IERC20 token;
        address[] beneficiaries;
        uint256[] amounts;
        uint256 start;
        address sender;
        bool cancelable;
        bool transferable;
    }

    /// @notice Stream IDs created by the last run, in beneficiary order.
    uint256[] public streamIds;

    function run() external {
        Config memory cfg;
        cfg.deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY_ROBINHOOD");
        cfg.lockup = ISablierLockup(vm.envAddress("SABLIER_LOCKUP_ROBINHOOD"));
        cfg.token = IERC20(vm.envAddress("VESTING_TOKEN_ROBINHOOD"));
        cfg.beneficiaries = vm.envAddress("VESTING_BENEFICIARIES_ROBINHOOD", ",");
        cfg.amounts = vm.envUint("VESTING_AMOUNTS_ROBINHOOD", ",");
        cfg.start = vm.envOr("VESTING_START_ROBINHOOD", block.timestamp);
        cfg.sender = vm.envOr("VESTING_SENDER_ROBINHOOD", vm.addr(cfg.deployerKey));
        cfg.cancelable = vm.envOr("VESTING_CANCELABLE_ROBINHOOD", true);
        cfg.transferable = vm.envOr("VESTING_TRANSFERABLE_ROBINHOOD", false);
        runWith(cfg);
    }

    /// @notice Validates `cfg`, funds and creates the streams, then re-reads every stream on-chain.
    function runWith(
        Config memory cfg
    ) public {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (4663)");

        address deployer = vm.addr(cfg.deployerKey);
        require(address(cfg.lockup).code.length > 0, "lockup is not a contract");
        require(address(cfg.token).code.length > 0, "token is not a contract");
        require(cfg.sender != address(0), "sender is zero");
        require(cfg.beneficiaries.length > 0, "no beneficiaries");
        require(cfg.beneficiaries.length == cfg.amounts.length, "beneficiaries/amounts length mismatch");
        require(cfg.start >= block.timestamp, "start is in the past");
        require(cfg.start <= type(uint40).max, "start does not fit uint40");
        uint40 start = uint40(cfg.start);

        uint256 total;
        for (uint256 i = 0; i < cfg.beneficiaries.length; i++) {
            require(cfg.beneficiaries[i] != address(0), "zero beneficiary");
            require(cfg.amounts[i] > 0, "zero amount");
            require(cfg.amounts[i] <= type(uint128).max, "amount does not fit uint128");
            for (uint256 j = 0; j < i; j++) {
                require(cfg.beneficiaries[i] != cfg.beneficiaries[j], "duplicate beneficiary");
            }
            total += cfg.amounts[i];
        }
        require(cfg.token.balanceOf(deployer) >= total, "deployer lacks vesting tokens");

        uint40 cliffAt = start + CLIFF;
        uint40 endAt = cliffAt + LINEAR_DURATION;

        vm.startBroadcast(cfg.deployerKey);
        cfg.token.forceApprove(address(cfg.lockup), total);
        delete streamIds;
        for (uint256 i = 0; i < cfg.beneficiaries.length; i++) {
            uint128 amount = uint128(cfg.amounts[i]);
            // Rounds the 30% tranche down; the dust streams linearly so the total is exact.
            uint128 cliffUnlock = uint128(uint256(amount) * UPFRONT_BPS / BPS);

            uint256 streamId = cfg.lockup
                .createWithTimestampsLL({
                    params: Lockup.CreateWithTimestamps({
                        sender: cfg.sender,
                        recipient: cfg.beneficiaries[i],
                        depositAmount: amount,
                        token: cfg.token,
                        cancelable: cfg.cancelable,
                        transferable: cfg.transferable,
                        timestamps: Lockup.Timestamps({start: start, end: endAt}),
                        shape: "Cliff 30% + Linear"
                    }),
                    unlockAmounts: LockupLinear.UnlockAmounts({start: 0, cliff: cliffUnlock}),
                    granularity: GRANULARITY,
                    cliffTime: cliffAt
                });
            streamIds.push(streamId);
        }
        vm.stopBroadcast();

        require(cfg.token.allowance(deployer, address(cfg.lockup)) == 0, "allowance not fully consumed");

        console.log("Lockup:       ", address(cfg.lockup));
        console.log("Token:        ", address(cfg.token));
        console.log("Sender:       ", cfg.sender);
        console.log("Start:        ", start);
        console.log("Cliff (30%):  ", cliffAt);
        console.log("Fully vested: ", endAt);
        for (uint256 i = 0; i < streamIds.length; i++) {
            uint256 id = streamIds[i];
            _assertStream(cfg, id, i, start, cliffAt, endAt);
            console.log("--- stream", id);
            console.log("  recipient: ", cfg.beneficiaries[i]);
            console.log("  allocation:", cfg.amounts[i]);
            console.log("  at cliff:  ", cfg.amounts[i] * UPFRONT_BPS / BPS);
        }
    }

    function _assertStream(
        Config memory cfg,
        uint256 id,
        uint256 i,
        uint40 start,
        uint40 cliffAt,
        uint40 endAt
    ) internal view {
        ISablierLockup lockup = cfg.lockup;
        require(lockup.getRecipient(id) == cfg.beneficiaries[i], "recipient mismatch");
        require(lockup.getSender(id) == cfg.sender, "sender mismatch");
        require(lockup.getDepositedAmount(id) == cfg.amounts[i], "deposit mismatch");
        require(lockup.getUnderlyingToken(id) == cfg.token, "token mismatch");
        require(lockup.getStartTime(id) == start, "start mismatch");
        require(lockup.getCliffTime(id) == cliffAt, "cliff mismatch");
        require(lockup.getEndTime(id) == endAt, "end mismatch");
        require(lockup.isCancelable(id) == cfg.cancelable, "cancelable mismatch");
        require(lockup.isTransferable(id) == cfg.transferable, "transferable mismatch");
        LockupLinear.UnlockAmounts memory unlocks = lockup.getUnlockAmounts(id);
        require(unlocks.start == 0, "start unlock must be 0");
        require(unlocks.cliff == cfg.amounts[i] * UPFRONT_BPS / BPS, "cliff unlock mismatch");
        require(lockup.getLockupModel(id) == Lockup.Model.LOCKUP_LINEAR, "model mismatch");
        require(lockup.streamedAmountOf(id) == 0, "nothing may be streamed at creation");
    }
}
