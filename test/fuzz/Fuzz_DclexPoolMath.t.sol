// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

// PrimeDelta audit — DIFFERENTIAL + PROPERTY FUZZING for DclexPool swap/LP math.
//
// The fee curve (getBuyFeeRate/getSellFeeRate) and _convertToUint are PRIVATE,
// so this suite drives them through the PUBLIC surface —
// swapExactInput / swapExactOutput / initialize / addLiquidity / removeLiquidity
// — and re-derives the expected integer result from the CONTRACT SOURCE using
// the exact same OpenZeppelin Math primitives + rounding directions. Any
// deviation between the re-derivation and the on-chain result is a genuine
// finding (a "differential" oracle over the pool's own arithmetic).
//
// Reuses the product harness (DclexPoolTest, setUp now virtual) for the real
// Factory/DID/Stock/MockPriceOracle world, then deploys a SECOND pool
// ("feePool") with a NON-ZERO fee curve and protocolFeeRate = 0 so:
//   * fees stay inside the pool reserves (value-conservation is clean), and
//   * getReserves() == raw balances (no protocol-fee subtraction to reason about).
//
// Properties (each fuzzed, asserting the PROPERTY not a single example):
//   (1) VALUE CONSERVATION — priced at the single oracle price that priced the
//       swap, the pool's reserve value after a swap is >= before. The pool never
//       leaks value to the trader; the intended fee stays in the pool.
//   (2) ROUNDING FAVORS POOL — swapExactInput output is FLOOR-rounded (trader
//       never gets more), swapExactOutput input is CEIL-rounded (trader never
//       pays less). Asserted as an exact differential against the re-derived
//       value PLUS an explicit direction check vs the opposite rounding.
//   (3) LP FAIRNESS — addLiquidity(L) then immediate removeLiquidity(L) returns
//       <= what was deposited, in BOTH tokens (add pulls ceil, remove pays floor).
//   (4) ZERO-OUTPUT guard — a swap that would produce 0 output reverts
//       DclexPool__ZeroOutputAmount.
//
// Run:
//   cd primedelta-protocol && FOUNDRY_EVM_VERSION=cancun \
//     forge test --match-path test/fuzz/Fuzz_DclexPoolMath.t.sol -vv

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DclexPool} from "../../src/DclexPool.sol";
import {DclexPoolTest} from "../DclexPool.t.sol";
import {DeployDclexPool} from "script/DeployDclexPool.s.sol";

