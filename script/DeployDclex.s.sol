// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {Stock} from "dclex-blockchain/contracts/dclex/Stock.sol";
import {USDCMock} from "dclex-blockchain/contracts/mocks/USDCMock.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {TokenBuilder} from "dclex-blockchain/contracts/dclex/TokenBuilder.sol";
import {
    DigitalIdentity
} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {
    SignatureUtils
} from "dclex-blockchain/contracts/dclex/SignatureUtils.sol";
import {Vault} from "dclex-blockchain/contracts/dclex/Vault.sol";
import {Security} from "dclex-blockchain/contracts/dclex/Security.sol";
import {MASTER_ADMIN_ROLE} from "dclex-blockchain/contracts/libs/Model.sol";

contract DeployDclex is Script {
    struct DclexContracts {
        SignatureUtils signatureUtils;
        Factory stocksFactory;
        DigitalIdentity digitalIdentity;
        Vault vault;
        TokenBuilder tokenBuilder;
        USDCMock dusdMock;
    }

    USDCMock internal dusdMock;
    SignatureUtils internal signatureUtils;
    Factory internal stocksFactory;
    DigitalIdentity internal digitalIdentity;
    Vault internal vault;
    TokenBuilder internal tokenBuilder;

    function run(
        address standardAdmin,
        address masterAdmin
    ) external returns (DclexContracts memory) {
        vm.startBroadcast();
        // USDCMock is a generic 6-dec ERC20 fixture from dclex-blockchain;
        // we instantiate it as the dUSD stand-in for local hardhat runs.
        dusdMock = new USDCMock("dUSD", "dUSD");
        signatureUtils = new SignatureUtils();
        stocksFactory = new Factory(address(signatureUtils));
        digitalIdentity = new DigitalIdentity(
            "DCLEX Digital Identity",
            "DCLEX:DID",
            address(signatureUtils)
        );
        vault = new Vault(address(dusdMock), address(signatureUtils));
        tokenBuilder = new TokenBuilder(address(stocksFactory));

        stocksFactory.setTokenBuilder(address(tokenBuilder));
        stocksFactory.setDID(address(digitalIdentity));

        Security[3] memory securityContracts = [
            Security(stocksFactory),
            Security(digitalIdentity),
            Security(vault)
        ];
        for (uint256 i = 0; i < securityContracts.length; ++i) {
            Security securityContract = securityContracts[i];
            securityContract.grantRole(
                securityContract.DEFAULT_ADMIN_ROLE(),
                standardAdmin
            );
            securityContract.grantRole(MASTER_ADMIN_ROLE, masterAdmin);
            securityContract.revokeRole(
                securityContract.DEFAULT_ADMIN_ROLE(),
                address(this)
            );
            securityContract.revokeRole(MASTER_ADMIN_ROLE, address(this));
        }
        vm.stopBroadcast();
        return
            DclexContracts({
                signatureUtils: signatureUtils,
                stocksFactory: stocksFactory,
                digitalIdentity: digitalIdentity,
                vault: vault,
                tokenBuilder: tokenBuilder,
                dusdMock: dusdMock
            });
    }
}
