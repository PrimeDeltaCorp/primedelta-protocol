// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Callback interface for DclexPool swaps
/// @notice Implemented by any contract that calls `DclexPool.swapExactInput` or
///         `DclexPool.swapExactOutput`. The pool sends the output leg first,
///         then calls back for payment, so the callee is the payer.
interface IDclexSwapCallback {
    /// @notice Pay the pool for a swap in progress.
    /// @dev **Authenticate `msg.sender` before paying.** This function is
    ///      `external`, so anyone can call it and claim a payment is owed. An
    ///      implementation must reject any caller that is not the pool it
    ///      expects — see the README example, and `DclexRouter`'s
    ///      `onlyExpectedDclexCallback`, which pins the sentinel to the one
    ///      pool it is mid-call with. Everything below assumes that check is in
    ///      place; without it the bounds are worthless.
    /// @dev **Bounds are the caller's responsibility.** The pool takes no
    ///      slippage or deadline parameters, matching the Uniswap
    ///      core/periphery split. Three mechanisms are available, and
    ///      `DclexRouter` uses all three:
    ///
    ///      - Revert here when `amount` exceeds the cap. The pool hands over
    ///        the exact input demand before payment settles.
    ///      - Check the swap's return value — `swapExactInput` returns the
    ///        output delivered, `swapExactOutput` the input consumed — and
    ///        revert. The output transfer precedes this call, but reverting in
    ///        the caller's frame unwinds it.
    ///      - Read `block.timestamp` before calling to enforce a deadline.
    ///
    ///      Do not assume a caller-supplied signed price pins the execution
    ///      price: `FIOracle._updateSingleFeed` ignores an update whose
    ///      `publishTime` is not newer than the stored one, so any fresher
    ///      price already pushed by anyone wins. Bound the realised amounts,
    ///      not the price.
    ///
    ///      This function returns nothing, so solc emits an `extcodesize` check
    ///      on the pool's `msg.sender`; an EOA cannot complete a swap.
    /// @param token The token the pool expects to receive
    /// @param amount The exact amount of `token` owed, due before this returns
    /// @param callbackData Opaque data forwarded from the swap call
    function dclexSwapCallback(
        address token,
        uint256 amount,
        bytes calldata callbackData
    ) external;
}