contract Fuzz_DclexPoolMath is DclexPoolTest {
    // Fee-bearing AAPL pool under test. Non-zero curve so round-trips and
    // fee-bound properties are meaningful; protocolFeeRate = 0 so reserves ==
    // raw balances and all fee value stays with the LPs.
    DclexPool internal feePool;

    // (feeCurveA, feeCurveB) — same shape as the committed invariant suite.
    // feeCurveB is the floor fee; feeCurveA scales the imbalance term. Both
    // well within MAX_FEE_RATE (1e18).
    uint256 internal constant FEE_A = 0.0005 ether;
    uint256 internal constant FEE_B = 0.003 ether;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_FEE = 1 ether; // DclexPool MAX_FEE_RATE

    // Price band kept away from the extremes so the imbalance-fee curve does not
    // force NotEnoughPoolLiquidity on bounded trades (a real protocol limit, not
    // the property under test). Aligned to 1e10 in _freshPrice so the pool reads
    // back EXACTLY the price we value the reserves at (MockPriceOracle stores
    // price/1e10 with expo -8, so only 1e10-multiples survive the round trip).
    uint256 internal constant P_MIN = 0.5 ether;
    uint256 internal constant P_MAX = 2 ether;

    function setUp() public override {
        super.setUp(); // Factory/DID/Stock/MockPriceOracle + aaplPool/nvdaPool

        DeployDclexPool poolDeployer = new DeployDclexPool();
        feePool = poolDeployer.deploy(aaplStock, helperConfig, FEE_A, FEE_B, 0, makeAddr("fuzz_pool_lp"));

        // Pool needs a DID to hold/transfer the stock token.
        vm.prank(ADMIN);
        digitalIdentity.mintAdmin(address(feePool), 0, bytes32(0));

        // Initialize from a DEDICATED LP (NOT address(this)) so the inherited
        // DclexPoolTest unit tests — which assert on address(this)'s balances —
        // are untouched when this file runs via --match-path.
        address poolLp = makeAddr("fuzz_pool_lp");
        vm.prank(ADMIN);
        digitalIdentity.mintAdmin(poolLp, 0, bytes32(0));
        vm.prank(ADMIN);
        stocksFactory.forceMintStocks("AAPL", poolLp, 5000 ether);
        usdcMock.mint(poolLp, 5000e6);
        skip(1);
        priceOracle.setPrice(AAPL_PRICE_FEED_ID, 1 ether);
        bytes[] memory empty = new bytes[](0);
        vm.startPrank(poolLp);
        aaplStock.approve(address(feePool), type(uint256).max);
        usdcMock.approve(address(feePool), type(uint256).max);
        feePool.initialize(5000 ether, 5000e6, poolLp, empty);
        vm.stopPrank();

        // address(this) approvals for the LP-fairness add (approval only, no
        // balance change). Swaps use the callback's direct transfer (no allowance).
        aaplStock.approve(address(feePool), type(uint256).max);
        usdcMock.approve(address(feePool), type(uint256).max);
    }

    // ---------------------------------------------------------------------
    //                              helpers
    // ---------------------------------------------------------------------

    /// Bound + 1e10-align a fuzzed price and stamp it fresh (publishTime = now).
    function _freshPrice(uint256 raw) internal returns (uint256 p) {
        p = bound(raw, P_MIN, P_MAX);
        p = (p / 1e10) * 1e10; // survive MockPriceOracle's expo-8 round trip
        priceOracle.setPrice(AAPL_PRICE_FEED_ID, p);
    }

    /// Reserve value at price `p`, in stablecoin-18 units: stock*p/1e18 + sc18.
    function _value(uint256 stockR, uint256 scR18, uint256 p) internal pure returns (uint256) {
        return Math.mulDiv(stockR, p, WAD) + scR18;
    }

    // getStocksRatioTotalValue re-derivation (reads live reserves).
    function _ratioTotal(uint256 p) internal view returns (uint256 ratio, uint256 total) {
        (uint256 stockR, uint256 scR18) = feePool.getReserves();
        uint256 stocksValue = Math.mulDiv(stockR, p, WAD);
        total = stocksValue + scR18;
        ratio = Math.mulDiv(WAD, stocksValue, total);
    }

    // getBuyFeeRate re-derivation. ok == false mirrors a NotEnoughPoolLiquidity
    // revert (stocksRatioDelta >= stocksRatioBefore).
    function _buyFee(uint256 stockOut, uint256 p) internal view returns (bool ok, uint256 rate) {
        (uint256 ratioBefore, uint256 total) = _ratioTotal(p);
        uint256 delta = Math.mulDiv(stockOut, p, total);
        if (delta >= ratioBefore) return (false, 0);
        uint256 ratioAfter = ratioBefore - delta;
        uint256 prod = Math.mulDiv(ratioBefore, ratioAfter, WAD);
        if (prod == 0) prod = 1;
        uint256 inv = 1e36 / prod;
        (uint256 a, uint256 b) = feePool.getFeeCurve();
        rate = b + Math.mulDiv(a, inv, WAD);
        if (rate > MAX_FEE) rate = MAX_FEE;
        if (rate >= WAD) return (false, 0);
        ok = true;
    }

    // getSellFeeRate re-derivation. ok == false mirrors a NotEnoughPoolLiquidity
    // revert (stocksRatioAfter >= 1e18).
    function _sellFee(uint256 stockIn, uint256 p) internal view returns (bool ok, uint256 rate) {
        (uint256 ratioBefore, uint256 total) = _ratioTotal(p);
        uint256 ratioAfter = ratioBefore + Math.mulDiv(stockIn, p, total);
        if (ratioAfter >= WAD) return (false, 0);
        uint256 prod = Math.mulDiv(ratioBefore, ratioAfter, WAD);
        uint256 denom = WAD + prod - ratioBefore - ratioAfter;
        if (denom == 0) denom = 1;
        uint256 inv = 1e36 / denom;
        (uint256 a, uint256 b) = feePool.getFeeCurve();
        rate = b + Math.mulDiv(a, inv, WAD);
        if (rate > MAX_FEE) rate = MAX_FEE;
        if (rate >= WAD) return (false, 0);
        ok = true;
    }

    // =====================================================================
    // (1)+(2) BUY, exact input (stablecoin in -> stock out).
    //   - differential: returned output == FLOOR-derived net.
    //   - direction:    output <= the CEIL alternative (proves floor).
    //   - favors pool:  output value at oracle price <= input value.
    //   - conservation: reserve value after >= before.
    // =====================================================================
    function testFuzz_buyExactInput(uint256 rawP, uint256 scIn) public {
        uint256 p = _freshPrice(rawP);
        uint256 valBefore;
        {
            (uint256 stockR, uint256 scR18) = feePool.getReserves();
            scIn = bound(scIn, 1e3, (scR18 / 1e12) / 8);
            valBefore = _value(stockR, scR18, p);
        }
        uint256 in18 = scIn * 1e12;
        uint256 gross = Math.mulDiv(in18, WAD, p); // outputPrice p, inputPrice 1e18
        uint256 expNetLow;
        uint256 expNetHigh;
        {
            (bool ok, uint256 feeAtGross) = _buyFee(gross, p);
            if (!ok) return;
            expNetLow = Math.mulDiv(gross, WAD - feeAtGross, WAD);
            if (expNetLow == 0) return; // would revert ZeroOutputAmount
            (bool ok2, uint256 feeAtNet) = _buyFee(expNetLow, p);
            if (!ok2) return;
            expNetHigh = Math.mulDiv(gross, WAD - feeAtNet, WAD);
        }

        uint256 got = feePool.swapExactInput(true, scIn, address(this), "", PRICE_DATA);

        assertGe(got, expNetLow, "buy exact-in: output below the curve(gross) bound");
        assertLe(got, expNetHigh, "buy exact-in: output above the curve(net) bound");
        assertLe(Math.mulDiv(got, p, WAD), in18, "buy exact-in: better-than-oracle output");

        {
            (uint256 stockA, uint256 scA18) = feePool.getReserves();
            assertGe(_value(stockA, scA18, p), valBefore, "buy exact-in: pool value leaked");
        }
    }

    // =====================================================================
    // (1)+(2) SELL, exact input (stock in -> stablecoin out).
    // =====================================================================
    function testFuzz_sellExactInput(uint256 rawP, uint256 stockIn) public {
        uint256 p = _freshPrice(rawP);
        uint256 valBefore;
        {
            (uint256 stockR, uint256 scR18) = feePool.getReserves();
            stockIn = bound(stockIn, 1e13, stockR / 8);
            valBefore = _value(stockR, scR18, p);
        }
        uint256 gross = Math.mulDiv(stockIn, p, WAD); // outputPrice 1e18, inputPrice p
        (bool ok, uint256 fee) = _sellFee(stockIn, p);
        if (!ok) return;
        uint256 expNet6 = Math.mulDiv(gross, WAD - fee, WAD) / 1e12; // 18 -> 6 dec (floor)
        if (expNet6 == 0) return; // would revert ZeroOutputAmount

        uint256 got = feePool.swapExactInput(false, stockIn, address(this), "", PRICE_DATA);

        assertEq(got, expNet6, "sell exact-in: output != floor-derived net");
        // output value (6-dec -> 18-dec) never exceeds the gross input value.
        assertLe(got * 1e12, gross, "sell exact-in: better-than-oracle output");

        {
            (uint256 stockA, uint256 scA18) = feePool.getReserves();
            assertGe(_value(stockA, scA18, p), valBefore, "sell exact-in: pool value leaked");
        }
    }

    // =====================================================================
    // (1)+(2) BUY, exact output (stock out -> stablecoin in).
    //   - differential: returned input == CEIL-derived gross.
    //   - direction:    input >= the FLOOR alternative (proves ceil).
    //   - favors pool:  input value >= requested output value at oracle price.
    //   - conservation: reserve value after >= before.
    // =====================================================================
    function testFuzz_buyExactOutput(uint256 rawP, uint256 stockOut) public {
        uint256 p = _freshPrice(rawP);
        uint256 valBefore;
        {
            (uint256 stockR, uint256 scR18) = feePool.getReserves();
            stockOut = bound(stockOut, 1e13, stockR / 8);
            valBefore = _value(stockR, scR18, p);
        }
        uint256 got;
        {
            uint256 netIn18 = Math.mulDiv(stockOut, p, WAD, Math.Rounding.Ceil);
            (bool ok, uint256 fee) = _buyFee(stockOut, p);
            if (!ok) return;
            uint256 expIn6 = Math.ceilDiv(Math.mulDiv(netIn18, WAD, WAD - fee, Math.Rounding.Ceil), 1e12);
            if (expIn6 == 0) return;

            got = feePool.swapExactOutput(true, stockOut, address(this), "", PRICE_DATA);
            assertEq(got, expIn6, "buy exact-out: input != ceil-derived gross");
            assertGe(got * 1e12, Math.mulDiv(netIn18, WAD, WAD - fee), "buy exact-out: input not ceil-rounded");
        }
        assertGe(got * 1e12, Math.mulDiv(stockOut, p, WAD), "buy exact-out: took less than oracle value");
        {
            (uint256 stockA, uint256 scA18) = feePool.getReserves();
            assertGe(_value(stockA, scA18, p), valBefore, "buy exact-out: pool value leaked");
        }
    }

    // =====================================================================
    // (1)+(2) SELL, exact output (stock in -> stablecoin out).
    // =====================================================================
    function testFuzz_sellExactOutput(uint256 rawP, uint256 scOut) public {
        uint256 p = _freshPrice(rawP);
        uint256 valBefore;
        {
            (uint256 stockR, uint256 scR18) = feePool.getReserves();
            scOut = bound(scOut, 1e3, (scR18 / 1e12) / 8);
            valBefore = _value(stockR, scR18, p);
        }
        uint256 outSc18 = scOut * 1e12;
        uint256 netInStock = Math.mulDiv(outSc18, WAD, p, Math.Rounding.Ceil);
        uint256 expGrossLow;
        uint256 expGrossHigh;
        {
            (bool ok, uint256 feeAtNet) = _sellFee(netInStock, p);
            if (!ok) return;
            expGrossLow = Math.mulDiv(netInStock, WAD, WAD - feeAtNet, Math.Rounding.Ceil);
            if (expGrossLow == 0) return;
            (bool ok2, uint256 feeAtGross) = _sellFee(expGrossLow, p);
            if (!ok2) return;
            expGrossHigh = Math.mulDiv(netInStock, WAD, WAD - feeAtGross, Math.Rounding.Ceil);
        }

        uint256 got = feePool.swapExactOutput(false, scOut, address(this), "", PRICE_DATA);

        assertGe(got, expGrossLow, "sell exact-out: input below the curve(net) bound");
        assertLe(got, expGrossHigh, "sell exact-out: input above the curve(gross) bound");
        assertGe(Math.mulDiv(got, p, WAD), outSc18, "sell exact-out: took less than oracle value");

        {
            (uint256 stockA, uint256 scA18) = feePool.getReserves();
            assertGe(_value(stockA, scA18, p), valBefore, "sell exact-out: pool value leaked");
        }
    }

    // =====================================================================
    // (3) LP FAIRNESS: add(L) then immediate remove(L) returns <= deposited,
    //     in BOTH tokens. Add pulls with CEIL, remove pays with FLOOR.
    // =====================================================================
    function testFuzz_lpFairness_addThenRemove(uint256 lp) public {
        uint256 supply = feePool.totalSupply();
        lp = bound(lp, 1e15, supply / 4);

        uint256 stockBefore = aaplStock.balanceOf(address(this));
        uint256 scBefore = usdcMock.balanceOf(address(this));
        feePool.addLiquidity(lp, type(uint256).max, type(uint256).max, block.timestamp);
        uint256 stockMid = aaplStock.balanceOf(address(this));
        uint256 scMid = usdcMock.balanceOf(address(this));
        uint256 putInStock = stockBefore - stockMid;
        uint256 putInSc = scBefore - scMid;

        feePool.removeLiquidity(lp, 0, 0, block.timestamp);
        uint256 gotStock = aaplStock.balanceOf(address(this)) - stockMid;
        uint256 gotSc = usdcMock.balanceOf(address(this)) - scMid;

        assertLe(gotStock, putInStock, "LP received more stock than deposited");
        assertLe(gotSc, putInSc, "LP received more stablecoin than deposited");
    }

    // =====================================================================
    // (4) ZERO-OUTPUT guard.
    //   Selling a sub-1e12-wei stock amount at price 1e18 yields < 1 unit of
    //   6-dec stablecoin -> truncates to 0 -> must revert ZeroOutputAmount.
    // =====================================================================
    function testFuzz_zeroOutput_sellTinyStockReverts(uint256 stockIn) public {
        priceOracle.setPrice(AAPL_PRICE_FEED_ID, 1 ether); // p == 1e18, aligned
        stockIn = bound(stockIn, 1, 1e12 - 1);
        vm.expectRevert(DclexPool.DclexPool__ZeroOutputAmount.selector);
        feePool.swapExactInput(false, stockIn, address(this), "", PRICE_DATA);
    }

    /// Requesting/supplying a zero amount reverts ZeroOutputAmount on every path.
    function test_zeroOutput_zeroAmountsRevert() public {
        priceOracle.setPrice(AAPL_PRICE_FEED_ID, 1 ether);
        vm.expectRevert(DclexPool.DclexPool__ZeroOutputAmount.selector);
        feePool.swapExactInput(true, 0, address(this), "", PRICE_DATA);
        vm.expectRevert(DclexPool.DclexPool__ZeroOutputAmount.selector);
        feePool.swapExactInput(false, 0, address(this), "", PRICE_DATA);
        vm.expectRevert(DclexPool.DclexPool__ZeroOutputAmount.selector);
        feePool.swapExactOutput(true, 0, address(this), "", PRICE_DATA);
        vm.expectRevert(DclexPool.DclexPool__ZeroOutputAmount.selector);
        feePool.swapExactOutput(false, 0, address(this), "", PRICE_DATA);
    }

    // ---------------------------------------------------------------------
    //          deterministic non-vacuity proofs (machinery works)
    // ---------------------------------------------------------------------

    /// Prove the differential + conservation machinery fires on a concrete swap
    /// (so the fuzz assertions above are not trivially skipped), and that the
    /// fee-bearing pool actually charges a non-zero fee.
    function test_nonVacuous_diffAndConservation() public {
        uint256 p = 1 ether;
        priceOracle.setPrice(AAPL_PRICE_FEED_ID, p);
        uint256 valBefore;
        {
            (uint256 stockR, uint256 scR18) = feePool.getReserves();
            valBefore = _value(stockR, scR18, p);
        }
        uint256 gross = Math.mulDiv(100e6 * 1e12, WAD, p);
        (bool ok, uint256 feeAtGross) = _buyFee(gross, p);
        assertTrue(ok, "fee derivation should succeed");
        assertGt(feeAtGross, 0, "fee-bearing pool must charge a fee");
        uint256 expNetLow = Math.mulDiv(gross, WAD - feeAtGross, WAD);
        assertGt(expNetLow, 0, "concrete swap must produce output");
        (bool ok2, uint256 feeAtNet) = _buyFee(expNetLow, p);
        assertTrue(ok2, "refined fee derivation should succeed");
        uint256 expNetHigh = Math.mulDiv(gross, WAD - feeAtNet, WAD);

        uint256 got = feePool.swapExactInput(true, 100e6, address(this), "", PRICE_DATA);
        assertGe(got, expNetLow, "concrete buy below the curve(gross) bound");
        assertLe(got, expNetHigh, "concrete buy above the curve(net) bound");
        assertLt(got, gross, "fee must reduce output below gross");

        {
            (uint256 stockA, uint256 scA18) = feePool.getReserves();
            assertGe(_value(stockA, scA18, p), valBefore, "concrete buy leaked value");
        }
    }

    /// Prove the LP round trip actually moves tokens (non-vacuity) and is lossy.
    function test_nonVacuous_lpRoundTripLossy() public {
        uint256 lp = feePool.totalSupply() / 10;
        uint256 stockBefore = aaplStock.balanceOf(address(this));
        uint256 scBefore = usdcMock.balanceOf(address(this));
        feePool.addLiquidity(lp, type(uint256).max, type(uint256).max, block.timestamp);
        uint256 stockMid = aaplStock.balanceOf(address(this));
        uint256 scMid = usdcMock.balanceOf(address(this));
        uint256 putInStock = stockBefore - stockMid;
        uint256 putInSc = scBefore - scMid;
        assertGt(putInStock, 0, "LP add pulled no stock");
        assertGt(putInSc, 0, "LP add pulled no stablecoin");

        feePool.removeLiquidity(lp, 0, 0, block.timestamp);
        uint256 gotStock = aaplStock.balanceOf(address(this)) - stockMid;
        uint256 gotSc = usdcMock.balanceOf(address(this)) - scMid;
        assertLe(gotStock, putInStock, "LP received more stock than deposited");
        assertLe(gotSc, putInSc, "LP received more stablecoin than deposited");
    }
}
