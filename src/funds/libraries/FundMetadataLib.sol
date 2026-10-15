// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFund} from "../../interfaces/IFund.sol";
import {FundInfo} from "../../interfaces/types/FundTypes.sol";

/// @title FundMetadataLib — checks and stores a fund's name, symbol and info
/// @notice External library, linked at deployment and run in the fund's context (delegatecall), so
///         the fund stays under the contract size limit. The fund checks the caller.
library FundMetadataLib {
    /// @notice Check lengths, store the info and emit {IFund.MetadataSet}; the fund stores the name and symbol.
    /// @param info    Info slot.
    /// @param name_   Name (1 to 64 bytes).
    /// @param symbol_ Symbol (1 to 16 bytes).
    /// @param info_   Logo (at most 512 bytes), description (at most 2 000) and links (at most 256 each).
    function set(
        FundInfo storage info,
        string calldata name_,
        string calldata symbol_,
        FundInfo calldata info_
    ) external {
        uint256 nameLen = bytes(name_).length;
        uint256 symbolLen = bytes(symbol_).length;
        if (
            nameLen == 0 || nameLen > 64 || symbolLen == 0 || symbolLen > 16 || bytes(info_.logo).length > 512
                || bytes(info_.description).length > 2000 || bytes(info_.website).length > 256
                || bytes(info_.x).length > 256 || bytes(info_.telegram).length > 256 || bytes(info_.discord).length > 256
        ) revert IFund.InvalidMetadata();
        info.logo = info_.logo;
        info.description = info_.description;
        info.website = info_.website;
        info.x = info_.x;
        info.telegram = info_.telegram;
        info.discord = info_.discord;
        emit IFund.MetadataSet(name_, symbol_, info_);
    }
}
