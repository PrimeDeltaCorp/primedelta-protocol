// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

interface IPriceOracle {
    struct Price {
        int64 price;
        int32 expo;
        uint64 publishTime;
    }

    error StalePrice();
    error PriceFeedNotFound();

    function updatePriceFeeds(bytes[] calldata updateData) external payable;

    function getPriceNoOlderThan(
        bytes32 id,
        uint256 age
    ) external view returns (Price memory);

    function getUpdateFee(
        bytes[] calldata updateData
    ) external view returns (uint256);
}
