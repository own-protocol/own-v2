// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CcipClient, IAny2EVMMessageReceiver} from "../../src/interfaces/external/ICcip.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockCcipRouter — records sends, charges a flat fee, delivers messages on demand
contract MockCcipRouter {
    uint256 public fee = 0.001 ether;
    uint64 public lastDestChainSelector;
    bytes public lastReceiver;
    bytes public lastData;
    bytes public lastExtraArgs;
    address public lastFeeToken;
    address public lastToken;
    uint256 public lastAmount;
    uint256 public sends;

    function setFee(
        uint256 fee_
    ) external {
        fee = fee_;
    }

    function isChainSupported(
        uint64
    ) external pure returns (bool) {
        return true;
    }

    function getFee(uint64, CcipClient.EVM2AnyMessage memory) external view returns (uint256) {
        return fee;
    }

    function ccipSend(
        uint64 destChainSelector,
        CcipClient.EVM2AnyMessage calldata message
    ) external payable returns (bytes32) {
        require(msg.value >= fee, "fee");
        lastDestChainSelector = destChainSelector;
        lastReceiver = message.receiver;
        lastData = message.data;
        lastExtraArgs = message.extraArgs;
        lastFeeToken = message.feeToken;
        lastToken = message.tokenAmounts[0].token;
        lastAmount = message.tokenAmounts[0].amount;
        IERC20(lastToken).transferFrom(msg.sender, address(this), lastAmount);
        ++sends;
        return keccak256(abi.encode(sends));
    }

    /// @notice Sends `amount` of `token` (held by this mock) to `receiver` and calls its `ccipReceive`.
    function deliver(
        address receiver,
        address token,
        uint256 amount,
        bytes calldata sender,
        bytes calldata data
    ) external {
        deliverFrom(keccak256("msg"), 6_180_753_054_346_818_345, receiver, token, amount, sender, data);
    }

    /// @notice {deliver} with a chosen message id and source chain.
    function deliverFrom(
        bytes32 messageId,
        uint64 sourceChainSelector,
        address receiver,
        address token,
        uint256 amount,
        bytes calldata sender,
        bytes calldata data
    ) public {
        IERC20(token).transfer(receiver, amount);
        CcipClient.EVMTokenAmount[] memory tokens = new CcipClient.EVMTokenAmount[](1);
        tokens[0] = CcipClient.EVMTokenAmount({token: token, amount: amount});
        IAny2EVMMessageReceiver(receiver).ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: messageId,
                sourceChainSelector: sourceChainSelector,
                sender: sender,
                data: data,
                destTokenAmounts: tokens
            })
        );
    }
}

/// @title MockBlocklistToken — ERC-20 whose issuer can block accounts from sending or receiving (like B20)
contract MockBlocklistToken is ERC20 {
    uint8 private immutable _decimals;
    mapping(address => bool) public blocked;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool on) external {
        blocked[account] = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[from] && !blocked[to], "PolicyForbids");
        super._update(from, to, value);
    }
}

/// @title MockFeeToken — ERC-20 that burns 1% of every transfer
contract MockFeeToken is ERC20 {
    constructor() ERC20("Fee", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 cut = value / 100;
            super._update(from, address(0), cut);
            value -= cut;
        }
        super._update(from, to, value);
    }
}
