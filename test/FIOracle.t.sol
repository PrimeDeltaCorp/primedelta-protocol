// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {FIOracle} from "../src/FIOracle.sol";
import {IPriceOracle} from "../src/IPriceOracle.sol";

contract FIOracleTest is Test {
    FIOracle internal oracle;
    uint256 internal signerKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address internal signer;
    address internal admin = makeAddr("admin");
    bytes32 internal constant AAPL_FEED_ID = bytes32(uint256(1));

    function setUp() public {
        signer = vm.addr(signerKey);
        oracle = new FIOracle(signer, admin);
    }

    function _signPrice(
        bytes32 feedId,
        int64 price,
        int32 expo,
        uint64 publishTime
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(feedId, price, expo, publishTime)
        );
        bytes32 ethSignedHash = _toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, ethSignedHash);
        return abi.encodePacked(feedId, price, expo, publishTime, v, r, s);
    }

    function _toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    function _updatePrice(
        bytes32 feedId,
        int64 price,
        int32 expo,
        uint64 publishTime
    ) internal {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = _signPrice(feedId, price, expo, publishTime);
        oracle.updatePriceFeeds(updateData);
    }

    function testUpdateAndReadPrice() public {
        _updatePrice(AAPL_FEED_ID, 15230000000, -8, uint64(block.timestamp));

        IPriceOracle.Price memory p = oracle.getPriceNoOlderThan(AAPL_FEED_ID, 60);
        assertEq(p.price, 15230000000);
        assertEq(p.expo, -8);
        assertEq(p.publishTime, uint64(block.timestamp));
    }

    function testRejectsInvalidSignature() public {
        uint256 wrongKey = 0xdead;
        address wrongSigner = vm.addr(wrongKey);

        bytes32 messageHash = keccak256(
            abi.encodePacked(AAPL_FEED_ID, int64(100), int32(-8), uint64(block.timestamp))
        );
        bytes32 ethSignedHash = _toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, ethSignedHash);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = abi.encodePacked(AAPL_FEED_ID, int64(100), int32(-8), uint64(block.timestamp), v, r, s);

        vm.expectRevert(FIOracle.InvalidSignature.selector);
        oracle.updatePriceFeeds(updateData);
    }

    function testRejectsInvalidDataLength() public {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"deadbeef";

        vm.expectRevert(FIOracle.InvalidUpdateData.selector);
        oracle.updatePriceFeeds(updateData);
    }

    function testRejectsStalePriceRead() public {
        _updatePrice(AAPL_FEED_ID, 15230000000, -8, uint64(block.timestamp));

        skip(61);

        vm.expectRevert(IPriceOracle.StalePrice.selector);
        oracle.getPriceNoOlderThan(AAPL_FEED_ID, 60);
    }

    function testRejectsPriceFeedNotFound() public {
        vm.expectRevert(IPriceOracle.PriceFeedNotFound.selector);
        oracle.getPriceNoOlderThan(AAPL_FEED_ID, 60);
    }

    function testIgnoresOlderPublishTime() public {
        _updatePrice(AAPL_FEED_ID, 15230000000, -8, uint64(block.timestamp));

        // Try updating with older timestamp — should be silently ignored
        _updatePrice(AAPL_FEED_ID, 99999999, -8, uint64(block.timestamp - 1));

        IPriceOracle.Price memory p = oracle.getPriceNoOlderThan(AAPL_FEED_ID, 60);
        assertEq(p.price, 15230000000);
    }

    function testAcceptsNewerPublishTime() public {
        _updatePrice(AAPL_FEED_ID, 15230000000, -8, uint64(block.timestamp));

        skip(1);
        _updatePrice(AAPL_FEED_ID, 16000000000, -8, uint64(block.timestamp));

        IPriceOracle.Price memory p = oracle.getPriceNoOlderThan(AAPL_FEED_ID, 60);
        assertEq(p.price, 16000000000);
    }

    function testBatchUpdate() public {
        bytes32 nvdaFeedId = bytes32(uint256(2));

        bytes[] memory updateData = new bytes[](2);
        updateData[0] = _signPrice(AAPL_FEED_ID, 15230000000, -8, uint64(block.timestamp));
        updateData[1] = _signPrice(nvdaFeedId, 87500000000, -8, uint64(block.timestamp));

        oracle.updatePriceFeeds(updateData);

        IPriceOracle.Price memory aaplPrice = oracle.getPriceNoOlderThan(AAPL_FEED_ID, 60);
        IPriceOracle.Price memory nvdaPrice = oracle.getPriceNoOlderThan(nvdaFeedId, 60);
        assertEq(aaplPrice.price, 15230000000);
        assertEq(nvdaPrice.price, 87500000000);
    }

    function testGetUpdateFeeReturnsZeroByDefault() public view {
        bytes[] memory updateData = new bytes[](3);
        assertEq(oracle.getUpdateFee(updateData), 0);
    }

    function testGetUpdateFeeIsFlatPerCall() public {
        vm.prank(admin);
        oracle.setPricePerUpdate(1 gwei);

        bytes[] memory one = new bytes[](1);
        bytes[] memory three = new bytes[](3);
        assertEq(oracle.getUpdateFee(one), 1 gwei);
        assertEq(oracle.getUpdateFee(three), 1 gwei);
    }

    function testUpdateRevertsWhenValueBelowFee() public {
        vm.prank(admin);
        oracle.setPricePerUpdate(1 gwei);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = _signPrice(AAPL_FEED_ID, 1e10, -8, uint64(block.timestamp));

        vm.expectRevert(FIOracle.InsufficientFee.selector);
        oracle.updatePriceFeeds{value: 0.5 gwei}(updateData);
    }

    function testUpdateForwardsFeeToRecipientAndRefundsExcess() public {
        address payer = makeAddr("payer");
        address recipient = makeAddr("recipient");
        vm.startPrank(admin);
        oracle.setPricePerUpdate(1 gwei);
        oracle.setFeeRecipient(recipient);
        vm.stopPrank();

        bytes[] memory updateData = new bytes[](2);
        updateData[0] = _signPrice(AAPL_FEED_ID, 1e10, -8, uint64(block.timestamp));
        updateData[1] = _signPrice(bytes32(uint256(2)), 2e10, -8, uint64(block.timestamp));

        vm.deal(payer, 10 gwei);
        vm.prank(payer);
        oracle.updatePriceFeeds{value: 5 gwei}(updateData);

        assertEq(recipient.balance, 1 gwei);
        assertEq(payer.balance, 9 gwei); // flat fee per call: started with 10, paid 1 fee, sent 5, got 4 back
    }

    function testAdminCanChangePricePerUpdate() public {
        vm.prank(admin);
        oracle.setPricePerUpdate(42);
        assertEq(oracle.pricePerUpdate(), 42);
    }

    function testNonAdminCannotChangePricePerUpdate() public {
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert();
        oracle.setPricePerUpdate(42);
    }

    function testAdminCanChangeFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        vm.prank(admin);
        oracle.setFeeRecipient(newRecipient);
        assertEq(oracle.feeRecipient(), newRecipient);
    }

    function testNonAdminCannotChangeFeeRecipient() public {
        address nobody = makeAddr("nobody");
        address newRecipient = makeAddr("newRecipient");
        vm.prank(nobody);
        vm.expectRevert();
        oracle.setFeeRecipient(newRecipient);
    }

    function testSetFeeRecipientRejectsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(FIOracle.InvalidFeeRecipient.selector);
        oracle.setFeeRecipient(address(0));
    }

    function testAdminCanChangeSigner() public {
        address newSigner = makeAddr("newSigner");
        vm.prank(admin);
        oracle.setTrustedSigner(newSigner);
        assertEq(oracle.trustedSigner(), newSigner);
    }

    function testNonAdminCannotChangeSigner() public {
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert();
        oracle.setTrustedSigner(nobody);
    }
}
