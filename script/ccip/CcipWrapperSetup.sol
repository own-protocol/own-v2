// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CcipWrappedToken} from "../../src/bridge/CcipWrappedToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CommonBase} from "forge-std/Base.sol";

/// @notice Chainlink CCIP 2.0.0 types and calls the setup uses (field order matches the deployed contracts).
library Ccip {
    enum PoolType {
        BURN_MINT,
        LOCK_RELEASE
    }

    struct RateLimitConfig {
        bool isEnabled;
        uint128 capacity;
        uint128 rate;
    }

    struct RemoteChainConfig {
        address remotePoolFactory;
        address remoteRouter;
        address remoteRMNProxy;
        address remoteLockBox;
        uint8 remoteTokenDecimals;
    }

    struct RemoteTokenPoolInfo {
        uint64 remoteChainSelector;
        bytes remotePoolAddress;
        bytes remotePoolInitCode;
        RemoteChainConfig remoteChainConfig;
        PoolType poolType;
        bytes remoteTokenAddress;
        bytes remoteTokenInitCode;
        RateLimitConfig rateLimiterConfig;
    }

    struct ChainUpdate {
        uint64 remoteChainSelector;
        bytes[] remotePoolAddresses;
        bytes remoteTokenAddress;
        RateLimitConfig outboundRateLimiterConfig;
        RateLimitConfig inboundRateLimiterConfig;
    }

    /// @notice `BaseERC20.ConstructorParams` of CrossChainToken 2.0.0.
    struct TokenParams {
        string name;
        string symbol;
        uint256 maxSupply;
        uint256 preMint;
        address preMintRecipient;
        uint8 decimals;
        address ccipAdmin;
    }
}

interface ITokenPoolFactory {
    function deployTokenAndTokenPool(
        Ccip.RemoteTokenPoolInfo[] calldata remoteTokenPools,
        uint8 localTokenDecimals,
        Ccip.PoolType localPoolType,
        bytes memory tokenInitCode,
        bytes calldata tokenPoolInitCode,
        address lockBox,
        bytes32 salt,
        address futureOwner
    ) external returns (address token, address pool);

    function deployTokenPoolWithExistingToken(
        address token,
        uint8 localTokenDecimals,
        Ccip.PoolType localPoolType,
        Ccip.RemoteTokenPoolInfo[] calldata remoteTokenPools,
        bytes calldata tokenPoolInitCode,
        address lockBox,
        bytes32 salt,
        address futureOwner
    ) external returns (address pool);
}

interface ITokenPool {
    function acceptOwnership() external;
    function transferOwnership(
        address to
    ) external;
    function owner() external view returns (address);
    function applyChainUpdates(
        uint64[] calldata remoteChainSelectorsToRemove,
        Ccip.ChainUpdate[] calldata chainsToAdd
    ) external;
    function getLockBox() external view returns (address);
    function getToken() external view returns (address);
    function getRemoteToken(
        uint64 remoteChainSelector
    ) external view returns (bytes memory);
    function getRemotePools(
        uint64 remoteChainSelector
    ) external view returns (bytes[] memory);
    function isSupportedChain(
        uint64 remoteChainSelector
    ) external view returns (bool);
    function typeAndVersion() external view returns (string memory);
}

interface ITokenAdminRegistry {
    struct TokenConfig {
        address administrator;
        address pendingAdministrator;
        address tokenPool;
    }

    function acceptAdminRole(
        address token
    ) external;
    function setPool(address token, address pool) external;
    function transferAdminRole(address token, address newAdmin) external;
    function getPool(
        address token
    ) external view returns (address);
    function getTokenConfig(
        address token
    ) external view returns (TokenConfig memory);
}

interface IRegistryModuleOwnerCustom {
    function registerAdminViaGetCCIPAdmin(
        address token
    ) external;
}

