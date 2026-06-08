// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPriceOracle} from "../src/IPriceOracle.sol";
import {FIOracle} from "../src/FIOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {USDCMock} from "../test/USDCMock.sol";
import {MockPriceOracle} from "../test/MockPriceOracle.sol";

contract HelperConfig is Script {
    error HelperConfig__InvalidChainId();

    struct NetworkConfig {
        address admin;
        IERC20 dusdToken;
        IPriceOracle oracle;
    }

    uint256 public constant LOCAL_CHAIN_ID = 31337;
    uint256 public constant PRIMEDELTA_DEV_CHAIN_ID = 2028;
    uint256 public constant PRIMEDELTA_TESTNET_CHAIN_ID = 7357;

    NetworkConfig public localNetworkConfig;
    NetworkConfig public primedeltaDevNetworkConfig;
    NetworkConfig public primedeltaTestnetNetworkConfig;

    function getConfig() public returns (NetworkConfig memory) {
        if (block.chainid == LOCAL_CHAIN_ID) {
            return getLocalConfig();
        } else if (block.chainid == PRIMEDELTA_DEV_CHAIN_ID) {
            return getPrimedeltaDevConfig();
        } else if (block.chainid == PRIMEDELTA_TESTNET_CHAIN_ID) {
            return getPrimedeltaTestnetConfig();
        } else {
            revert HelperConfig__InvalidChainId();
        }
    }

    function getLocalConfig() public returns (NetworkConfig memory) {
        if (address(localNetworkConfig.oracle) != address(0)) {
            return localNetworkConfig;
        }
        vm.startBroadcast();
        MockPriceOracle oracle = new MockPriceOracle();
        // USDCMock is a generic 6-decimal ERC20 fixture; we instantiate
        // it as the dUSD stand-in for local hardhat runs.
        IERC20 dusdToken = new USDCMock("dUSD", "Dclex USD");
        vm.stopBroadcast();
        localNetworkConfig = NetworkConfig({
            admin: makeAddr("pool_admin"),
            dusdToken: dusdToken,
            oracle: IPriceOracle(address(oracle))
        });
        return localNetworkConfig;
    }

    function getPrimedeltaDevConfig() public returns (NetworkConfig memory) {
        if (address(primedeltaDevNetworkConfig.oracle) != address(0)) {
            return primedeltaDevNetworkConfig;
        }
        // All operationally-rotated values come from env: the dUSD address
        // changes on every chain reset, the backend signer rotated to KMS
        // on 2026-05-15, and the admin address has always lived in .env.
        // Previous hardcoded values went stale silently and would brick a
        // redeploy without anyone noticing until the first swap reverted.
        address admin = vm.envAddress("ADMIN_PUBLIC");
        address backendSigner = vm.envAddress("BACKEND_SIGNER_ADDRESS");
        address dusdTokenAddress = vm.envAddress("DUSD_ADDRESS");
        vm.startBroadcast(vm.envUint("ADMIN_PRIVATE_KEY"));
        FIOracle fiOracle = new FIOracle(backendSigner, admin);
        fiOracle.setPricePerUpdate(0.001 ether);
        vm.stopBroadcast();
        primedeltaDevNetworkConfig = NetworkConfig({
            admin: admin,
            dusdToken: IERC20(dusdTokenAddress),
            oracle: IPriceOracle(address(fiOracle))
        });
        return primedeltaDevNetworkConfig;
    }

    function getPrimedeltaTestnetConfig()
        public
        returns (NetworkConfig memory)
    {
        if (address(primedeltaTestnetNetworkConfig.oracle) != address(0)) {
            return primedeltaTestnetNetworkConfig;
        }
        // Mirror getPrimedeltaDevConfig: deploy FIOracle inline so a fresh
        // chain reset doesn't require pre-deploying the oracle separately.
        // Broadcast as ADMIN because FIOracle.setPricePerUpdate requires
        // DEFAULT_ADMIN_ROLE which is held by ADMIN (not MASTER).
        address admin = vm.envAddress("ADMIN_PUBLIC");
        address backendSigner = vm.envAddress("BACKEND_SIGNER_ADDRESS");
        address dusdTokenAddress = vm.envAddress("DUSD_ADDRESS");
        vm.startBroadcast(vm.envUint("ADMIN_PRIVATE_KEY"));
        FIOracle fiOracle = new FIOracle(backendSigner, admin);
        fiOracle.setPricePerUpdate(0.001 ether);
        vm.stopBroadcast();
        primedeltaTestnetNetworkConfig = NetworkConfig({
            admin: admin,
            dusdToken: IERC20(dusdTokenAddress),
            oracle: IPriceOracle(address(fiOracle))
        });
        return primedeltaTestnetNetworkConfig;
    }

    /// @notice Deterministic test feed ID derived from symbol.
    ///         Tests deploy fresh pools/oracles wired to the same algorithm,
    ///         so the actual bytes don't need to match any external feed.
    function getPriceFeedId(
        string memory symbol
    ) public pure returns (bytes32) {
        return keccak256(bytes(symbol));
    }
}
