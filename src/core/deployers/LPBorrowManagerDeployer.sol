// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {InterestRateModel} from "../../libraries/InterestRateModel.sol";
import {LPBorrowManager} from "../LPBorrowManager.sol";

/// @title LPBorrowManagerDeployer — Stateless deployer for `LPBorrowManager`
/// @notice Holds `LPBorrowManager`'s creation code so that `BorrowManagerFactory`'s
///         runtime bytecode stays under EIP-170. Called by
///         `BorrowManagerFactory.createBorrowManager`.
contract LPBorrowManagerDeployer {
    function deploy(
        address vault,
        address stablecoin,
        address debtToken,
        address aavePool,
        address market,
        address registry,
        address coordinator,
        bytes32 collateralAsset,
        InterestRateModel.Params calldata rateParams
    ) external returns (address) {
        return address(
            new LPBorrowManager(
                vault, stablecoin, debtToken, aavePool, market, registry, coordinator, collateralAsset, rateParams
            )
        );
    }
}