interface ICrossChainToken {
    function beginDefaultAdminTransfer(
        address newAdmin
    ) external;
    function owner() external view returns (address);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @title CcipWrapperSetup — CCIP self-serve registration for rZEC and rHYPE (Base <-> Robinhood Chain)
/// @notice Shared by the setup script and its fork test. The steps, each run on its own chain by the same deployer:
///         1. Base: deploy the {CcipWrappedToken} and a LockRelease pool (its lockbox comes with it) through
///            Chainlink's TokenPoolFactory, accept ownership, register the wrapper in the TokenAdminRegistry and
///            point it at the pool.
///         2. Robinhood: deploy the CrossChainToken (BurnMint) and its pool through the factory, already linked to
///            the Base wrapper and pool; the factory registers it. Accept ownership and the registry admin role.
///         3. Base: link the Base pool to the Robinhood token and pool.
///         4. Both: hand the pools, lockbox, registry admin and token admin to the Safe (two-step; the Safe accepts).
///         Pool bytecode is Chainlink's own npm contracts-ccip 2.0.0 build, fetched and checked by
///         `tools/fetch-ccip-bytecode.sh` into `ccip-bytecode/v2_0_0/`.
abstract contract CcipWrapperSetup is CommonBase {
    uint64 internal constant BASE_SELECTOR = 15_971_525_489_660_198_786;
    uint64 internal constant RH_SELECTOR = 6_180_753_054_346_818_345;

    address internal constant BASE_POOL_FACTORY = 0x8cE19F73e85a68490e08c89b510215Ca71B0F2B8;
    address internal constant BASE_TOKEN_ADMIN_REGISTRY = 0x6f6C373d09C07425BaAE72317863d7F6bb731e37;
    address internal constant BASE_REGISTRY_MODULE = 0xAFEd606Bd2CAb6983fC6F10167c98aaC2173D77f;
    address internal constant BASE_ROUTER = 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD;

    address internal constant RH_POOL_FACTORY = 0x614B367841ec854994706f06AAB4aA2C80Fe06D9;
    address internal constant RH_TOKEN_ADMIN_REGISTRY = 0x1912C3cFafE8A76A32a92861d815aC2837F237Ca;
    address internal constant RH_ROUTER = 0x06fC836cf9839B1cd891C440A0a45242DA6Ae1c9;

    address internal constant CB_ZEC = 0xB2000000000000000000008501b13360000cb2EC;
    address internal constant CB_HYPE = 0xB200000000000000000000451d033a5000cb479e;

    string internal constant BYTECODE_DIR = "ccip-bytecode/v2_0_0/";

    /// @notice One wrapper's identity, the same on both chains.
    struct WrapperSpec {
        address underlying;
        string name;
        string symbol;
        uint8 decimals;
    }

    function _spec(
        string memory key
    ) internal pure returns (WrapperSpec memory) {
        bytes32 k = keccak256(bytes(key));
        if (k == keccak256("ZEC")) return WrapperSpec(CB_ZEC, "Own Wrapped cbZEC", "rZEC", 8);
        if (k == keccak256("HYPE")) return WrapperSpec(CB_HYPE, "Own Wrapped cbHYPE", "rHYPE", 18);
        revert("unknown wrapper key");
    }

    function _bin(
        string memory name
    ) internal view returns (bytes memory) {
        return vm.parseBytes(vm.readFile(string.concat(vm.projectRoot(), "/", BYTECODE_DIR, name, ".bin")));
    }

    /// @notice Step 1 (Base). `deployer` is the account sending the calls.
    function _setupBase(
        WrapperSpec memory s,
        address deployer
    ) internal returns (address wrapper, address pool, address lockBox) {
        wrapper = address(new CcipWrappedToken(IERC20(s.underlying), s.name, s.symbol, deployer));
        pool = ITokenPoolFactory(BASE_POOL_FACTORY).deployTokenPoolWithExistingToken(
            wrapper,
            s.decimals,
            Ccip.PoolType.LOCK_RELEASE,
            new Ccip.RemoteTokenPoolInfo[](0),
            _bin("lock_release_token_pool"),
            address(0),
            keccak256(bytes(s.symbol)),
            deployer
        );
        ITokenPool(pool).acceptOwnership();
        lockBox = ITokenPool(pool).getLockBox();
        ITokenPool(lockBox).acceptOwnership();
        IRegistryModuleOwnerCustom(BASE_REGISTRY_MODULE).registerAdminViaGetCCIPAdmin(wrapper);
        ITokenAdminRegistry(BASE_TOKEN_ADMIN_REGISTRY).acceptAdminRole(wrapper);
        ITokenAdminRegistry(BASE_TOKEN_ADMIN_REGISTRY).setPool(wrapper, pool);
    }

    /// @notice Step 2 (Robinhood).
    function _setupRobinhood(
        WrapperSpec memory s,
        address deployer,
        address baseWrapper,
        address basePool,
        Ccip.RateLimitConfig memory limit
    ) internal returns (address token, address pool) {
        (token, pool) = ITokenPoolFactory(RH_POOL_FACTORY).deployTokenAndTokenPool(
            _baseRemote(s.decimals, baseWrapper, basePool, limit),
            s.decimals,
            Ccip.PoolType.BURN_MINT,
            _rhTokenInit(s, deployer),
            _bin("burn_mint_token_pool"),
            address(0),
            keccak256(bytes(s.symbol)),
            deployer
        );
        ITokenPool(pool).acceptOwnership();
        ITokenAdminRegistry(RH_TOKEN_ADMIN_REGISTRY).acceptAdminRole(token);
    }

    /// @dev The factory must be the token's ccipAdmin and burn-mint role admin; it registers the token, grants the
    ///      pool mint and burn and renounces the role admin. `deployer` is the token's default admin.
    function _rhTokenInit(WrapperSpec memory s, address deployer) internal view returns (bytes memory) {
        return abi.encodePacked(
            _bin("cross_chain_token"),
            abi.encode(
                Ccip.TokenParams({
                    name: s.name,
                    symbol: s.symbol,
                    maxSupply: 0,
                    preMint: 0,
                    preMintRecipient: address(0),
                    decimals: s.decimals,
                    ccipAdmin: RH_POOL_FACTORY
                }),
                RH_POOL_FACTORY,
                deployer
            )
        );
    }

    function _baseRemote(
        uint8 decimals,
        address baseWrapper,
        address basePool,
        Ccip.RateLimitConfig memory limit
    ) internal pure returns (Ccip.RemoteTokenPoolInfo[] memory remotes) {
        remotes = new Ccip.RemoteTokenPoolInfo[](1);
        remotes[0] = Ccip.RemoteTokenPoolInfo({
            remoteChainSelector: BASE_SELECTOR,
            remotePoolAddress: abi.encode(basePool),
            remotePoolInitCode: "",
            remoteChainConfig: Ccip.RemoteChainConfig(address(0), address(0), address(0), address(0), decimals),
            poolType: Ccip.PoolType.LOCK_RELEASE,
            remoteTokenAddress: abi.encode(baseWrapper),
            remoteTokenInitCode: "",
            rateLimiterConfig: limit
        });
    }

    /// @notice Step 3 (Base).
    function _linkBase(address basePool, address rhToken, address rhPool, Ccip.RateLimitConfig memory limit) internal {
        Ccip.ChainUpdate[] memory adds = new Ccip.ChainUpdate[](1);
        bytes[] memory pools = new bytes[](1);
        pools[0] = abi.encode(rhPool);
        adds[0] = Ccip.ChainUpdate({
            remoteChainSelector: RH_SELECTOR,
            remotePoolAddresses: pools,
            remoteTokenAddress: abi.encode(rhToken),
            outboundRateLimiterConfig: limit,
            inboundRateLimiterConfig: limit
        });
        ITokenPool(basePool).applyChainUpdates(new uint64[](0), adds);
    }

    /// @notice Step 4 (Base): start the hand-off to `owner`, who accepts on the pool, lockbox and registry.
    function _handOffBase(address wrapper, address pool, address owner) internal {
        ITokenPool(pool).transferOwnership(owner);
        ITokenPool(ITokenPool(pool).getLockBox()).transferOwnership(owner);
        ITokenAdminRegistry(BASE_TOKEN_ADMIN_REGISTRY).transferAdminRole(wrapper, owner);
    }

    /// @notice Step 4 (Robinhood): start the hand-off to `owner`, who accepts on the pool, registry and token.
    function _handOffRobinhood(address token, address pool, address owner) internal {
        ITokenPool(pool).transferOwnership(owner);
        ITokenAdminRegistry(RH_TOKEN_ADMIN_REGISTRY).transferAdminRole(token, owner);
        ICrossChainToken(token).beginDefaultAdminTransfer(owner);
    }
}
