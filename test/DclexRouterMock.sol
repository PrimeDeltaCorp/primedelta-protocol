// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDclexSwapCallback} from "../src/IDclexSwapCallback.sol";

contract DclexRouterMock is IDclexSwapCallback {
    struct CallbackData {
        address recordBalanceToken;
    }

    uint256 private amountToBePaid;
    bool private amountToBePaidSet;
    bool public dclexSwapCallbackCalled;
    uint256 public recordedBalance;

    function dclexSwapCallback(
        address token,
        uint256 amount,
        bytes calldata callbackData
    ) external {
        if (callbackData.length > 4) {
            CallbackData memory decodedData = abi.decode(
                callbackData,
                (CallbackData)
            );
            recordedBalance = IERC20(decodedData.recordBalanceToken).balanceOf(
                address(this)
            );
        }
        dclexSwapCallbackCalled = true;
        IERC20(token).transfer(
            msg.sender,
            amountToBePaidSet ? amountToBePaid : amount
        );
    }

    function setAmountToBePaid(uint256 _amountToBePaid) external {
        amountToBePaidSet = true;
        amountToBePaid = _amountToBePaid;
    }

    function reset() external {
        dclexSwapCallbackCalled = false;
    }
}
