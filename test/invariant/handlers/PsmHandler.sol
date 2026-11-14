// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EUSD} from "../../../src/eusd/EUSD.sol";
import {EUSDPsm} from "../../../src/eusd/EUSDPsm.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title PsmHandler — stateful fuzz handler for EUSDPsm invariants
/// @notice Mints and redeems against two assets (6 and 18 decimals) from several actors, in any
///         cross-asset order, with fee changes, pauses and surplus withdrawals in between.
contract PsmHandler is CommonBase, StdCheats, StdUtils {
    EUSDPsm public immutable psm;
    EUSD public immutable eusd;
    address public immutable admin;
    MockERC20[] internal _assets;
    address[] internal _actors;

    /// @notice Successful calls per action, to check the campaign reaches each path.
    mapping(bytes32 => uint256) public ghost_calls;

    constructor(EUSDPsm psm_, EUSD eusd_, address admin_, MockERC20[] memory assets_, address[] memory actors_) {
        psm = psm_;
        eusd = eusd_;
        admin = admin_;
        _assets = assets_;
        _actors = actors_;
    }

    function assetCount() external view returns (uint256) {
        return _assets.length;
    }

    function assetAt(
        uint256 i
    ) external view returns (MockERC20) {
        return _assets[i];
    }

    function mint(uint256 actorSeed, uint256 assetSeed, uint256 amount) external {
        address actor = _actors[actorSeed % _actors.length];
        MockERC20 asset = _assets[assetSeed % _assets.length];
        amount = bound(amount, 1, 200_000 * 10 ** asset.decimals());
        asset.mint(actor, amount);
        vm.startPrank(actor);
        asset.approve(address(psm), amount);
        try psm.mint(address(asset), amount, 0) {
            ghost_calls["mint"]++;
        } catch {}
        vm.stopPrank();
    }

    function redeem(uint256 actorSeed, uint256 assetSeed, uint256 amount) external {
        address actor = _actors[actorSeed % _actors.length];
        MockERC20 asset = _assets[assetSeed % _assets.length];
        uint256 bal = eusd.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(actor);
        try psm.redeem(address(asset), amount, 0) {
            ghost_calls["redeem"]++;
        } catch {}
    }

    function setFees(uint256 assetSeed, uint16 mintFee, uint16 redeemFee) external {
        MockERC20 asset = _assets[assetSeed % _assets.length];
        vm.prank(admin);
        psm.setFees(address(asset), uint16(bound(mintFee, 0, 100)), uint16(bound(redeemFee, 0, 100)));
        ghost_calls["setFees"]++;
    }

    function setPaused(uint256 assetSeed, bool paused) external {
        MockERC20 asset = _assets[assetSeed % _assets.length];
        vm.prank(admin);
        psm.setMintPaused(address(asset), paused);
        ghost_calls["setPaused"]++;
    }

    function withdrawSurplus(uint256 assetSeed, uint256 amount) external {
        MockERC20 asset = _assets[assetSeed % _assets.length];
        uint256 available = psm.surplus(address(asset));
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(admin);
        psm.withdrawSurplus(address(asset), amount);
        ghost_calls["withdrawSurplus"]++;
    }
}
