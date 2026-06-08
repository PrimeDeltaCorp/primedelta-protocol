// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {DclexPool} from "../src/DclexPool.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployDclexPool is Script {
    // 15% protocol cut on swap fees — chain-wide default, baked into
    // every pool at deploy so the cast-by-cast post-deploy
    // setProtocolFeeRate dance can't be skipped (dclex-infrastructure#256).
    uint256 public constant DEFAULT_PROTOCOL_FEE_RATE = 0.15 ether;

    function run(
        IStock stockToken,
        HelperConfig helperConfig,
        uint256 feeCurveA,
        uint256 feeCurveB,
        uint256 protocolFeeRate
    ) external returns (DclexPool) {
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        string memory stockSymbol = stockToken.symbol();
        bytes32 stockPriceFeedId = helperConfig.getPriceFeedId(stockSymbol);
        vm.startBroadcast();
        DclexPool dclexPool = new DclexPool(
            stockToken,
            config.dusdToken,
            config.oracle,
            stockPriceFeedId,
            feeCurveA,
            feeCurveB,
            protocolFeeRate,
            config.admin
        );
        vm.stopBroadcast();
        return dclexPool;
    }

    /// @notice Deploy pool without broadcast - caller manages broadcast
    function deploy(
        IStock stockToken,
        HelperConfig helperConfig,
        uint256 feeCurveA,
        uint256 feeCurveB,
        uint256 protocolFeeRate
    ) external returns (DclexPool) {
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        string memory stockSymbol = stockToken.symbol();
        bytes32 stockPriceFeedId = helperConfig.getPriceFeedId(stockSymbol);
        return new DclexPool(
            stockToken,
            config.dusdToken,
            config.oracle,
            stockPriceFeedId,
            feeCurveA,
            feeCurveB,
            protocolFeeRate,
            config.admin
        );
    }

    function run() external {
        address stock = (block.chainid == 11155111)
            ? 0x538d1094A35201D69e1Ac8c2dD42000C1CC0612E
            : 0x7fc1375aA5d360Ca90cc443B5c3d3919aA8B9208;
        this.run(
            IStock(address(stock)),
            new HelperConfig(),
            0,
            0,
            DEFAULT_PROTOCOL_FEE_RATE
        );
    }
}
