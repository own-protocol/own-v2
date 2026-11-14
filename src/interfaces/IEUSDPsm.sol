// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IEUSDPsm — Peg stability module: eUSD 1:1 against listed stablecoins
/// @notice Anyone can put in a listed stablecoin and get the same amount of eUSD, or put eUSD back
///         and get the same amount of that stablecoin, less the asset's mint or redeem fee. Each
///         asset is its own book: eUSD minted against it is its debt, it can only be redeemed up to
///         that debt, and its reserve always covers its debt. Arbitrage against the PSM holds eUSD
///         pools at $1 in both directions, up to each asset's debt ceiling on the way up and its
///         reserve on the way down.
/// @dev The PSM's debt counts toward eUSD supply like a manager's: `totalDebt` is the eUSD it has
///      minted and not yet burned. Fees stay in the reserve as surplus, which the admin can send to
///      the treasury. Redemptions are never paused.
interface IEUSDPsm {
    // ──────────────────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────────────────

    /// @notice Per-asset settings and book.
    /// @param listed       Whether the asset has been added.
    /// @param mintPaused   Whether minting against the asset is paused (redeem stays open).
    /// @param decimals     The asset's ERC-20 decimals (at most 18), read when it is added.
    /// @param mintFeeBps   Fee on mint, taken from the eUSD out (BPS).
    /// @param redeemFeeBps Fee on redeem, taken from the asset out (BPS).
    /// @param debtCeiling  Most eUSD that may be outstanding against the asset (18 decimals).
    /// @param debt         eUSD minted against the asset and not yet redeemed (18 decimals).
    struct AssetConfig {
        bool listed;
        bool mintPaused;
        uint8 decimals;
        uint16 mintFeeBps;
        uint16 redeemFeeBps;
        uint256 debtCeiling;
        uint256 debt;
    }

    // ──────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────

    /// @notice Emitted when eUSD is minted against an asset.
    /// @param asset   Asset paid in.
    /// @param account Payer and eUSD recipient.
    /// @param assetIn Asset paid (asset units).
    /// @param eusdOut eUSD minted to the account (18 decimals).
    /// @param fee     eUSD-equivalent fee kept as reserve surplus (18 decimals).
    event Minted(address indexed asset, address indexed account, uint256 assetIn, uint256 eusdOut, uint256 fee);

    /// @notice Emitted when eUSD is redeemed for an asset.
    /// @param asset    Asset paid out.
    /// @param account  eUSD payer and asset recipient.
    /// @param eusdIn   eUSD burned (18 decimals).
    /// @param assetOut Asset paid (asset units).
    /// @param fee      eUSD-equivalent fee kept as reserve surplus (18 decimals).
    event Redeemed(address indexed asset, address indexed account, uint256 eusdIn, uint256 assetOut, uint256 fee);

    /// @notice Emitted when an asset is listed.
    /// @param asset        The asset.
    /// @param decimals     Its decimals.
    /// @param debtCeiling  Initial debt ceiling (18 decimals).
    /// @param mintFeeBps   Initial mint fee (BPS).
    /// @param redeemFeeBps Initial redeem fee (BPS).
    event AssetAdded(
        address indexed asset, uint8 decimals, uint256 debtCeiling, uint16 mintFeeBps, uint16 redeemFeeBps
    );

    /// @notice Emitted when an asset's debt ceiling changes.
    /// @param asset       The asset.
    /// @param debtCeiling New ceiling (18 decimals).
    event DebtCeilingSet(address indexed asset, uint256 debtCeiling);

    /// @notice Emitted when an asset's fees change.
    /// @param asset        The asset.
    /// @param mintFeeBps   New mint fee (BPS).
    /// @param redeemFeeBps New redeem fee (BPS).
    event FeesSet(address indexed asset, uint16 mintFeeBps, uint16 redeemFeeBps);

    /// @notice Emitted when minting against an asset is paused or resumed.
    /// @param asset  The asset.
    /// @param paused New state.
    event MintPausedSet(address indexed asset, bool paused);

    /// @notice Emitted when reserve surplus goes to the treasury.
    /// @param asset  The asset.
    /// @param to     Treasury at the time of the call.
    /// @param amount Asset units sent.
    event SurplusWithdrawn(address indexed asset, address indexed to, uint256 amount);

    // ──────────────────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────────────────

    /// @notice A required address was the zero address.
    error ZeroAddress();
    /// @notice A required amount was zero, or rounded to zero.
    error ZeroAmount();
    /// @notice Caller is not the admin.
    error OnlyAdmin();
    /// @notice Caller is not the operator.
    error OnlyOperator();
    /// @notice The asset is not listed.
    /// @param asset The asset.
    error AssetNotListed(address asset);
    /// @notice The asset is already listed.
    /// @param asset The asset.
    error AssetAlreadyListed(address asset);
    /// @notice eUSD itself cannot be listed.
    /// @param asset The asset.
    error UnsupportedAsset(address asset);
    /// @notice The asset has more than 18 decimals.
    /// @param decimals Its decimals.
    error UnsupportedDecimals(uint8 decimals);
    /// @notice A fee is above `MAX_FEE_BPS`.
    /// @param feeBps The fee.
    error FeeTooHigh(uint16 feeBps);
    /// @notice Minting against the asset is paused.
    /// @param asset The asset.
    error MintingPaused(address asset);
    /// @notice The mint would take the asset's debt above its ceiling.
    /// @param debt        Debt after the mint (18 decimals).
    /// @param debtCeiling The ceiling (18 decimals).
    error DebtCeilingExceeded(uint256 debt, uint256 debtCeiling);
    /// @notice The redeem is larger than the asset's debt.
    /// @param requested eUSD to redeem (18 decimals).
    /// @param available The asset's debt (18 decimals).
    error InsufficientDebt(uint256 requested, uint256 available);
    /// @notice The output is below the caller's minimum.
    /// @param out Output (eUSD or asset units).
    /// @param min The caller's minimum.
    error InsufficientOutput(uint256 out, uint256 min);
    /// @notice The PSM received a different amount than was sent (fee-on-transfer tokens are not
    ///         supported).
    /// @param expected Amount sent.
    /// @param received Amount received.
    error TransferAmountMismatch(uint256 expected, uint256 received);
    /// @notice The withdrawal is larger than the asset's surplus.
    /// @param requested Asset units requested.
    /// @param available Surplus (asset units).
    error InsufficientSurplus(uint256 requested, uint256 available);

