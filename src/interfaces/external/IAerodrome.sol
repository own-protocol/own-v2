// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICLFactory — the subset of the Aero Slipstream pool factory used by Own
interface ICLFactory {
    /// @notice The pool for a pair and tick spacing, or zero if none.
    /// @param tokenA      One token of the pair.
    /// @param tokenB      The other token.
    /// @param tickSpacing Tick spacing.
    /// @return pool The pool.
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address pool);
}

/// @title ICLPool — the subset of an Aero Slipstream pool used by Own
interface ICLPool {
    /// @notice Lower-sorted token of the pair.
    /// @return The token.
    function token0() external view returns (address);

    /// @notice Higher-sorted token of the pair.
    /// @return The token.
    function token1() external view returns (address);

    /// @notice Tick spacing; range bounds must be multiples of it.
    /// @return The spacing.
    function tickSpacing() external view returns (int24);

    /// @notice The pool's gauge, or zero if none.
    /// @return The gauge.
    function gauge() external view returns (address);

    /// @notice Current pool state; only `sqrtPriceX96` is used.
    /// @return sqrtPriceX96               Sqrt price (Q64.96).
    /// @return tick                       Current tick.
    /// @return observationIndex           Oracle index.
    /// @return observationCardinality     Oracle cardinality.
    /// @return observationCardinalityNext Next oracle cardinality.
    /// @return unlocked                   Reentrancy flag.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        );
}

/// @title INonfungiblePositionManager — the subset of the Aero Slipstream position NFT used by Own
/// @notice Each position is an ERC-721 holding one range's liquidity in one pool.
interface INonfungiblePositionManager {
    /// @notice Parameters of {mint}.
    /// @param token0         Lower-sorted token.
    /// @param token1         Higher-sorted token.
    /// @param tickSpacing    Pool tick spacing.
    /// @param tickLower      Lower tick of the range.
    /// @param tickUpper      Upper tick of the range.
    /// @param amount0Desired Most token0 to pay.
    /// @param amount1Desired Most token1 to pay.
    /// @param amount0Min     Least token0 to pay.
    /// @param amount1Min     Least token1 to pay.
    /// @param recipient      NFT recipient.
    /// @param deadline       Latest block timestamp for the call.
    /// @param sqrtPriceX96   Initial price if the call creates the pool; zero otherwise.
    struct MintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
    }

    /// @notice Parameters of {increaseLiquidity}.
    /// @param tokenId        Position.
    /// @param amount0Desired Most token0 to pay.
    /// @param amount1Desired Most token1 to pay.
    /// @param amount0Min     Least token0 to pay.
    /// @param amount1Min     Least token1 to pay.
    /// @param deadline       Latest block timestamp for the call.
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Parameters of {decreaseLiquidity}.
    /// @param tokenId    Position.
    /// @param liquidity  Liquidity to remove.
    /// @param amount0Min Least token0 to receive.
    /// @param amount1Min Least token1 to receive.
    /// @param deadline   Latest block timestamp for the call.
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Parameters of {collect}.
    /// @param tokenId    Position.
    /// @param recipient  Recipient.
    /// @param amount0Max Most token0 to collect.
    /// @param amount1Max Most token1 to collect.
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice Open a position. Principal is pulled from the caller by `transferFrom`.
    /// @param params See {MintParams}.
    /// @return tokenId   New position.
    /// @return liquidity Liquidity added.
    /// @return amount0   Token0 paid.
    /// @return amount1   Token1 paid.
    function mint(
        MintParams calldata params
    ) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Add liquidity to a position. Principal is pulled from the caller by `transferFrom`.
    /// @param params See {IncreaseLiquidityParams}.
    /// @return liquidity Liquidity added.
    /// @return amount0   Token0 paid.
    /// @return amount1   Token1 paid.
    function increaseLiquidity(
        IncreaseLiquidityParams calldata params
    ) external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Remove liquidity; the amounts are owed to the position until {collect}.
    /// @param params See {DecreaseLiquidityParams}.
    /// @return amount0 Token0 owed.
    /// @return amount1 Token1 owed.
    function decreaseLiquidity(
        DecreaseLiquidityParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1);

    /// @notice Send what the position is owed (removed principal and swap fees).
    /// @param params See {CollectParams}.
    /// @return amount0 Token0 sent.
    /// @return amount1 Token1 sent.
    function collect(
        CollectParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1);

    /// @notice A position's state; only `liquidity` is used.
    /// @param tokenId Position.
    /// @return nonce                    Permit nonce.
    /// @return operator                 Approved operator.
    /// @return token0                   Lower-sorted token.
    /// @return token1                   Higher-sorted token.
    /// @return tickSpacing              Pool tick spacing.
    /// @return tickLower                Lower tick of the range.
    /// @return tickUpper                Upper tick of the range.
    /// @return liquidity                Liquidity in the position, from any depositor.
    /// @return feeGrowthInside0LastX128 Fee growth of token0 at the last update.
    /// @return feeGrowthInside1LastX128 Fee growth of token1 at the last update.
    /// @return tokensOwed0              Token0 owed.
    /// @return tokensOwed1              Token1 owed.
    function positions(
        uint256 tokenId
    )
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    /// @notice Burn an empty, fully collected position.
    /// @param tokenId Position.
    function burn(
        uint256 tokenId
    ) external payable;

    /// @notice Approve `to` to move the position.
    /// @param to      Spender.
    /// @param tokenId Position.
    function approve(address to, uint256 tokenId) external;
}

/// @title ICLGauge — the subset of an Aero Slipstream gauge used by Own
/// @notice A staked position NFT sits in the gauge. Its liquidity gives up swap fees and earns
///         emissions while in range.
interface ICLGauge {
    /// @notice Stake a position NFT owned by the caller, crediting the caller.
    /// @param tokenId Position.
    function deposit(
        uint256 tokenId
    ) external;

    /// @notice Unstake a position NFT credited to the caller and return it, claiming its emissions
    ///         to the caller.
    /// @param tokenId Position.
    function withdraw(
        uint256 tokenId
    ) external;

    /// @notice Claim `account`'s emissions to `recipient`. The caller must be `account`.
    /// @param account   Account credited with the stakes.
    /// @param recipient Recipient.
    function claimEmissions(address account, address recipient) external;
}
