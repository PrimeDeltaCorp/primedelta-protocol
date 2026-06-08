// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

interface IDclexSwapCallback {
    function dclexSwapCallback(
        address token,
        uint256 amount,
        bytes calldata callbackData
    ) external;
}
