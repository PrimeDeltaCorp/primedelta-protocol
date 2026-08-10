// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

// PrimeDelta audit — R2-C-13 READ-ONLY REENTRANCY invariant suite for DclexPool.
//
// Property INV-ROR:
//   DclexPool.swapExact{Input,Output} transfer the OUTPUT token to `recipient`
//   BEFORE invoking `dclexSwapCallback` and BEFORE the input token is pulled in.
//   The nonReentrant guard protects state-changing entrypoints but NOT the
//   `getReserves()` / balanceOf views. So a caller (or any third-party contract
//   the callback re-enters) that reads pool reserves DURING the callback sees a
//   MID-SWAP, DEFLATED view: the output has already left, the input has not yet
//   arrived. This is the read-only-reentrancy window flagged by R2-C-13.
//
// The handler below IS the swap caller. Inside its dclexSwapCallback it reads
//   pool.getReserves() and the raw token balances and records them as ghost
//   state BEFORE paying the input. We then assert two properties:
//
//   (1) INV-ROR-WINDOW-PRESENT: on EVERY settled swap, the input-token RAW
//       BALANCE observed inside the callback is STRICTLY BELOW the settled
//       post-swap balance. The pool cannot guard another contract's view, so
//       this leak is irreducible and is asserted to be consistently present —
//       it documents why raw balanceOf is never a valid pricing source.
//
//   (2) INV-ROR-POST-CONSISTENT: AFTER every swap settles, the public view
//       getReserves() equals raw token balances minus collected protocol fees.
//       The transient mid-swap deflation has fully closed once control returns.
//
// Run:
//   FOUNDRY_EVM_VERSION=cancun forge test \
//     --match-path test/invariant/Invariant_ReadOnlyReentrancy.t.sol -vvv

import {Test, console} from "forge-std/Test.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DclexPool} from "../../src/DclexPool.sol";
import {IDclexSwapCallback} from "../../src/IDclexSwapCallback.sol";
import {DclexPoolTest} from "../DclexPool.t.sol";
import {DeployDclexPool} from "script/DeployDclexPool.s.sol";

