// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

// PrimeDelta audit — Phase 2 PROPERTY-BASED FUZZING for FIOracle's 117-byte
// blob parser (`_updateSingleFeed`) and `updatePriceFeeds`.
//
// Reference catalog: audit-round2/testplan/02-fuzzing.md, Group E (FZ-ORA).
// Target: src/FIOracle.sol:74-157.
//
// This file pairs a STATELESS property-fuzz contract (blob-level properties)
// with a STATEFUL handler-based invariant (monotonicity across a fuzz sequence),
// mirroring the style of test/invariant/AuditInvariant_FIOracle.t.sol.
//
// Properties (all fuzzed, asserting the PROPERTY not a single example):
//   (1) FZ-ORA-01  length != 117            -> revert InvalidUpdateData
//   (2) FZ-ORA-02  domain-signed, fresh pt  -> ACCEPTED and stored verbatim
//   (3) FZ-ORA-04  pt > now + MAX_CLOCK_SKEW -> revert FuturePublishTime
//   (4) FZ-ORA-05  pt <= stored             -> silent no-op (no revert/downgrade)
//   (5) INV-MONO   stored publishTime never decreases across a fuzz sequence
//   (6) INV-TRUST  a blob from a NON-trusted key is rejected / never stored
//
// The domain preimage MUST match the contract exactly (F-001/F-028 fix):
//   keccak256(abi.encodePacked(chainid, address(oracle), feedId, price, expo,
//   publishTime))  ->  toEthSignedMessageHash (EIP-191).
//
// Run:
//   cd primedelta-protocol && FOUNDRY_EVM_VERSION=cancun \
//     forge test --match-path test/fuzz/Fuzz_FIOracleBlob.t.sol -vv

import {Test, console} from "forge-std/Test.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";
import {FIOracle} from "../../src/FIOracle.sol";
import {IPriceOracle} from "../../src/IPriceOracle.sol";

// secp256k1 group order: valid private keys live in [1, N-1].
uint256 constant SECP256K1_N =
    0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;

