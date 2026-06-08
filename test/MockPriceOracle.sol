// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPriceOracle} from "../src/IPriceOracle.sol";

/// @notice In-memory IPriceOracle for tests. Replaces the legacy
///         MockPyth + PythAdapter combo. Two ways to set prices:
///           1. `setPrice(feedId, priceWei)` — direct, bypasses everything.
///           2. `getUpdatePriceData(feedId, priceWei)` + pass to
///              `updatePriceFeeds()` — exercises the pool's payable
///              update path (fee forwarding, refund, etc).
contract MockPriceOracle is IPriceOracle {
    mapping(bytes32 => Price) private prices;
    uint256 public updateFee;

    function setUpdateFee(uint256 fee) external {
        updateFee = fee;
    }

    function setPrice(bytes32 id, uint256 price18) external {
        _writePrice(id, price18);
    }

    /// @notice Encode (feedId, priceWei) into the bytes blob expected by
    ///         `updatePriceFeeds`. Mirrors the helper that
    ///         `pythMock.getUpdatePriceData` provided in the legacy tests.
    function getUpdatePriceData(
        bytes32 id,
        uint256 price18
    ) external pure returns (bytes memory) {
        return abi.encode(id, price18);
    }

    function updatePriceFeeds(
        bytes[] calldata updateData
    ) external payable override {
        require(msg.value >= updateFee * updateData.length, "fee");
        for (uint256 i = 0; i < updateData.length; i++) {
            (bytes32 id, uint256 price18) = abi.decode(
                updateData[i],
                (bytes32, uint256)
            );
            _writePrice(id, price18);
        }
    }

    function getPriceNoOlderThan(
        bytes32 id,
        uint256 age
    ) external view override returns (Price memory p) {
        p = prices[id];
        if (p.publishTime == 0) revert PriceFeedNotFound();
        if (block.timestamp - p.publishTime > age) revert StalePrice();
    }

    function getUpdateFee(
        bytes[] calldata updateData
    ) external view override returns (uint256) {
        return updateFee * updateData.length;
    }

    function _writePrice(bytes32 id, uint256 price18) internal {
        prices[id] = Price({
            price: int64(uint64(price18 / 1e10)),
            expo: -8,
            publishTime: uint64(block.timestamp)
        });
    }
}
