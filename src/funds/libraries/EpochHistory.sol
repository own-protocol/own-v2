// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title EpochHistory — a value recorded per weekly epoch
/// @notice Each checkpoint holds the value from its epoch until the next checkpoint. Writes only
///         ever touch the current epoch `e` and the next one `e + 1` (a deposit made now counts from
///         the next epoch), so a history never holds a checkpoint later than `e + 1`, and the
///         values of epochs before `e` are final.
library EpochHistory {
    struct Checkpoint {
        uint32 epoch;
        uint224 value;
    }

    struct History {
        Checkpoint[] checkpoints;
    }

    /// @notice The value counted in `epoch`.
    /// @param h     The history.
    /// @param epoch The epoch.
    /// @return The value.
    function valueAt(History storage h, uint256 epoch) internal view returns (uint256) {
        Checkpoint[] storage cps = h.checkpoints;
        uint256 high = cps.length;
        if (high == 0) return 0;
        // The newest two checkpoints answer every query about the current and next epoch.
        Checkpoint storage last = cps[high - 1];
        if (last.epoch <= epoch) return last.value;
        if (high >= 2 && cps[high - 2].epoch <= epoch) return cps[high - 2].value;
        uint256 low;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (cps[mid].epoch > epoch) high = mid;
            else low = mid + 1;
        }
        return high == 0 ? 0 : cps[high - 1].value;
    }

    /// @notice Set the value counted from `current` to `atCurrent` and from `current + 1` to
    ///         `atNext`.
    /// @param h         The history.
    /// @param current   The current epoch.
    /// @param atCurrent Value for the current epoch.
    /// @param atNext    Value from the next epoch on.
    function set(History storage h, uint256 current, uint256 atCurrent, uint256 atNext) internal {
        Checkpoint[] storage cps = h.checkpoints;
        uint256 len = cps.length;
        // Drop a pending next-epoch checkpoint; it is rewritten below.
        if (len != 0 && cps[len - 1].epoch > current) {
            cps.pop();
            --len;
        }
        uint32 e = SafeCast.toUint32(current);
        if (len != 0 && cps[len - 1].epoch == e) {
            cps[len - 1].value = SafeCast.toUint224(atCurrent);
        } else if (len != 0 || atCurrent != 0) {
            cps.push(Checkpoint({epoch: e, value: SafeCast.toUint224(atCurrent)}));
        }
        if (atNext != atCurrent) {
            cps.push(Checkpoint({epoch: e + 1, value: SafeCast.toUint224(atNext)}));
        }
    }

    /// @notice Add `deltaCurrent` to the value counted in the current epoch and `deltaNext` to the
    ///         value counted from the next epoch on.
    /// @param h            The history.
    /// @param current      The current epoch.
    /// @param deltaCurrent Change for the current epoch.
    /// @param deltaNext    Change from the next epoch on.
    function add(History storage h, uint256 current, int256 deltaCurrent, int256 deltaNext) internal {
        if (deltaCurrent == 0 && deltaNext == 0) return;
        uint256 atCurrent = valueAt(h, current);
        uint256 atNext = valueAt(h, current + 1);
        set(h, current, _apply(atCurrent, deltaCurrent), _apply(atNext, deltaNext));
    }

    function _apply(uint256 value, int256 delta) private pure returns (uint256) {
        return delta >= 0 ? value + uint256(delta) : value - uint256(-delta);
    }
}
