// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title IHookr — the parts of Hookr 1 (github.com/Hookr-fun/hookr-contracts, `hookr-1/`) a fund
///        venue uses
/// @notice A fund's pool opens through `HookrLauncher.launchAdvised` on the shared `HookrRoot` hook,
///         which Uniswap's routing allowlists, with the Directional Tax advisory taking the fund fee
///         on swaps. Struct layouts match Hookr's ABI exactly.
library HookrTypes {
    /// @notice Immutable execution limits of a pool.
    struct Caps {
        uint24 maxLpFeePips;
        uint24 maxQuoteTakePips;
        uint16 maxSubjectTakeBps;
    }

    /// @notice Pool identity, trusted modules and execution limits; the launcher fills in the
    ///         subject, quote and liquidity owner.
    struct PoolConfig {
        Currency subject;
        Currency quote;
        address rules;
        address advisory;
        address liquidityOwner;
        uint24 baseLpFeePips;
        Caps caps;
        uint32 rulesGasLimit;
        uint32 advisoryGasLimit;
        uint8 advisoryPhases;
        bool advisoryFailOpen;
        bytes32 policyId;
    }

    /// @notice The pool's native rules; a fund pool uses only the LP fee and Hookr's share.
    struct RulesConfig {
        uint40 guardEndBlock;
        uint24 maxFeePips;
        uint24 snipeTaxPips;
        uint24 snipeFloorPips;
        uint16 snipeDecaySeconds;
        uint16 dynamicFeeSens;
        uint16 burnBps;
        uint16 lpBps;
        uint16 potBps;
        uint16 royaltyBps;
        uint16 protocolShareBps;
        uint32 potEveryNBuys;
        uint128 maxBuyQuoteAmount;
        uint128 potMinBuyQuote;
        address royaltyTo;
        address integrator;
    }

    /// @notice Arb recapture; zeroed for a fund pool.
    struct RecaptureConfig {
        bool on;
        uint16 traderBps;
        uint16 lpBps;
        uint32 period;
        uint16 maxPrizeBps;
        uint16 potReleaseBps;
        uint128 minBuyQuote;
        uint32 releaseBlocks;
    }
}

/// @title IHookrLauncher — opens Hookr pools and manages the family owner's launch position
interface IHookrLauncher {
    /// @notice The family's subject: an existing token here.
    struct Token {
        address existing;
        string name;
        string symbol;
        uint256 supply;
        bytes32 salt;
    }

    /// @notice One pool of a family and its launch position.
    struct Member {
        Currency quote;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
        HookrTypes.PoolConfig config;
        HookrTypes.RulesConfig rules;
        HookrTypes.RecaptureConfig recapture;
    }

    /// @notice A member's launch position.
    struct Position {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @notice Opens the members' pools on `rootAddress` with their advisory bind data and funds each
    ///         launch position from the caller, refunding what is unused. `msg.value` is the launch fee.
    function launchAdvised(
        Token calldata token,
        address rootAddress,
        Member[] calldata members,
        bytes[] calldata advisoryConfigs,
        uint256 deadline
    ) external payable returns (bytes32 familyId, address subject);

    /// @notice Removes liquidity (zero collects fees only), paying `recipient`. Family owner only.
    function withdraw(
        bytes32 familyId,
        uint8 member,
        uint128 liquidity,
        uint256 min0,
        uint256 min1,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Adds to a member's range, pulling up to the maximums from the caller and refunding the
    ///         rest; first pays the caller the position's accrued fees. Family owner only.
    function addLiquidity(
        bytes32 familyId,
        uint8 member,
        uint128 liquidity,
        uint128 max0,
        uint128 max1,
        uint256 deadline
    ) external payable returns (uint256 amount0, uint256 amount1);

    /// @notice A member's launch position.
    function position(bytes32 familyId, uint8 member) external view returns (Position memory p);

    /// @notice The PoolManager every family pool lives on.
    function poolManager() external view returns (address);
}

/// @title IHookrDirectionalTax — the buy and sell tax advisory
interface IHookrDirectionalTax {
    /// @notice One direction of a pool's tax; all zero disables it.
    struct Leg {
        uint24 taxPips;
        bytes32 routeId;
        address assetRecipient;
        address recoveryRecipient;
        uint32 staleRecoveryDelay;
    }

    /// @notice The advisory bind data, `abi.encode(Config)`.
    struct Config {
        Leg buy;
        Leg sell;
    }

    /// @notice A bound pool's terms.
    struct Terms {
        address buyQueue;
        uint24 buyTaxPips;
        bool bound;
        bool tiered;
        bool decaying;
        address sellQueue;
        uint24 sellTaxPips;
    }

    /// @notice A pool's terms, with its two tax queues.
    function terms(address root, PoolId id) external view returns (Terms memory);
}

/// @title IHookrTaxQueue — one pool direction's tax queue; every function is permissionless
interface IHookrTaxQueue {
    /// @notice Settles, then pays the whole creator share as quote to the frozen asset recipient.
    ///         Reverts when nothing is due.
    function payCreator() external returns (uint256 amount);
}