/// @notice Bounded-action handler that acts as the swap caller. Its
///         dclexSwapCallback performs the read-only reentrant observation
///         (reads pool.getReserves() + raw balances mid-swap) and only THEN
///         pays the input token back to the pool.
contract ReadOnlyReentrancyHandler is IDclexSwapCallback, StdUtils {
    DclexPool public pool;
    IERC20 public stock; // 18-dec
    IERC20 public stablecoin; // 6-dec
    address public priceSetter; // MockPriceOracle low-level setter
    bytes32 public feedId;

    // ---- mid-swap snapshot, written INSIDE the callback ----
    uint256 public ghost_midStockR; // getReserves() stock reserve (18-dec)
    uint256 public ghost_midScR; // getReserves() stablecoin reserve (18-dec)
    uint256 public ghost_midStockRaw; // raw stock balanceOf(pool)
    uint256 public ghost_midScRaw; // raw stablecoin balanceOf(pool) (6-dec)
    bool public ghost_callbackFired;

    // ---- window accounting ----
    uint256 public ghost_swapsExecuted;
    uint256 public ghost_windowChecks; // swaps we compared mid vs post
    uint256 public ghost_windowPresentCount; // swaps where mid input reserve < post
    bool public ghost_windowAbsent; // set if any settled swap showed NO window
    uint256 public ghost_viewBlocked; // callbacks where getReserves() reverted
    bool public ghost_probeInsideCallback; // poolOperationInProgress() seen mid-swap
    bool public ghost_viewLeaked; // set if a guarded view ever answered mid-swap
    uint256 public callCount;

    bytes[] internal EMPTY;

    constructor(
        DclexPool _pool,
        IERC20 _stock,
        IERC20 _stablecoin,
        address _priceSetter,
        bytes32 _feedId
    ) {
        pool = _pool;
        stock = _stock;
        stablecoin = _stablecoin;
        priceSetter = _priceSetter;
        feedId = _feedId;
    }

    // ---- swap callback: READ pool views mid-swap, THEN pay the input ----
    function dclexSwapCallback(
        address token,
        uint256 amount,
        bytes calldata
    ) external override {
        // getReserves() now carries nonReentrantView, so reading it here — the
        // exact read-only-reentrancy window — must REVERT rather than answer
        // with a mid-swap, deflated view.
        try pool.getReserves() returns (uint256 sR, uint256 cR) {
            ghost_midStockR = sR;
            ghost_midScR = cR;
            ghost_viewLeaked = true;
        } catch {
            ghost_viewBlocked++;
        }

        // Raw ERC20 balances stay readable — the pool cannot guard another
        // contract's view. This is the irreducible leak the guard does not
        // close, and integrators must never price off it.
        ghost_midStockRaw = stock.balanceOf(address(pool));
        ghost_midScRaw = stablecoin.balanceOf(address(pool));
        ghost_probeInsideCallback = pool.poolOperationInProgress();
        ghost_callbackFired = true;

        // Now settle the input the pool is owed.
        IERC20(token).transfer(msg.sender, amount);
    }

    // Keep the signed price fresh + in a band that keeps the pool tradeable on
    // BOTH sides (a wild jump drives the pool to ~100%/0% stock value and the
    // imbalance-fee curve correctly refuses same-side trades — a real protocol
    // limit, not the property under test).
    function _refreshPrice(uint256 price18) internal {
        price18 = bound(price18, 0.4 ether, 2.5 ether);
        (bool ok, ) = priceSetter.call(
            abi.encodeWithSignature("setPrice(bytes32,uint256)", feedId, price18)
        );
        ok;
    }

    function _reserveStock() internal view returns (uint256 s) {
        (s, ) = pool.getReserves();
    }

    function _reserveSc6() internal view returns (uint256) {
        (, uint256 scR18) = pool.getReserves();
        return scR18 / 1e12;
    }

    // Record the read-only-reentrancy window for a just-settled swap: the
    // input-token reserve observed inside the callback must be STRICTLY BELOW
    // the settled reserve (the input landed only after the callback returned).
    function _recordWindow(bool stablecoinInput) internal {
        if (!ghost_callbackFired) return;
        ghost_windowChecks++;
        uint256 postStockRaw = stock.balanceOf(address(pool));
        uint256 postScRaw = stablecoin.balanceOf(address(pool));
        // input token = stablecoin for a buy, stock for a sell.
        uint256 midInputR = stablecoinInput ? ghost_midScRaw : ghost_midStockRaw;
        uint256 postInputR = stablecoinInput ? postScRaw : postStockRaw;
        if (midInputR < postInputR) {
            ghost_windowPresentCount++;
        } else {
            // The mid-swap view was NOT deflated: either the input arrived
            // before the callback (guard closed the window) or accounting is
            // wrong. Under R2-C-13 this must never happen.
            ghost_windowAbsent = true;
        }
    }

    // ---------- ACTIONS ----------

    /// Buy stock with stablecoin, exact input.
    function buyExactIn(uint256 price18, uint256 scIn) external {
        callCount++;
        _refreshPrice(price18);
        uint256 cap = _reserveSc6();
        uint256 hi = cap / 10;
        if (hi < 1e6) hi = 1e6;
        scIn = bound(scIn, 1e6, hi);
        ghost_callbackFired = false;
        try pool.swapExactInput(true, scIn, address(this), "", EMPTY) returns (
            uint256
        ) {
            ghost_swapsExecuted++;
            _recordWindow(true);
        } catch {}
    }

    /// Sell stock for stablecoin, exact input.
    function sellExactIn(uint256 price18, uint256 stockIn) external {
        callCount++;
        _refreshPrice(price18);
        uint256 cap = _reserveStock();
        uint256 hi = cap / 10;
        if (hi < 1 ether) hi = 1 ether;
        stockIn = bound(stockIn, 1 ether, hi);
        ghost_callbackFired = false;
        try pool.swapExactInput(false, stockIn, address(this), "", EMPTY) returns (
            uint256
        ) {
            ghost_swapsExecuted++;
            _recordWindow(false);
        } catch {}
    }

    /// Buy stock, exact output (stablecoin is the input token).
    function buyExactOut(uint256 price18, uint256 stockOut) external {
        callCount++;
        _refreshPrice(price18);
        uint256 cap = _reserveStock();
        stockOut = bound(stockOut, 0, cap == 0 ? 1 : cap / 10);
        ghost_callbackFired = false;
        try
            pool.swapExactOutput(true, stockOut, address(this), "", EMPTY)
        returns (uint256) {
            ghost_swapsExecuted++;
            _recordWindow(true);
        } catch {}
    }

    /// Sell stock, exact output (stock is the input token).
    function sellExactOut(uint256 price18, uint256 scOut) external {
        callCount++;
        _refreshPrice(price18);
        uint256 cap = _reserveSc6();
        scOut = bound(scOut, 0, cap == 0 ? 1 : cap / 10);
        ghost_callbackFired = false;
        try
            pool.swapExactOutput(false, scOut, address(this), "", EMPTY)
        returns (uint256) {
            ghost_swapsExecuted++;
            _recordWindow(false);
        } catch {}
    }

    /// Move the price without swapping — keeps the feed fresh + exercises
    /// imbalance states between trades.
    function jigglePrice(uint256 price18) external {
        callCount++;
        _refreshPrice(price18);
    }
}

