// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IDclexSwapCallback} from "./IDclexSwapCallback.sol";
import {IPriceOracle} from "./IPriceOracle.sol";
import {IDID} from "dclex-blockchain/contracts/interfaces/IDID.sol";
import {InvalidDID} from "dclex-blockchain/contracts/libs/Model.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";

contract DclexPool is ERC20, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IStock;

    error DclexPool__AlreadyInitialized();
    error DclexPool__NotInitialized();
    error DclexPool__InsufficientInputAmount();
    error DclexPool__ZeroOutputAmount();
    error DclexPool__ZeroLiquidityDeposit();
    error DclexPool__NativeTransferFailed();
    error DclexPool__NotEnoughPoolLiquidity();
    error DclexPool__ProtocolFeeRateTooHigh();
    error DclexPool__InvalidPriceOrExponent();
    error DclexPool__FeeCurveOutOfBounds();
    error DclexPool__InvalidStablecoinDecimals();
    error DclexPool__ZeroAddress();

    uint256 private constant MAX_PROTOCOL_FEE_RATE = 0.15 ether;
    uint8 private constant DECIMALS = 18;
    uint8 private constant STABLECOIN_DECIMALS = 6;
    // Caps configured + runtime fee rate so `1e18 - feeRate` stays >= 0
    // (at feeRate == 1e18 the swap returns zero output, never underflows).
    uint256 private constant MAX_FEE_RATE = 1 ether;
    /// @notice Hard-coded maximum age of a signed price update accepted by
    ///         this pool. Baked in at deploy — no setter, no per-deploy knob.
    uint256 private constant MAX_PRICE_STALENESS = 60 seconds;
    IPriceOracle public immutable oracle;
    IStock public immutable stockToken;
    IERC20 public immutable stablecoinToken;
    bytes32 private immutable stockPriceFeedId;
    bool private initialized = false;
    uint256 private immutable feeCurveA;
    uint256 private immutable feeCurveB;
    uint256 private protocolFeeRate;
    uint256 private collectedProtocolFeesStock;
    uint256 private collectedProtocolFeesStablecoin;

    event LiquidityAdded(
        uint256 addedLiquidity,
        uint256 addedStockAmount,
        uint256 addedStablecoinAmount
    );
    event LiquidityRemoved(
        uint256 removedLiquidity,
        uint256 removedStockAmount,
        uint256 removedStablecoinAmount
    );
    event SwapExecuted(
        bool stablecoinInput,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 stockPrice,
        uint256 stablecoinPrice,
        address recipient
    );
    event ProtocolFeeRateChanged(uint256 feeRate);
    event ProtocolFeeWithdrawn(
        uint256 stocksWithdrawn,
        uint256 stablecoinWithdrawn,
        address recipient
    );

    constructor(
        IStock _stockToken,
        IERC20 _stablecoinToken,
        IPriceOracle _oracle,
        bytes32 _stockPriceFeedId,
        uint256 _feeCurveA,
        uint256 _feeCurveB,
        uint256 _protocolFeeRate,
        address _admin
    )
        ERC20(
            string.concat(_stockToken.symbol(), "-LP"),
            string.concat(_stockToken.symbol(), "-LP")
        )
    {
        if (address(_oracle) == address(0)) revert DclexPool__ZeroAddress();
        if (_admin == address(0)) revert DclexPool__ZeroAddress();
        if (address(_stablecoinToken) == address(0)) revert DclexPool__ZeroAddress();
        // Pool math hard-codes *1e12 scaling between 18-dec stock and 6-dec stablecoin.
        if (
            IERC20Metadata(address(_stablecoinToken)).decimals() !=
            STABLECOIN_DECIMALS
        ) {
            revert DclexPool__InvalidStablecoinDecimals();
        }
        if (_feeCurveA > MAX_FEE_RATE || _feeCurveB > MAX_FEE_RATE) {
            revert DclexPool__FeeCurveOutOfBounds();
        }
        if (_protocolFeeRate > MAX_PROTOCOL_FEE_RATE) {
            revert DclexPool__ProtocolFeeRateTooHigh();
        }
        stockToken = _stockToken;
        stablecoinToken = _stablecoinToken;
        oracle = _oracle;
        stockPriceFeedId = _stockPriceFeedId;
        feeCurveA = _feeCurveA;
        feeCurveB = _feeCurveB;
        protocolFeeRate = _protocolFeeRate;
        emit ProtocolFeeRateChanged(_protocolFeeRate);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /// @notice Returns the current fee curve parameters
    function getFeeCurve() external view returns (uint256 a, uint256 b) {
        return (feeCurveA, feeCurveB);
    }

    function updatePriceFeeds(bytes[] memory priceUpdateData) public payable {
        uint256 balanceBefore = address(this).balance - msg.value;
        if (priceUpdateData.length > 0) {
            uint256 fee = oracle.getUpdateFee(priceUpdateData);
            oracle.updatePriceFeeds{value: fee}(priceUpdateData);
        }
        uint256 refund = address(this).balance - balanceBefore;
        if (refund > 0) {
            (bool success, ) = msg.sender.call{value: refund}(new bytes(0));
            if (!success) revert DclexPool__NativeTransferFailed();
        }
    }

    function initialize(
        uint256 stockAmount,
        uint256 stablecoinAmount,
        bytes[] memory priceUpdateData
    ) public payable nonReentrant {
        if (initialized) {
            revert DclexPool__AlreadyInitialized();
        }
        if (stockAmount == 0 || stablecoinAmount == 0) {
            revert DclexPool__ZeroLiquidityDeposit();
        }
        updatePriceFeeds(priceUpdateData);
        uint256 stockReserveValue = Math.mulDiv(
            stockAmount, getStockTokenPrice(), 1e18, Math.Rounding.Ceil
        );
        uint256 stablecoinReserveValue = stablecoinAmount * 1e12;
        uint256 liquidityAmount = (stockReserveValue + stablecoinReserveValue);
        initialized = true;
        stockToken.safeTransferFrom(msg.sender, address(this), stockAmount);
        stablecoinToken.safeTransferFrom(msg.sender, address(this), stablecoinAmount);
        _mint(msg.sender, liquidityAmount);
        emit LiquidityAdded(liquidityAmount, stockAmount, stablecoinAmount);
    }

    function addLiquidity(
        uint256 liquidityAmount
    ) public nonReentrant {
        if (!initialized) {
            revert DclexPool__NotInitialized();
        }
        uint256 supply = totalSupply();
        // Defensive: removeLiquidity resets `initialized = false` when the
        // last LP exits, so reaching this branch is not expected. Kept as
        // a safety net against future code paths that bypass that reset.
        if (supply == 0) {
            revert DclexPool__NotInitialized();
        }
        (uint256 stockReserve, uint256 stablecoinReserve) = _getReserves();
        uint256 stocksTaken = Math.mulDiv(
        liquidityAmount, stockReserve, supply, Math.Rounding.Ceil
        );
        uint256 stablecoinsTaken18 = Math.mulDiv(
        liquidityAmount, stablecoinReserve, supply, Math.Rounding.Ceil
        );
        uint256 stablecoinsTaken6 = Math.ceilDiv(stablecoinsTaken18, 1e12);
        if (stocksTaken == 0 || stablecoinsTaken6 == 0) {
            revert DclexPool__ZeroLiquidityDeposit();
        }
        stockToken.safeTransferFrom(msg.sender, address(this), stocksTaken);
        stablecoinToken.safeTransferFrom(msg.sender, address(this), stablecoinsTaken6);
        _mint(msg.sender, liquidityAmount);
        emit LiquidityAdded(liquidityAmount, stocksTaken, stablecoinsTaken6);
    }

    function removeLiquidity(
        uint256 liquidityAmount
    ) public nonReentrant {
        if (!initialized) revert DclexPool__NotInitialized();
        uint256 supply = totalSupply();
        if (supply == 0) revert DclexPool__NotInitialized();
        (uint256 stockReserve, uint256 stablecoinReserve) = _getReserves();
        uint256 stocksToSend = Math.mulDiv(liquidityAmount, stockReserve, supply);
        uint256 stablecoinToSend = Math.mulDiv(liquidityAmount, stablecoinReserve, supply);
        _burn(msg.sender, liquidityAmount);
        stockToken.safeTransfer(msg.sender, stocksToSend);
        stablecoinToken.safeTransfer(msg.sender, stablecoinToSend / 1e12);
        emit LiquidityRemoved(liquidityAmount, stocksToSend, stablecoinToSend / 1e12);
        // Last LP exited — re-open the pool for a fresh initialize() instead
        // of bricking it forever (dclex-infrastructure#336). Protocol fees
        // stay accounted in collectedProtocolFees* and survive across re-init.
        if (totalSupply() == 0) {
            initialized = false;
        }
    }

    function swapExactInput(
        bool stablecoinInput,
        uint256 exactInputAmount,
        address recipient,
        bytes memory callbackData,
        bytes[] memory priceUpdateData
    ) external payable nonReentrant returns (uint256) {
        if (!initialized) revert DclexPool__NotInitialized();
        updatePriceFeeds(priceUpdateData);
        exactInputAmount *= (stablecoinInput ? 1e12 : 1);
        address inputToken = stablecoinInput
            ? address(stablecoinToken)
            : address(stockToken);
        address outputToken = stablecoinInput
            ? address(stockToken)
            : address(stablecoinToken);
        uint256 stockTokenPrice = getStockTokenPrice();
        uint256 stablecoinTokenPrice = 1e18;
        uint256 netOutputTokenAmount;
        {
            uint256 outputTokenPrice = stablecoinInput
                ? stockTokenPrice
                : stablecoinTokenPrice;
            uint256 inputTokenPrice = stablecoinInput
                ? stablecoinTokenPrice
                : stockTokenPrice;
            uint256 grossOutputTokenAmount = Math.mulDiv(
                exactInputAmount, inputTokenPrice, outputTokenPrice
            );
            uint256 feeRate = stablecoinInput
                ? getBuyFeeRate(grossOutputTokenAmount, stockTokenPrice)
                : getSellFeeRate(exactInputAmount, stockTokenPrice);

            netOutputTokenAmount = Math.mulDiv(
                grossOutputTokenAmount, 1e18 - feeRate, 1e18
            );
            if (stablecoinInput) {
                collectedProtocolFeesStock += Math.mulDiv(
                    grossOutputTokenAmount - netOutputTokenAmount, protocolFeeRate, 1e18
                );
            } else {
                collectedProtocolFeesStablecoin += Math.mulDiv(
                    grossOutputTokenAmount - netOutputTokenAmount, protocolFeeRate, 1e18
                );
            }
        }

        if (stablecoinInput) {
            exactInputAmount /= 1e12;
        } else {
            netOutputTokenAmount /= 1e12;
        }

        if (netOutputTokenAmount == 0) {
            revert DclexPool__ZeroOutputAmount();
        }

        IERC20(outputToken).safeTransfer(recipient, netOutputTokenAmount);
        {
            uint256 inputBalanceBefore = IERC20(inputToken).balanceOf(
                address(this)
            );
            IDclexSwapCallback(msg.sender).dclexSwapCallback(
                inputToken,
                exactInputAmount,
                callbackData
            );
            uint256 inputBalanceAfter = IERC20(inputToken).balanceOf(
                address(this)
            );
            if (inputBalanceBefore + exactInputAmount > inputBalanceAfter) {
                revert DclexPool__InsufficientInputAmount();
            }
        }
        emit SwapExecuted(
            stablecoinInput,
            exactInputAmount,
            netOutputTokenAmount,
            stockTokenPrice,
            stablecoinTokenPrice,
            recipient
        );
        return netOutputTokenAmount;
    }

    function swapExactOutput(
        bool stablecoinInput,
        uint256 exactOutputAmount,
        address recipient,
        bytes memory callbackData,
        bytes[] memory priceUpdateData
    ) external payable nonReentrant returns (uint256) {
        if (!initialized) revert DclexPool__NotInitialized();
        updatePriceFeeds(priceUpdateData);
        exactOutputAmount *= (stablecoinInput ? 1 : 1e12);
        address inputToken = stablecoinInput
            ? address(stablecoinToken)
            : address(stockToken);
        address outputToken = stablecoinInput
            ? address(stockToken)
            : address(stablecoinToken);
        uint256 stockTokenPrice = getStockTokenPrice();
        uint256 stablecoinTokenPrice = 1e18;
        uint256 grossInputTokenAmount;
        {
            uint256 outputTokenPrice = stablecoinInput
                ? stockTokenPrice
                : stablecoinTokenPrice;
            uint256 inputTokenPrice = stablecoinInput
                ? stablecoinTokenPrice
                : stockTokenPrice;
            uint256 netInputTokenAmount = Math.mulDiv(
                exactOutputAmount, outputTokenPrice, inputTokenPrice, Math.Rounding.Ceil
            );
            uint256 feeRate = stablecoinInput
                ? getBuyFeeRate(exactOutputAmount, stockTokenPrice)
                : getSellFeeRate(netInputTokenAmount, stockTokenPrice);
            grossInputTokenAmount = Math.mulDiv(
                netInputTokenAmount, 1e18 + feeRate, 1e18, Math.Rounding.Ceil
            );
            if (stablecoinInput) {
                collectedProtocolFeesStablecoin += Math.mulDiv(
                    grossInputTokenAmount - netInputTokenAmount, protocolFeeRate, 1e18
                );
            } else {
                collectedProtocolFeesStock += Math.mulDiv(
                    grossInputTokenAmount - netInputTokenAmount, protocolFeeRate, 1e18
                );
            }
        }

        if (stablecoinInput) {
            grossInputTokenAmount = Math.ceilDiv(grossInputTokenAmount, 1e12);
        } else {
            exactOutputAmount /= 1e12;
        }

        if (grossInputTokenAmount == 0) {
            revert DclexPool__ZeroOutputAmount();
        }

        IERC20(outputToken).safeTransfer(recipient, exactOutputAmount);
        {
            uint256 inputBalanceBefore = IERC20(inputToken).balanceOf(
                address(this)
            );
            IDclexSwapCallback(msg.sender).dclexSwapCallback(
                inputToken,
                grossInputTokenAmount,
                callbackData
            );
            uint256 inputBalanceAfter = IERC20(inputToken).balanceOf(
                address(this)
            );
            if (
                inputBalanceBefore + grossInputTokenAmount > inputBalanceAfter
            ) {
                revert DclexPool__InsufficientInputAmount();
            }
        }
        emit SwapExecuted(
            stablecoinInput,
            grossInputTokenAmount,
            exactOutputAmount,
            stockTokenPrice,
            stablecoinTokenPrice,
            recipient
        );
        return grossInputTokenAmount;
    }

    function getStockTokenPrice() private view returns (uint256 price) {
        uint256 stockSharePrice = getStockPrice(stockPriceFeedId);
        (uint256 numerator, uint256 denominator) = stockToken.multiplier();
        return Math.mulDiv(stockSharePrice, numerator, denominator);
    }

    function getStockPrice(
        bytes32 priceFeedId
    ) private view returns (uint256) {
        IPriceOracle.Price memory p = oracle.getPriceNoOlderThan(
            priceFeedId,
            MAX_PRICE_STALENESS
        );
        return _convertToUint(p.price, p.expo, DECIMALS);
    }

    function _convertToUint(
        int64 price,
        int32 expo,
        uint8 targetDecimals
    ) private pure returns (uint256) {
        if (price < 0 || expo > 0 || expo < -255) {
            revert DclexPool__InvalidPriceOrExponent();
        }
        uint8 priceDecimals = uint8(uint32(-1 * expo));
        if (targetDecimals >= priceDecimals) {
            return
                uint256(uint64(price)) *
                10 ** uint32(targetDecimals - priceDecimals);
        } else {
            return
                uint256(uint64(price)) /
                10 ** uint32(priceDecimals - targetDecimals);
        }
    }

    function getBuyFeeRate(
        uint256 stockOutputAmount,
        uint256 stockPrice
    ) private view returns (uint256) {
        (
            uint256 stocksRatioBefore,
            uint256 totalValue
        ) = getStocksRatioTotalValue(stockPrice);
        uint256 stocksRatioDelta = Math.mulDiv(stockOutputAmount, stockPrice, totalValue);
        if (stocksRatioDelta >= stocksRatioBefore) {
            revert DclexPool__NotEnoughPoolLiquidity();
        }
        uint256 stocksRatioAfter = stocksRatioBefore - stocksRatioDelta;
        uint256 ratiosProduct = Math.mulDiv(stocksRatioBefore, stocksRatioAfter, 1e18);
        // `ratiosProduct` floor-rounds to zero when both ratios are
        // extremely small (e.g. pool holds 1 wei of stock vs huge
        // stablecoin reserve). Clamp to 1 — the resulting inverse is
        // huge, then `rate` is bounded by MAX_FEE_RATE below.
        if (ratiosProduct == 0) ratiosProduct = 1;
        uint256 inverseRatiosProduct = 1e36 / ratiosProduct;
        uint256 rate = feeCurveB + Math.mulDiv(feeCurveA, inverseRatiosProduct, 1e18);
        return rate > MAX_FEE_RATE ? MAX_FEE_RATE : rate;
    }

    function getSellFeeRate(
        uint256 stockInputAmount,
        uint256 stockPrice
    ) private view returns (uint256) {
        (
            uint256 stocksRatioBefore,
            uint256 totalValue
        ) = getStocksRatioTotalValue(stockPrice);
        uint256 stocksRatioAfter = stocksRatioBefore +
            Math.mulDiv(stockInputAmount, stockPrice, totalValue);
        if (stocksRatioAfter >= 1e18) {
            revert DclexPool__NotEnoughPoolLiquidity();
        }
        uint256 ratiosProduct = Math.mulDiv(stocksRatioBefore, stocksRatioAfter, 1e18);
        uint256 denom = 1e18 + ratiosProduct - stocksRatioBefore - stocksRatioAfter;
        // Integer-floor of `ratiosProduct` can leave the algebraic
        // denominator at 0 when both ratios approach 1e18 (pool nearly
        // 100% stock). Clamp to 1 — the inverse is huge, then `rate` is
        // capped at MAX_FEE_RATE below.
        if (denom == 0) denom = 1;
        uint256 inverseRatiosProduct = 1e36 / denom;
        uint256 rate = feeCurveB + Math.mulDiv(feeCurveA, inverseRatiosProduct, 1e18);
        return rate > MAX_FEE_RATE ? MAX_FEE_RATE : rate;
    }

    function getStocksRatioTotalValue(
        uint256 stockPrice
    ) private view returns (uint256, uint256) {
        (uint256 stockReserve, uint256 stablecoinReserve) = _getReserves();
        uint256 stocksValue = Math.mulDiv(stockReserve, stockPrice, 1e18);
        uint256 totalValue = stocksValue + stablecoinReserve;
        uint256 stocksRatio = Math.mulDiv(1e18, stocksValue, totalValue);
        return (stocksRatio, totalValue);
    }

    function setProtocolFeeRate(
        uint256 _protocolFeeRate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_protocolFeeRate > MAX_PROTOCOL_FEE_RATE) {
            revert DclexPool__ProtocolFeeRateTooHigh();
        }
        protocolFeeRate = _protocolFeeRate;
        emit ProtocolFeeRateChanged(_protocolFeeRate);
    }

    function getProtocolFeeRate() external view returns (uint256) {
        return protocolFeeRate;
    }

    function collectedProtocolFees() external view returns (uint256, uint256) {
        return (collectedProtocolFeesStock, collectedProtocolFeesStablecoin);
    }

    function withdrawCollectedProtocolFees(
        address receiver
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        stockToken.safeTransfer(receiver, collectedProtocolFeesStock);
        stablecoinToken.safeTransfer(receiver, collectedProtocolFeesStablecoin / 1e12);
        emit ProtocolFeeWithdrawn(
            collectedProtocolFeesStock,
            collectedProtocolFeesStablecoin / 1e12,
            receiver
        );
        collectedProtocolFeesStock = 0;
        collectedProtocolFeesStablecoin = 0;
    }

    function token0() external view returns (address) {
        return address(stockToken);
    }

    function token1() external view returns (address) {
        return address(stablecoinToken);
    }

    /// @notice Returns the pool's LP-backing reserves, with accumulated protocol
    ///         fees subtracted. Off-chain LP pricing must use these values, not
    ///         `token.balanceOf(pool)` directly — the raw balances include
    ///         protocol fees that belong to the protocol, not to LPs.
    /// @return stockReserve Raw stock-token amount (post-fee). In the stock
    ///         token's native unit (pre-multiplier shares); apply
    ///         `stockToken.multiplier()` off-chain when displaying values that
    ///         use a post-multiplier "token price" convention.
    /// @return stablecoinReserve Stablecoin amount scaled to 1e18 (post-fee).
    ///         Divide by 1e12 to convert back to the underlying 6-decimal dUSD
    ///         unit.
    function getReserves() external view returns (uint256 stockReserve, uint256 stablecoinReserve) {
        return _getReserves();
    }

    /// @notice Maximum age (seconds) of a signed price feed update before
    ///         this pool rejects the swap with `StalePrice()`. Hard-coded
    ///         constant — no setter, no per-deploy knob.
    /// @dev Exposed so the DEX frontend can cap the user-chosen swap
    ///      deadline at this value — a deadline longer than
    ///      `MAX_PRICE_STALENESS` is a UX lie because the signed price will
    ///      expire before the deadline does.
    function getMaxPriceStaleness() external pure returns (uint256) {
        return MAX_PRICE_STALENESS;
    }

    function _getReserves() private view returns (uint256, uint256) {
        uint256 stockReserve = stockToken.balanceOf(address(this)) -
            collectedProtocolFeesStock;
        uint256 stablecoinReserve = stablecoinToken.balanceOf(address(this)) *
            1e12 -
            collectedProtocolFeesStablecoin;
        return (stockReserve, stablecoinReserve);
    }

    function transfer(
        address to,
        uint256 amount
    ) public override nonReentrant returns (bool) {
        if (!stockToken.DID().verifyTransfer(msg.sender, to)) {
            revert InvalidDID();
        }
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override nonReentrant returns (bool) {
        if (!stockToken.DID().verifyTransfer(from, to)) {
            revert InvalidDID();
        }
        return super.transferFrom(from, to, amount);
    }
}
