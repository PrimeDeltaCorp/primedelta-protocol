# DCLEX protocol

## Getting Started
You can install dclex-protocol in your project using forge:
```
forge install dclex-platform/dclex-protocol
```

To use DCLEX pools in your contract you need to make your contract implement the `IDclexSwapCallback` interface. Its `dclexSwapCallback` should be able to pay swap input tokens to the pool. Always remember to verify if these payment requests actually come from the expected DCLEX pool.

```solidity
import {IDclexSwapCallback} from "src/IDclexSwapCallback.sol";
import {DclexPool} from "src/DclexPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MyContract is IDclexSwapCallback {
    error NotDclexPool();
    DclexPool pool;

    function dclexSwapCallback(
        address token,
        uint256 amount,
        bytes calldata callbackData
    ) external {
        if (msg.sender != address(pool)) {
            revert NotDclexPool();
        }
        IERC20(token).transfer(msg.sender, amount);
    }

    function doSomeSwap(address recipient) external {
        pool.swapExactOutput(true, 1 ether, recipient, "", new bytes[](0));
    }
}
```

## Test
You can run the full test suite using forge:
```
forge test
```

## License
DCLEX protocol is licensed under the Business Source License 1.1 (`BUSL-1.1`)