// =============================================================================
//                     STATELESS BLOB-LEVEL PROPERTY FUZZING
// =============================================================================
contract Fuzz_FIOracleBlob is Test {
    FIOracle internal oracle;
    // Anvil default key 0 — same trusted signer the committed suites use.
    uint256 internal constant SIGNER_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address internal signer;
    address internal admin = makeAddr("oracle_admin");

    function setUp() public {
        signer = vm.addr(SIGNER_KEY);
        oracle = new FIOracle(signer, admin);
        // Start the clock well above 0 so `now - X` bounds never underflow and
        // fresh feeds (publishTime 0) are unambiguously below any bounded pt.
        vm.warp(1_000_000);
    }

    // ---------------------------- helpers ----------------------------

    /// Build a 117-byte blob signed by `key` over the exact contract preimage.
    function _sign(
        uint256 key,
        bytes32 feedId,
        int64 price,
        int32 expo,
        uint64 publishTime
    ) internal view returns (bytes memory) {
        bytes32 h = keccak256(
            abi.encodePacked(
                block.chainid,
                address(oracle),
                feedId,
                price,
                expo,
                publishTime
            )
        );
        bytes32 eth = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", h)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, eth);
        return abi.encodePacked(feedId, price, expo, publishTime, v, r, s);
    }

    function _one(bytes memory blob) internal pure returns (bytes[] memory a) {
        a = new bytes[](1);
        a[0] = blob;
    }

    /// Stored publishTime for a feed, or 0 if never set (max age => never stale).
    function _stored(bytes32 feedId) internal view returns (uint64) {
        try oracle.getPriceNoOlderThan(feedId, type(uint256).max) returns (
            IPriceOracle.Price memory p
        ) {
            return p.publishTime;
        } catch {
            return 0;
        }
    }

    function _boundKey(uint256 k) internal pure returns (uint256) {
        return bound(k, 1, SECP256K1_N - 1);
    }

    // ======================================================================
    // (1) FZ-ORA-01 — length != 117 ALWAYS reverts InvalidUpdateData.
    // Fuzz arbitrary blob content of arbitrary length; the length check is the
    // very first thing `_updateSingleFeed` does, so content is irrelevant.
    // ======================================================================
    function testFuzz_malformedLengthReverts(bytes memory data) public {
        vm.assume(data.length != 117);
        vm.expectRevert(FIOracle.InvalidUpdateData.selector);
        oracle.updatePriceFeeds(_one(data));
    }

    /// Same property, but sweeping the length dimension densely (incl. the
    /// off-by-one neighborhood 116/118) with structured filler bytes so every
    /// length in [0,300]\{117} is exercised, not just the ones fuzzing samples.
    function testFuzz_everyLengthButExactReverts(
        uint16 len,
        bytes32 filler
    ) public {
        len = uint16(bound(len, 0, 300));
        vm.assume(len != 117);
        bytes memory data = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            data[i] = filler[i % 32];
        }
        vm.expectRevert(FIOracle.InvalidUpdateData.selector);
        oracle.updatePriceFeeds(_one(data));
    }

    // ======================================================================
    // (2) FZ-ORA-02/03 — a correctly domain-signed blob with publishTime in
    // (stored, now + MAX_CLOCK_SKEW] is ACCEPTED and each field is stored
    // VERBATIM, across the full int64 price / int32 expo ranges (incl. neg/0).
    // ======================================================================
    function testFuzz_validBlobStoredVerbatim(
        uint256 feedSeed,
        int64 price,
        int32 expo,
        uint64 publishTime
    ) public {
        bytes32 feedId = bytes32(feedSeed);
        // fresh feed => stored == 0; pt in [1, now+skew] is strictly > stored
        // and within the future window, so it MUST be accepted.
        publishTime = uint64(
            bound(publishTime, 1, block.timestamp + oracle.MAX_CLOCK_SKEW())
        );
        bytes memory blob = _sign(SIGNER_KEY, feedId, price, expo, publishTime);

        oracle.updatePriceFeeds(_one(blob));

        IPriceOracle.Price memory p = oracle.getPriceNoOlderThan(
            feedId,
            type(uint256).max
        );
        assertEq(p.price, price, "price not stored verbatim");
        assertEq(p.expo, expo, "expo not stored verbatim");
        assertEq(
            uint256(p.publishTime),
            uint256(publishTime),
            "publishTime not stored verbatim"
        );
    }

    // ======================================================================
    // (3) FZ-ORA-04 — publishTime > now + MAX_CLOCK_SKEW ALWAYS reverts
    // FuturePublishTime. The future check runs BEFORE the signature check, so
    // even a perfectly valid signature cannot save a too-far-future blob.
    // ======================================================================
    function testFuzz_futurePublishTimeReverts(
        uint256 feedSeed,
        int64 price,
        int32 expo,
        uint64 publishTime
    ) public {
        bytes32 feedId = bytes32(feedSeed);
        uint256 minFuture = block.timestamp + oracle.MAX_CLOCK_SKEW() + 1;
        publishTime = uint64(
            bound(uint256(publishTime), minFuture, type(uint64).max)
        );
        bytes memory blob = _sign(SIGNER_KEY, feedId, price, expo, publishTime);

        vm.expectRevert(FIOracle.FuturePublishTime.selector);
        oracle.updatePriceFeeds(_one(blob));
    }

    /// Boundary sweep: exactly now+skew is accepted, now+skew+1 reverts.
    function test_skewBoundaryExact() public {
        bytes32 feedId = bytes32(uint256(0xB0));
        uint64 atEdge = uint64(block.timestamp + oracle.MAX_CLOCK_SKEW());
        oracle.updatePriceFeeds(_one(_sign(SIGNER_KEY, feedId, 1e10, -8, atEdge)));
        assertEq(_stored(feedId), atEdge, "boundary pt should be accepted");

        uint64 beyond = atEdge + 1;
        vm.expectRevert(FIOracle.FuturePublishTime.selector);
        oracle.updatePriceFeeds(
            _one(_sign(SIGNER_KEY, bytes32(uint256(0xB1)), 1e10, -8, beyond))
        );
    }

    // ======================================================================
    // (4) FZ-ORA-05 — publishTime <= stored is a SILENT no-op: it does not
    // revert and it never downgrades the stored price/expo/publishTime.
    // ======================================================================
    function testFuzz_stalePublishTimeIsSilentNoOp(
        uint256 feedSeed,
        int64 basePrice,
        int64 stalePrice,
        int32 expo,
        uint64 baseTime,
        uint64 staleTime
    ) public {
        bytes32 feedId = bytes32(feedSeed);
        // Establish a baseline at baseTime in [2, now+skew].
        baseTime = uint64(
            bound(baseTime, 2, block.timestamp + oracle.MAX_CLOCK_SKEW())
        );
        oracle.updatePriceFeeds(
            _one(_sign(SIGNER_KEY, feedId, basePrice, expo, baseTime))
        );

        // A validly-signed but stale update (publishTime <= baseTime).
        uint64 stalePt = uint64(bound(staleTime, 0, baseTime));
        // must NOT revert
        oracle.updatePriceFeeds(
            _one(_sign(SIGNER_KEY, feedId, stalePrice, expo, stalePt))
        );

        // stored state is exactly the baseline — no downgrade, no regression.
        IPriceOracle.Price memory p = oracle.getPriceNoOlderThan(
            feedId,
            type(uint256).max
        );
        assertEq(p.price, basePrice, "stale update downgraded price");
        assertEq(p.expo, expo, "stale update mutated expo");
        assertEq(p.publishTime, baseTime, "stale update regressed publishTime");
    }

    /// Documents the early-return semantics: on the stale path the signature is
    /// NEVER recovered, so even a WRONG-KEY stale blob is a silent no-op (this is
    /// expected/by-design, not a forgery — nothing is written).
    function test_staleWrongSigIsSilentNoOp() public {
        bytes32 feedId = bytes32(uint256(7));
        uint64 t = uint64(block.timestamp);
        oracle.updatePriceFeeds(_one(_sign(SIGNER_KEY, feedId, 100, -8, t)));

        // stale (== t) blob signed by a NON-trusted key -> no revert, no write.
        bytes memory bad = _sign(0xBEEF, feedId, 999, -8, t);
        oracle.updatePriceFeeds(_one(bad));

        IPriceOracle.Price memory p = oracle.getPriceNoOlderThan(
            feedId,
            type(uint256).max
        );
        assertEq(p.price, 100, "wrong-sig stale blob mutated price");
        assertEq(p.publishTime, t, "wrong-sig stale blob mutated publishTime");
    }

    // ======================================================================
    // (6) INV-TRUST — a fresh (pt > stored) blob signed by a NON-trusted key is
    // rejected with InvalidSignature and NEVER stored.
    // ======================================================================
    function testFuzz_wrongKeyRejectedAndNotStored(
        uint256 feedSeed,
        uint256 wrongKey,
        int64 price,
        int32 expo,
        uint64 publishTime
    ) public {
        bytes32 feedId = bytes32(feedSeed);
        wrongKey = _boundKey(wrongKey);
        vm.assume(wrongKey != SIGNER_KEY);
        // fresh feed, pt in [1, now+skew] => strictly > stored(0) and in-window,
        // so the code reaches the signature check (not the future/stale gates).
        publishTime = uint64(
            bound(publishTime, 1, block.timestamp + oracle.MAX_CLOCK_SKEW())
        );
        bytes memory blob = _sign(wrongKey, feedId, price, expo, publishTime);

        vm.expectRevert(FIOracle.InvalidSignature.selector);
        oracle.updatePriceFeeds(_one(blob));

        // nothing was stored.
        assertEq(_stored(feedId), 0, "wrong-key blob was stored");
    }

    /// A fully random (v, r, s) over a fresh feed is NEVER accepted as a write.
    /// OZ ECDSA.recover may revert (high-s / bad v) or recover a junk address;
    /// either way the trusted signer is never matched, so nothing is stored.
    function testFuzz_randomSigNeverStored(
        uint256 feedSeed,
        int64 price,
        int32 expo,
        uint64 publishTime,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        bytes32 feedId = bytes32(feedSeed);
        publishTime = uint64(
            bound(publishTime, 1, block.timestamp + oracle.MAX_CLOCK_SKEW())
        );
        bytes memory blob = abi.encodePacked(
            feedId,
            price,
            expo,
            publishTime,
            v,
            r,
            s
        );
        try oracle.updatePriceFeeds(_one(blob)) {} catch {}

        // Fresh feed: if anything got stored, a forged signature was accepted.
        assertEq(
            _stored(feedId),
            0,
            "random-sig blob stored a price (forgery)"
        );
    }

    // ------------------------ deterministic proofs ------------------------

    /// A 117-byte blob PROCEEDS past the length check (contrast with (1)): a
    /// well-formed but wrong-signer blob reverts InvalidSignature, NOT
    /// InvalidUpdateData — proving the length gate is length-exact.
    function test_exactLengthProceedsPastLengthGate() public {
        bytes memory blob = _sign(0xBEEF, bytes32(uint256(9)), 5, -8, uint64(block.timestamp));
        assertEq(blob.length, 117, "blob must be 117 bytes");
        vm.expectRevert(FIOracle.InvalidSignature.selector);
        oracle.updatePriceFeeds(_one(blob));
    }
}

