// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TestBalance is Test {
    uint256 private recordedBalance;
    address private recordedBalanceAddress;
    IERC20 private recordedBalanceToken;

    function recordBalance(address token, address addr) internal {
        recordedBalanceToken = IERC20(token);
        recordedBalance = recordedBalanceToken.balanceOf(addr);
        recordedBalanceAddress = addr;
    }

    function recordEthBalance(address _address) internal {
        recordedBalance = _address.balance;
        recordedBalanceAddress = _address;
    }

    function getBalanceChange() internal view returns (int256) {
        uint256 currentBalance = recordedBalanceToken.balanceOf(
            recordedBalanceAddress
        );
        return int256(currentBalance) - int256(recordedBalance);
    }

    function assertBalanceNotChanged() internal view {
        uint256 currentBalance = recordedBalanceToken.balanceOf(
            recordedBalanceAddress
        );
        assertEq(currentBalance, recordedBalance);
    }

    function assertBalanceIncreased(uint256 increasedBy) internal view {
        uint256 currentBalance = recordedBalanceToken.balanceOf(
            recordedBalanceAddress
        );
        assertGt(currentBalance, recordedBalance);
        assertEq(currentBalance - recordedBalance, increasedBy);
    }

    function assertBalanceDecreased(uint256 dereasedBy) internal view {
        uint256 currentBalance = recordedBalanceToken.balanceOf(
            recordedBalanceAddress
        );
        assertGt(recordedBalance, currentBalance);
        assertEq(recordedBalance - currentBalance, dereasedBy);
    }

    function assertBalanceIncreasedApprox(uint256 increasedBy) internal view {
        uint256 currentBalance = recordedBalanceToken.balanceOf(
            recordedBalanceAddress
        );
        assertGt(currentBalance, recordedBalance);
        assertApproxEqRel(
            currentBalance - recordedBalance,
            increasedBy,
            0.001 ether
        );
    }

    function assertEthBalanceIncreased(uint256 increasedBy) internal view {
        uint256 currentBalance = recordedBalanceAddress.balance;
        assertGt(currentBalance, recordedBalance);
        assertEq(currentBalance - recordedBalance, increasedBy);
    }

    function assertEthBalanceIncreasedApprox(
        uint256 increasedBy
    ) internal view {
        uint256 currentBalance = recordedBalanceAddress.balance;
        assertGt(currentBalance, recordedBalance);
        assertApproxEqRel(
            currentBalance - recordedBalance,
            increasedBy,
            0.001 ether
        );
    }

    function assertEthBalanceDecreasedApprox(
        uint256 increasedBy
    ) internal view {
        uint256 currentBalance = recordedBalanceAddress.balance;
        assertLt(currentBalance, recordedBalance);
        assertApproxEqRel(
            recordedBalance - currentBalance,
            increasedBy,
            0.001 ether
        );
    }

    function assertBalanceDecreasedApprox(uint256 dereasedBy) internal view {
        uint256 currentBalance = recordedBalanceToken.balanceOf(
            recordedBalanceAddress
        );
        assertGt(recordedBalance, currentBalance);
        assertApproxEqRel(
            recordedBalance - currentBalance,
            dereasedBy,
            0.001 ether
        );
    }
}
