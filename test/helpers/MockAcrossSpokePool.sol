// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockAcrossSpokePool — records the last V3 deposit and pulls its input
/// @dev `depositV3` is decoded by hand in the fallback: twelve parameters are too deep for the legacy pipeline.
contract MockAcrossSpokePool {
    bytes4 internal constant DEPOSIT_V3 = bytes4(
        keccak256(
            "depositV3(address,address,address,address,uint256,uint256,uint256,address,uint32,uint32,uint32,bytes)"
        )
    );

    struct Deposit {
        address depositor;
        address recipient;
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 destinationChainId;
        address exclusiveRelayer;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
    }

    Deposit internal _last;
    uint256 public deposits;
    uint32 public fillDeadlineBuffer = 6 hours;

    function lastDeposit() external view returns (Deposit memory) {
        return _last;
    }

    fallback() external payable {
        require(msg.sig == DEPOSIT_V3, "unknown");
        Deposit memory d;
        (d.depositor, d.recipient, d.inputToken, d.outputToken, d.inputAmount, d.outputAmount) =
            abi.decode(msg.data[4:196], (address, address, address, address, uint256, uint256));
        (d.destinationChainId, d.exclusiveRelayer, d.quoteTimestamp, d.fillDeadline, d.exclusivityDeadline) =
            abi.decode(msg.data[196:356], (uint256, address, uint32, uint32, uint32));
        IERC20(d.inputToken).transferFrom(msg.sender, address(this), d.inputAmount);
        _last = d;
        ++deposits;
    }
}