// =============================================================================
//                                  HANDLER
// =============================================================================
/// Bounded-action actor for the monotonicity/never-forged invariant campaign.
/// Submits a random mix of VALID (trusted-key) and WRONG-KEY updates and warps
/// the clock; ghost state mirrors the highest publishTime ever written per feed.
contract FIOracleMonoHandler is StdUtils {
    Vm internal constant vm =
        Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    FIOracle public oracle;
    uint256 internal signerKey;
    bytes32[3] public feeds;

    // highest publishTime ever successfully written per feed.
    mapping(bytes32 => uint64) public ghostMax;
    bool public ghostRegressed; // INV-MONO witness
    bool public ghostForged; // INV-TRUST witness

    uint256 public callCount;
    uint256 public ghostValidAccepted;
    uint256 public ghostWrongRejected;

    constructor(FIOracle _oracle, uint256 _signerKey) {
        oracle = _oracle;
        signerKey = _signerKey;
        feeds[0] = bytes32(uint256(1));
        feeds[1] = bytes32(uint256(2));
        feeds[2] = bytes32(uint256(3));
    }

    function _sign(
        uint256 key,
        bytes32 feedId,
        int64 price,
        int32 expo,
        uint64 publishTime
    ) internal view returns (bytes memory) {
        bytes32 h = keccak256(
            abi.encodePacked(
                block.chainid,
                address(oracle),
                feedId,
                price,
                expo,
                publishTime
            )
        );
        bytes32 eth = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", h)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, eth);
        return abi.encodePacked(feedId, price, expo, publishTime, v, r, s);
    }

    function _one(bytes memory blob) internal pure returns (bytes[] memory a) {
        a = new bytes[](1);
        a[0] = blob;
    }

    function _feed(uint256 sel) internal view returns (bytes32) {
        return feeds[sel % 3];
    }

    /// Stored publishTime for a feed, or 0 if never set (public: read by invariant).
    function stored(bytes32 feedId) public view returns (uint64) {
        try oracle.getPriceNoOlderThan(feedId, type(uint256).max) returns (
            IPriceOracle.Price memory p
        ) {
            return p.publishTime;
        } catch {
            return 0;
        }
    }

    // ----------------------------- actions -----------------------------

    /// Valid update by the trusted signer. pt bounded to [now-90, now+skew] so a
    /// meaningful fraction advances the feed while the rest exercises the no-op.
    function pushValid(uint256 feedSel, int64 price, uint64 publishTime) external {
        callCount++;
        bytes32 feedId = _feed(feedSel);
        publishTime = uint64(
            bound(
                publishTime,
                block.timestamp > 90 ? block.timestamp - 90 : 0,
                block.timestamp + oracle.MAX_CLOCK_SKEW()
            )
        );
        uint64 before = stored(feedId);
        try
            oracle.updatePriceFeeds(_one(_sign(signerKey, feedId, price, -8, publishTime)))
        {
            uint64 aft = stored(feedId);
            if (aft < before) ghostRegressed = true;
            if (publishTime > before) {
                if (aft != publishTime) ghostRegressed = true;
                ghostMax[feedId] = publishTime;
                ghostValidAccepted++;
            } else {
                if (aft != before) ghostRegressed = true;
            }
        } catch {}
    }

    /// Update signed by a NON-trusted key. Must never write; the only non-revert
    /// path is the stale early-return (pt <= stored), which writes nothing.
    function pushWrongKey(
        uint256 feedSel,
        uint256 wrongKey,
        int64 price,
        uint64 publishTime
    ) external {
        callCount++;
        wrongKey = bound(wrongKey, 1, SECP256K1_N - 1);
        if (wrongKey == signerKey) {
            wrongKey = signerKey == 1 ? 2 : signerKey - 1;
        }
        bytes32 feedId = _feed(feedSel);
        publishTime = uint64(
            bound(publishTime, 1, block.timestamp + oracle.MAX_CLOCK_SKEW())
        );
        uint64 before = stored(feedId);
        try
            oracle.updatePriceFeeds(_one(_sign(wrongKey, feedId, price, -8, publishTime)))
        {
            uint64 aft = stored(feedId);
            // a write that advanced the feed from a non-trusted sig == forgery.
            if (aft == publishTime && publishTime > before) ghostForged = true;
            if (aft < before) ghostRegressed = true;
        } catch {
            ghostWrongRejected++;
        }
    }

    /// Advance the clock so newer publishTimes become reachable over the run.
    function warp(uint256 dt) external {
        callCount++;
        dt = bound(dt, 1, 120);
        vm.warp(block.timestamp + dt);
    }
}

