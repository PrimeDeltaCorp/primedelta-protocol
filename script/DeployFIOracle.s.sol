// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {FIOracle} from "../src/FIOracle.sol";

/// @notice Deploys FIOracle with a trusted signer and admin.
///         Usage: FOUNDRY_PROFILE=default forge script script/DeployFIOracle.s.sol --broadcast
contract DeployFIOracle is Script {
    uint256 public constant INITIAL_UPDATE_FEE = 0.001 ether;

    function run(
        address trustedSigner,
        address admin
    ) external returns (FIOracle) {
        vm.startBroadcast();
        FIOracle oracle = new FIOracle(trustedSigner, admin);
        oracle.setPricePerUpdate(INITIAL_UPDATE_FEE);
        vm.stopBroadcast();
        console.log("FIOracle deployed at:", address(oracle));
        console.log("Update fee set to (wei):", INITIAL_UPDATE_FEE);
        return oracle;
    }
}
