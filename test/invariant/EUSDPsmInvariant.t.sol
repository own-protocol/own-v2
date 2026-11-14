// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EUSD} from "../../src/eusd/EUSD.sol";
import {EUSDPsm} from "../../src/eusd/EUSDPsm.sol";
import {Actors} from "../helpers/Actors.sol";
import {BaseTest} from "../helpers/BaseTest.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {PsmHandler} from "./handlers/PsmHandler.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title EUSDPsmInvariant — eUSD supply, per-asset books and reserves of the PSM
contract EUSDPsmInvariant is BaseTest {
    EUSD internal eusd;
    EUSDPsm internal psm;
    PsmHandler internal handler;

    function setUp() public override {
        super.setUp();
        address admin = Actors.ADMIN;
        eusd = new EUSD(admin);
        EUSDPsm impl = new EUSDPsm();
        psm = EUSDPsm(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(EUSDPsm.initialize, (address(protocolRegistry), address(eusd)))
                )
            )
        );
        MockERC20[] memory assets = new MockERC20[](2);
        assets[0] = new MockERC20("USDG", "USDG", 6);
        assets[1] = new MockERC20("frxUSD", "frxUSD", 18);
        vm.startPrank(admin);
        eusd.grantRole(eusd.MINTER_ROLE(), address(psm));
        protocolRegistry.setTreasury(address(0x7ea5));
        psm.addAsset(address(assets[0]), 1_000_000e18, 0, 0);
        psm.addAsset(address(assets[1]), 100_000e18, 0, 0);
        vm.stopPrank();

        address[] memory actors = new address[](3);
        actors[0] = Actors.MINTER1;
        actors[1] = Actors.MINTER2;
        actors[2] = Actors.ATTACKER;
        handler = new PsmHandler(psm, eusd, admin, assets, actors);
        targetContract(address(handler));
    }

    /// @notice eUSD supply is exactly the PSM's debt (it is the only minter here).
    function invariant_supplyEqualsDebt() public view {
        assertEq(eusd.totalSupply(), psm.totalDebt());
    }

    /// @notice The per-asset debts sum to the total.
    function invariant_assetDebtsSumToTotal() public view {
        uint256 sum;
        for (uint256 i; i < handler.assetCount(); ++i) {
            sum += psm.assetConfig(address(handler.assetAt(i))).debt;
        }
        assertEq(sum, psm.totalDebt());
    }

    /// @notice Each asset's reserve covers its debt, and stays within its ceiling unless lowered.
    function invariant_reserveCoversDebt() public view {
        for (uint256 i; i < handler.assetCount(); ++i) {
            MockERC20 asset = handler.assetAt(i);
            uint256 scale = 10 ** (18 - asset.decimals());
            assertGe(asset.balanceOf(address(psm)) * scale, psm.assetConfig(address(asset)).debt);
            assertLe(psm.assetConfig(address(asset)).debt, psm.assetConfig(address(asset)).debtCeiling);
        }
    }
}