contract Invariant_ReadOnlyReentrancy is DclexPoolTest {
    DclexPool internal pool; // fee-bearing pool under test
    ReadOnlyReentrancyHandler internal handler;

    // Non-zero fee curve so swaps actually move value + collect protocol fees
    // (makes property (2)'s "- collected fees" term non-trivial).
    uint256 internal constant FEE_A = 0.0005 ether;
    uint256 internal constant FEE_B = 0.003 ether; // 0.3% floor
    uint256 internal constant PROTOCOL_FEE = 0.1 ether; // 10% (<= 0.15 cap)

    function setUp() public override {
        super.setUp(); // Factory/DID/Stock/MockPriceOracle world + default pools

        // Fresh AAPL pool with a non-zero fee curve AND a non-zero protocol fee
        // so collectedProtocolFees actually accumulate.
        DeployDclexPool poolDeployer = new DeployDclexPool();
        pool = poolDeployer.deploy(aaplStock, helperConfig, FEE_A, FEE_B, PROTOCOL_FEE, makeAddr("ror_pool_lp"));

        vm.prank(ADMIN);
        digitalIdentity.mintAdmin(address(pool), 0, bytes32(0));

        // Initialize from a DEDICATED LP (not address(this)) so inherited
        // DclexPoolTest unit tests (re-run under --match-path) stay unperturbed.
        address poolLp = makeAddr("ror_pool_lp");
        vm.prank(ADMIN);
        digitalIdentity.mintAdmin(poolLp, 0, bytes32(0));
        vm.prank(ADMIN);
        stocksFactory.forceMintStocks("AAPL", poolLp, 10_000 ether);
        usdcMock.mint(poolLp, 10_000e6);
        skip(1);
        priceOracle.setPrice(AAPL_PRICE_FEED_ID, 1 ether);
        bytes[] memory empty = new bytes[](0);
        vm.startPrank(poolLp);
        aaplStock.approve(address(pool), type(uint256).max);
        usdcMock.approve(address(pool), type(uint256).max);
        pool.initialize(5000 ether, 5000e6, poolLp, empty);
        vm.stopPrank();

        // Deploy + fund the handler (DID, stock, dUSD, approvals).
        handler = new ReadOnlyReentrancyHandler(
            pool,
            IERC20(address(aaplStock)),
            IERC20(address(usdcMock)),
            address(priceOracle),
            AAPL_PRICE_FEED_ID
        );
        vm.prank(ADMIN);
        digitalIdentity.mintAdmin(address(handler), 0, bytes32(0));
        vm.prank(ADMIN);
        stocksFactory.forceMintStocks("AAPL", address(handler), 1_000_000 ether);
        usdcMock.mint(address(handler), 1_000_000e6);
        vm.startPrank(address(handler));
        aaplStock.approve(address(pool), type(uint256).max);
        usdcMock.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        // Target only the handler's action selectors (exclude dclexSwapCallback,
        // which is the pool's reentrant callback and only fires inside a swap).
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.buyExactIn.selector;
        selectors[1] = handler.sellExactIn.selector;
        selectors[2] = handler.buyExactOut.selector;
        selectors[3] = handler.sellExactOut.selector;
        selectors[4] = handler.jigglePrice.selector;
        targetSelector(
            StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors})
        );
        targetContract(address(handler));
    }

    // ============================================================
    // INV-ROR-WINDOW-PRESENT: the read-only-reentrancy window exists on EVERY
    // settled swap. The input-token reserve read INSIDE the callback is always
    // strictly below the settled post-swap reserve — output leaves before input
    // arrives. This is EXPECTED per R2-C-13; we assert the window is never
    // absent (mid-swap view is always the deflated one).
    // ============================================================
    function invariant_guardedViewsNeverAnswerMidSwap() public view {
        assertFalse(
            handler.ghost_viewLeaked(),
            "getReserves() answered during a swap callback"
        );
    }

    function invariant_readOnlyReentrancyWindowPresent() public view {
        assertFalse(
            handler.ghost_windowAbsent(),
            "a settled swap showed NO mid-swap deflation window"
        );
        // Equivalent framing: every checked swap presented the window.
        assertEq(
            handler.ghost_windowChecks(),
            handler.ghost_windowPresentCount(),
            "window-present count != window-check count"
        );
    }

    // ============================================================
    // INV-ROR-POST-CONSISTENT: after every swap settles, the public view
    // getReserves() equals raw token balances minus collected protocol fees.
    // The transient mid-swap deflation has fully closed; the post-swap view is
    // internally consistent. (Invariants run at the top level, i.e. AFTER the
    // swap returns — never mid-callback.)
    // ============================================================
    function invariant_postSwapViewConsistent() public view {
        (uint256 stockR, uint256 scR) = pool.getReserves();
        (uint256 feeStock, uint256 feeSc) = pool.collectedProtocolFees();
        assertEq(
            stockR,
            aaplStock.balanceOf(address(pool)) - feeStock,
            "stock reserve != raw balance - collected fees"
        );
        assertEq(
            scR,
            usdcMock.balanceOf(address(pool)) * 1e12 - feeSc,
            "stablecoin reserve != raw balance - collected fees"
        );
    }

    function afterInvariant() public view {
        assertGt(handler.ghost_swapsExecuted(), 0, "campaign executed no swaps");
        assertGt(handler.ghost_viewBlocked(), 0, "view guard never exercised");
        assertTrue(
            handler.ghost_probeInsideCallback(),
            "poolOperationInProgress() did not report true mid-swap"
        );
        console.log("handler callCount (last seq):", handler.callCount());
        console.log("swaps executed (last seq):", handler.ghost_swapsExecuted());
        console.log("window checks (last seq):", handler.ghost_windowChecks());
        console.log(
            "windows present (last seq):",
            handler.ghost_windowPresentCount()
        );
    }

    // ============================================================
    // Deterministic non-vacuity proof + explicit documentation of the R2-C-13
    // window on BOTH getReserves() and the raw token balances, for BOTH swap
    // directions. Without this, the assertFalse-style invariants above could
    // pass on a no-op campaign.
    // ============================================================
    function test_ror_windowIsPresentDeterministic() public {
        priceOracle.setPrice(AAPL_PRICE_FEED_ID, 1 ether);

        // ---------- BUY: stablecoin is the input; its reserve is deflated ----
        (, uint256 preScR) = pool.getReserves();
        uint256 preRawStock = aaplStock.balanceOf(address(pool));
        uint256 preRawSc = usdcMock.balanceOf(address(pool));

        handler.buyExactIn(0, 100e6);

        assertGt(handler.ghost_swapsExecuted(), 0, "no swap executed");
        assertGt(handler.ghost_windowChecks(), 0, "no window observed");
        assertFalse(handler.ghost_windowAbsent(), "window absent on buy");

        // getReserves() is guarded: the callback's read reverted instead of
        // answering with the deflated mid-swap view.
        assertGt(handler.ghost_viewBlocked(), 0, "getReserves() was not blocked mid-swap");
        assertFalse(handler.ghost_viewLeaked(), "getReserves() answered mid-swap");
        assertTrue(
            handler.ghost_probeInsideCallback(),
            "poolOperationInProgress() must be true inside the callback"
        );
        assertFalse(pool.poolOperationInProgress(), "probe must be false at rest");
        (, uint256 postScR) = pool.getReserves();
        assertGt(postScR, preScR, "settled sc reserve did not grow after the buy");
        // Same story on RAW balances: the OUTPUT stock already left the pool
        // during the callback (mid raw stock < pre raw stock), while the INPUT
        // stablecoin had not yet arrived (mid raw sc == pre raw sc).
        assertLt(
            handler.ghost_midStockRaw(),
            preRawStock,
            "mid-swap raw stock not reduced -> output not yet sent?"
        );
        assertEq(
            handler.ghost_midScRaw(),
            preRawSc,
            "mid-swap raw sc changed -> input arrived before callback?"
        );
        _assertViewConsistent();

        // ---------- SELL: stock is the input; its reserve is deflated --------
        priceOracle.setPrice(AAPL_PRICE_FEED_ID, 1 ether);
        (uint256 preStockR2, ) = pool.getReserves();
        uint256 preRawSc2 = usdcMock.balanceOf(address(pool));

        handler.sellExactIn(0, 50 ether);

        assertFalse(handler.ghost_windowAbsent(), "window absent on sell");
        assertFalse(handler.ghost_viewLeaked(), "getReserves() answered mid-swap");
        (uint256 postStockR2, ) = pool.getReserves();
        assertGt(
            postStockR2,
            preStockR2,
            "settled stock reserve did not grow after the sell"
        );
        // OUTPUT stablecoin already left the pool during the callback.
        assertLt(
            handler.ghost_midScRaw(),
            preRawSc2,
            "mid-swap raw sc not reduced -> output not yet sent?"
        );
        _assertViewConsistent();

        // Non-vacuity for property (2): protocol fees actually accumulated on
        // BOTH sides (buy -> stock fee, sell -> stablecoin fee), so the
        // "- collected fees" term in the post-swap consistency check is real.
        (uint256 feeStock, uint256 feeSc) = pool.collectedProtocolFees();
        assertGt(feeStock, 0, "no stock protocol fee collected on buy");
        assertGt(feeSc, 0, "no stablecoin protocol fee collected on sell");
    }

    function _assertViewConsistent() internal view {
        (uint256 stockR, uint256 scR) = pool.getReserves();
        (uint256 feeStock, uint256 feeSc) = pool.collectedProtocolFees();
        assertEq(
            stockR,
            aaplStock.balanceOf(address(pool)) - feeStock,
            "post-swap: stock reserve != raw - fees"
        );
        assertEq(
            scR,
            usdcMock.balanceOf(address(pool)) * 1e12 - feeSc,
            "post-swap: sc reserve != raw - fees"
        );
    }
}
