// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPriceOracle} from "./IPriceOracle.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract FIOracle is IPriceOracle, AccessControl {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    error InvalidSignature();
    error InvalidUpdateData();
    error FuturePublishTime();
    error InsufficientFee();
    error FeeTransferFailed();
    error InvalidFeeRecipient();

    address public trustedSigner;
    uint256 public pricePerUpdate;
    address public feeRecipient;
    mapping(bytes32 => Price) private priceFeeds;

    event TrustedSignerUpdated(address newSigner);
    event PricePerUpdateChanged(uint256 pricePerUpdate);
    event FeeRecipientChanged(address feeRecipient);

    constructor(address _trustedSigner, address admin) {
        trustedSigner = _trustedSigner;
        feeRecipient = admin;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setTrustedSigner(
        address _trustedSigner
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        trustedSigner = _trustedSigner;
        emit TrustedSignerUpdated(_trustedSigner);
    }

    function setPricePerUpdate(
        uint256 _pricePerUpdate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        pricePerUpdate = _pricePerUpdate;
        emit PricePerUpdateChanged(_pricePerUpdate);
    }

    function setFeeRecipient(
        address _feeRecipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_feeRecipient == address(0)) revert InvalidFeeRecipient();
        feeRecipient = _feeRecipient;
        emit FeeRecipientChanged(_feeRecipient);
    }

    /// @notice Updates price feeds with signed data from the trusted signer.
    /// @param updateData Each element: abi.encodePacked(feedId, price, expo, publishTime, v, r, s)
    ///        feedId: bytes32 (32 bytes)
    ///        price: int64 (8 bytes)
    ///        expo: int32 (4 bytes)
    ///        publishTime: uint64 (8 bytes)
    ///        v: uint8 (1 byte)
    ///        r: bytes32 (32 bytes)
    ///        s: bytes32 (32 bytes)
    ///        Total: 117 bytes
    function updatePriceFeeds(
        bytes[] calldata updateData
    ) external payable override {
        uint256 fee = pricePerUpdate;
        if (msg.value < fee) {
            revert InsufficientFee();
        }
        for (uint256 i = 0; i < updateData.length; ++i) {
            _updateSingleFeed(updateData[i]);
        }
        if (fee > 0) {
            (bool sent, ) = feeRecipient.call{value: fee}("");
            if (!sent) revert FeeTransferFailed();
        }
        uint256 refund = msg.value - fee;
        if (refund > 0) {
            (bool refunded, ) = msg.sender.call{value: refund}("");
            if (!refunded) revert FeeTransferFailed();
        }
    }

    function getPriceNoOlderThan(
        bytes32 id,
        uint256 age
    ) external view override returns (Price memory) {
        Price memory p = priceFeeds[id];
        if (p.publishTime == 0) {
            revert PriceFeedNotFound();
        }
        if (block.timestamp - p.publishTime > age) {
            revert StalePrice();
        }
        return p;
    }

    function getUpdateFee(
        bytes[] calldata
    ) external view override returns (uint256) {
        return pricePerUpdate;
    }

    function _updateSingleFeed(bytes calldata data) private {
        if (data.length != 117) {
            revert InvalidUpdateData();
        }

        bytes32 feedId = bytes32(data[0:32]);
        int64 price = int64(uint64(bytes8(data[32:40])));
        int32 expo = int32(uint32(bytes4(data[40:44])));
        uint64 publishTime = uint64(bytes8(data[44:52]));

        if (publishTime > block.timestamp) {
            revert FuturePublishTime();
        }

        if (publishTime <= priceFeeds[feedId].publishTime) {
            return;
        }

        bytes32 messageHash = keccak256(
            abi.encodePacked(feedId, price, expo, publishTime)
        );
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();

        uint8 v = uint8(data[52]);
        bytes32 r = bytes32(data[53:85]);
        bytes32 s = bytes32(data[85:117]);

        address recovered = ethSignedHash.recover(v, r, s);
        if (recovered != trustedSigner) {
            revert InvalidSignature();
        }

        priceFeeds[feedId] = Price(price, expo, publishTime);
    }
}
