// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {InterestRateModel} from "../../libraries/InterestRateModel.sol";
import {UserBorrowManager} from "../UserBorrowManager.sol";

/// @title UserBorrowManagerDeployer — Stateless deployer for `UserBorrowManager`
/// @notice Holds `UserBorrowManager`'s creation code so that `BorrowManagerFactory`'s
///         runtime bytecode stays under EIP-170. Called by
///         `BorrowManagerFactory.createBorrowManager`.
contract UserBorrowManagerDeployer {
    function deploy(
        address vault,
        address stablecoin,
        address debtToken,
        address aavePool,
        address registry,
        address coordinator,
        InterestRateModel.Params calldata rateParams
    ) external returns (address) {
        return address(new UserBorrowManager(vault, stablecoin, debtToken, aavePool, registry, coordinator, rateParams));
    }
}