    // ──────────────────────────────────────────────────────────
    //  Swaps
    // ──────────────────────────────────────────────────────────

    /// @notice Pay `assetIn` of a listed asset and get the same amount of eUSD less the mint fee.
    /// @param asset      Asset to pay.
    /// @param assetIn    Asset units to pay, pulled from the caller.
    /// @param minEusdOut Least eUSD the caller accepts.
    /// @return eusdOut eUSD minted to the caller (18 decimals).
    function mint(address asset, uint256 assetIn, uint256 minEusdOut) external returns (uint256 eusdOut);

    /// @notice Burn `eusdIn` from the caller and get the same amount of a listed asset less the
    ///         redeem fee. Never paused; limited to the asset's debt.
    /// @param asset       Asset to receive.
    /// @param eusdIn      eUSD to burn (18 decimals).
    /// @param minAssetOut Least asset units the caller accepts.
    /// @return assetOut Asset units paid to the caller.
    function redeem(address asset, uint256 eusdIn, uint256 minAssetOut) external returns (uint256 assetOut);

    // ──────────────────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────────────────

    /// @notice List an asset (ADMIN). It must be a $1 stablecoin with at most 18 decimals and no
    ///         transfer fee.
    /// @param asset        The asset.
    /// @param debtCeiling  Most eUSD outstanding against it (18 decimals); 0 lists it closed.
    /// @param mintFeeBps   Mint fee (BPS, at most `MAX_FEE_BPS`).
    /// @param redeemFeeBps Redeem fee (BPS, at most `MAX_FEE_BPS`).
    function addAsset(address asset, uint256 debtCeiling, uint16 mintFeeBps, uint16 redeemFeeBps) external;

    /// @notice Set an asset's debt ceiling (ADMIN). A ceiling below the current debt only blocks
    ///         new mints.
    /// @param asset       The asset.
    /// @param debtCeiling New ceiling (18 decimals).
    function setDebtCeiling(address asset, uint256 debtCeiling) external;

    /// @notice Set an asset's fees (ADMIN).
    /// @param asset        The asset.
    /// @param mintFeeBps   Mint fee (BPS, at most `MAX_FEE_BPS`).
    /// @param redeemFeeBps Redeem fee (BPS, at most `MAX_FEE_BPS`).
    function setFees(address asset, uint16 mintFeeBps, uint16 redeemFeeBps) external;

    /// @notice Pause or resume minting against an asset (OPERATOR). Redeem stays open.
    /// @param asset  The asset.
    /// @param paused New state.
    function setMintPaused(address asset, bool paused) external;

    /// @notice Send reserve surplus of an asset to the registry treasury (ADMIN). Never touches the
    ///         reserve that covers the asset's debt.
    /// @param asset  The asset.
    /// @param amount Asset units to send.
    function withdrawSurplus(address asset, uint256 amount) external;

    // ──────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────

    /// @notice Highest mint or redeem fee the admin can set.
    /// @return Fee cap (BPS).
    function MAX_FEE_BPS() external view returns (uint16);

    /// @notice The eUSD token.
    /// @return eUSD address.
    function eusd() external view returns (address);

    /// @notice eUSD minted by the PSM and not yet burned, across all assets.
    /// @return Debt (18 decimals).
    function totalDebt() external view returns (uint256);

    /// @notice An asset's settings and book.
    /// @param asset The asset.
    /// @return The config (all zero when not listed).
    function assetConfig(
        address asset
    ) external view returns (AssetConfig memory);

    /// @notice Number of listed assets.
    /// @return Count.
    function assetCount() external view returns (uint256);

    /// @notice Listed asset by index, in listing order.
    /// @param index Index below `assetCount()`.
    /// @return The asset.
    function assetAt(
        uint256 index
    ) external view returns (address);

    /// @notice Reserve above what covers the asset's debt.
    /// @param asset The asset.
    /// @return Surplus (asset units).
    function surplus(
        address asset
    ) external view returns (uint256);

    /// @notice eUSD out and fee for a mint, as {mint} would compute them now.
    /// @param asset   The asset.
    /// @param assetIn Asset units to pay.
    /// @return eusdOut eUSD out (18 decimals).
    /// @return fee     eUSD-equivalent fee (18 decimals).
    function previewMint(address asset, uint256 assetIn) external view returns (uint256 eusdOut, uint256 fee);

    /// @notice Asset out and fee for a redeem, as {redeem} would compute them now.
    /// @param asset  The asset.
    /// @param eusdIn eUSD to burn (18 decimals).
    /// @return assetOut Asset units out.
    /// @return fee      eUSD-equivalent fee (18 decimals).
    function previewRedeem(address asset, uint256 eusdIn) external view returns (uint256 assetOut, uint256 fee);
}