// =============================================================================
//                    STATEFUL INVARIANT: MONOTONICITY + TRUST
// =============================================================================
contract Invariant_FIOracleMono is Test {
    FIOracle internal oracle;
    FIOracleMonoHandler internal handler;
    uint256 internal constant SIGNER_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address internal admin = makeAddr("oracle_admin");

    function setUp() public {
        oracle = new FIOracle(vm.addr(SIGNER_KEY), admin);
        vm.warp(1_000_000);
        handler = new FIOracleMonoHandler(oracle, SIGNER_KEY);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.pushValid.selector;
        selectors[1] = handler.pushWrongKey.selector;
        selectors[2] = handler.warp.selector;
        targetSelector(
            StdInvariant.FuzzSelector({
                addr: address(handler),
                selectors: selectors
            })
        );
        targetContract(address(handler));
    }

    // (5) INV-MONO: stored publishTime never decreases, and equals the highest
    // value the handler ever successfully wrote, for every feed.
    function invariant_monotonicPublishTime() public view {
        assertFalse(
            handler.ghostRegressed(),
            "publishTime regressed -> monotonicity broken"
        );
        for (uint256 i = 0; i < 3; ++i) {
            bytes32 feedId = handler.feeds(i);
            assertEq(
                handler.stored(feedId),
                handler.ghostMax(feedId),
                "stored publishTime != max accepted"
            );
        }
    }

    // (6) INV-TRUST: no non-trusted signature ever produced a write, and the
    // trusted signer is unchanged for the whole campaign.
    function invariant_onlyTrustedSignerWrites() public view {
        assertFalse(
            handler.ghostForged(),
            "non-trusted signature was accepted -> forgery"
        );
        assertEq(oracle.trustedSigner(), vm.addr(SIGNER_KEY), "signer changed");
    }

    function afterInvariant() public view {
        console.log("mono handler callCount   :", handler.callCount());
        console.log("valid accepted (last seq):", handler.ghostValidAccepted());
        console.log("wrong rejected (last seq):", handler.ghostWrongRejected());
    }

    /// Deterministic non-vacuity: prove the ghost witnesses can actually move so
    /// the assertFalse invariants above cannot pass on an empty campaign.
    function test_monoHandlerNonVacuous() public {
        // valid advance.
        handler.pushValid(0, 15230000000, uint64(block.timestamp));
        bytes32 f = handler.feeds(0);
        uint64 t1 = handler.stored(f);
        assertGt(t1, 0, "valid update not stored");

        // stale valid -> no-op, no regression.
        handler.pushValid(0, 99, uint64(block.timestamp) - 1);
        assertEq(handler.stored(f), t1, "stale valid changed state");

        // wrong-key at a higher pt -> rejected, feed unchanged, no forgery.
        vm.warp(block.timestamp + 5);
        handler.pushWrongKey(0, 0xBEEF, 42, uint64(block.timestamp));
        assertEq(handler.stored(f), t1, "wrong-key mutated feed");
        assertGt(handler.ghostWrongRejected(), 0, "no wrong-key rejection");

        assertFalse(handler.ghostForged(), "forgery accepted");
        assertFalse(handler.ghostRegressed(), "monotonicity violated");
    }
}
