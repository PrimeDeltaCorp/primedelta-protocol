// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

// PrimeDelta audit — Phase 2 STATEFUL INVARIANT FUZZING for FIOracle.
//
// Handler-based Foundry invariant suite. The handler submits a random mix of
// VALID signed updates (signed by the trusted signer key, random feed/price/
// publishTime) and INVALID updates (random v/r/s, or signed by a wrong key).
// Ghost variables track the last accepted publishTime per feed; the invariants
// assert monotonicity and that no non-trusted signature is ever accepted.
//
// Reuses the exact signing/packing scheme from AuditFIOraclePoC (do NOT
// reinvent): abi.encodePacked(feedId, price, expo, publishTime) -> eth-signed.
//
// Run:
//   forge test --match-path test/AuditInvariant_FIOracle.t.sol -vvv
//   forge test --match-contract AuditInvariant_FIOracle -vvv

import {Test, console} from "forge-std/Test.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";
import {FIOracle} from "../../src/FIOracle.sol";
import {IPriceOracle} from "../../src/IPriceOracle.sol";

contract FIOracleHandler is StdUtils {
    Vm internal constant vm =
        Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    FIOracle public oracle;
    uint256 public signerKey;
    address public signer;

    // A SMALL fixed set of feeds the fuzzer rotates through (so monotonicity
    // gets repeatedly stressed on the same feed).
    bytes32[3] public feeds;

    // ---- ghosts ----
    // Highest publishTime we have EVER successfully written per feed (mirror of
    // what the oracle should store). INV-MONOTONIC: the oracle's stored
    // publishTime must always equal the max we ever accepted (never regress).
    mapping(bytes32 => uint64) public ghost_lastAcceptedPublishTime;
    // INV-ONLY-TRUSTED: set true if the oracle EVER accepted an update whose
    // signature did not come from the trusted signer. Must stay false.
    bool public ghost_forgedAccepted;
    // INV-MONOTONIC violation witness.
    bool public ghost_monotonicViolated;

    uint256 public callCount;
    uint256 public ghost_validAccepted;
    uint256 public ghost_forgedRejected;

    constructor(FIOracle _oracle, uint256 _signerKey) {
        oracle = _oracle;
        signerKey = _signerKey;
        signer = vm.addr(_signerKey);
        feeds[0] = bytes32(uint256(1));
        feeds[1] = bytes32(uint256(2));
        feeds[2] = bytes32(uint256(3));
    }

    function _pack(
        bytes32 feedId,
        int64 price,
        int32 expo,
        uint64 publishTime,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(feedId, price, expo, publishTime, v, r, s);
    }

    function _signWith(
        uint256 key,
        bytes32 feedId,
        int64 price,
        int32 expo,
        uint64 publishTime
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        // Domain-bound preimage: MUST match FIOracle._updateSingleFeed exactly
        // (block.chainid + address(oracle) + feed fields). The F-001/F-028 fix
        // added chainid + verifyingContract; a preimage missing them recovers a
        // different address and the oracle rejects it as InvalidSignature.
        bytes32 h = keccak256(
            abi.encodePacked(block.chainid, address(oracle), feedId, price, expo, publishTime)
        );
        bytes32 eth = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", h)
        );
        (v, r, s) = vm.sign(key, eth);
    }

    function _one(bytes memory blob) internal pure returns (bytes[] memory a) {
        a = new bytes[](1);
        a[0] = blob;
    }

    function _feed(uint256 sel) internal view returns (bytes32) {
        return feeds[sel % 3];
    }

    /// Stored publishTime for a feed, or 0 if never set. Uses a max age so the
    /// staleness branch never trips; catches PriceFeedNotFound -> 0.
    function _storedPublishTime(bytes32 feedId) public view returns (uint64) {
        try oracle.getPriceNoOlderThan(feedId, type(uint256).max) returns (
            IPriceOracle.Price memory p
        ) {
            return p.publishTime;
        } catch {
            return 0;
        }
    }

    // ---------- ACTIONS ----------

    /// Submit a VALID update (signed by the trusted signer). publishTime is
    /// bounded to [now-2*staleness, now+skew] so a meaningful fraction lands in
    /// the acceptable window; the oracle ignores stale-vs-stored ones silently.
    function pushValid(
        uint256 feedSel,
        int64 price,
        uint64 publishTime
    ) external {
        callCount++;
        bytes32 feedId = _feed(feedSel);
        int32 expo = -8;
        // keep price positive-ish but allow zero/neg (oracle stores verbatim).
        publishTime = uint64(
            bound(
                publishTime,
                block.timestamp > 120 ? block.timestamp - 120 : 0,
                block.timestamp + oracle.MAX_CLOCK_SKEW()
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = _signWith(
            signerKey,
            feedId,
            price,
            expo,
            publishTime
        );
        uint64 storedBefore = _storedPublishTime(feedId);
        try oracle.updatePriceFeeds(_one(_pack(feedId, price, expo, publishTime, v, r, s))) {
            uint64 storedAfter = _storedPublishTime(feedId);
            // The oracle accepts iff publishTime > storedBefore (else no-op).
            if (publishTime > storedBefore) {
                if (storedAfter != publishTime) ghost_monotonicViolated = true;
                ghost_lastAcceptedPublishTime[feedId] = publishTime;
                ghost_validAccepted++;
            } else {
                // no-op path: stored must NOT have regressed.
                if (storedAfter != storedBefore) ghost_monotonicViolated = true;
            }
        } catch {}
    }

    /// Submit a FORGED update: a random (v, r, s) that is NOT a trusted-signer
    /// signature over this message. The oracle MUST reject it (revert) — or, if
    /// the random sig happens to recover to SOME address, that address must not
    /// be the trusted signer (ECDSA.recover can return a junk address but never
    /// the trusted one for a message it didn't sign).
    function pushForgedRandomSig(
        uint256 feedSel,
        int64 price,
        uint64 publishTime,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        callCount++;
        bytes32 feedId = _feed(feedSel);
        int32 expo = -8;
        publishTime = uint64(
            bound(publishTime, 1, block.timestamp + oracle.MAX_CLOCK_SKEW())
        );
        uint64 storedBefore = _storedPublishTime(feedId);
        try
            oracle.updatePriceFeeds(_one(_pack(feedId, price, expo, publishTime, v, r, s)))
        {
            // Accepted without reverting. Two legal cases:
            //  (a) publishTime <= storedBefore -> silent no-op (no write).
            //  (b) the random sig coincidentally recovered the trusted signer
            //      (astronomically unlikely) -> would be a real write.
            // A write that advanced the stored publishTime from a NON-trusted
            // signature is a forgery acceptance.
            uint64 storedAfter = _storedPublishTime(feedId);
            if (storedAfter == publishTime && publishTime > storedBefore) {
                ghost_forgedAccepted = true;
            }
        } catch {
            ghost_forgedRejected++;
        }
    }

    /// Submit a WRONG-KEY update: a valid signature but from a different,
    /// non-trusted key. Must always revert with InvalidSignature.
    function pushWrongSigner(
        uint256 feedSel,
        uint256 wrongKey,
        int64 price,
        uint64 publishTime
    ) external {
        callCount++;
        // ensure wrongKey is a valid, non-trusted secp256k1 key.
        wrongKey = bound(
            wrongKey,
            1,
            0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140 - 1
        );
        if (wrongKey == signerKey) wrongKey = signerKey - 1;
        bytes32 feedId = _feed(feedSel);
        int32 expo = -8;
        publishTime = uint64(
            bound(publishTime, 1, block.timestamp + oracle.MAX_CLOCK_SKEW())
        );
        (uint8 v, bytes32 r, bytes32 s) = _signWith(
            wrongKey,
            feedId,
            price,
            expo,
            publishTime
        );
        uint64 storedBefore = _storedPublishTime(feedId);
        try
            oracle.updatePriceFeeds(_one(_pack(feedId, price, expo, publishTime, v, r, s)))
        {
            uint64 storedAfter = _storedPublishTime(feedId);
            // The only non-revert path for a wrong signer is publishTime <=
            // storedBefore (early no-op return BEFORE signature check). Any
            // actual write is a forgery acceptance.
            if (storedAfter == publishTime && publishTime > storedBefore) {
                ghost_forgedAccepted = true;
            }
        } catch {
            ghost_forgedRejected++;
        }
    }

    /// Advance the clock so fresh publishTimes become reachable over the run.
    function warp(uint256 dt) external {
        callCount++;
        dt = bound(dt, 1, 90);
        vm.warp(block.timestamp + dt);
    }
}

contract AuditInvariant_FIOracle is Test {
    FIOracle internal oracle;
    FIOracleHandler internal handler;
    // Anvil default key 0 (same one AuditFIOraclePoC uses).
    uint256 internal constant SIGNER_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address internal admin = makeAddr("oracle_admin");

    function setUp() public {
        address signer = vm.addr(SIGNER_KEY);
        oracle = new FIOracle(signer, admin);
        // start the clock comfortably above 0 so now-120 doesn't underflow.
        vm.warp(1_000_000);
        handler = new FIOracleHandler(oracle, SIGNER_KEY);

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.pushValid.selector;
        selectors[1] = handler.pushForgedRandomSig.selector;
        selectors[2] = handler.pushWrongSigner.selector;
        selectors[3] = handler.warp.selector;
        targetSelector(
            StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors})
        );
        targetContract(address(handler));
    }

    // ============================================================
    // INV-MONOTONIC: stored publishTime per feed is non-decreasing across any
    // sequence of updates. The handler flags any observed regression; we also
    // assert directly here that each feed's stored publishTime equals the
    // highest publishTime the handler ever successfully wrote.
    // ============================================================
    function invariant_monotonicPublishTime() public view {
        assertFalse(
            handler.ghost_monotonicViolated(),
            "publishTime regressed -> monotonicity broken"
        );
        for (uint256 i = 0; i < 3; i++) {
            bytes32 feedId = handler.feeds(i);
            uint64 stored = handler._storedPublishTime(feedId);
            assertEq(
                stored,
                handler.ghost_lastAcceptedPublishTime(feedId),
                "stored publishTime != max accepted"
            );
        }
    }

    // ============================================================
    // INV-ONLY-TRUSTED: no update with a signature that is not the trusted
    // signer's is ever accepted (random v/r/s and wrong-key signatures are both
    // fuzzed). The handler flags any forged acceptance.
    // ============================================================
    function invariant_onlyTrustedSigner() public view {
        assertFalse(
            handler.ghost_forgedAccepted(),
            "non-trusted signature was accepted -> forgery"
        );
        // trustedSigner is immutable in this campaign (no admin action).
        assertEq(oracle.trustedSigner(), vm.addr(SIGNER_KEY), "signer changed");
    }

    function afterInvariant() public view {
        // NOTE: in invariant mode the handler's ghost counters reset between
        // runs, so afterInvariant sees only the LAST sequence — it is logged for
        // visibility but NOT asserted (that would give false negatives when the
        // last sequence happened to skip an action). Campaign-wide non-vacuity
        // is proven deterministically by test_oracle_handlerNonVacuous below.
        console.log("oracle handler callCount (last seq):", handler.callCount());
        console.log("valid accepted (last seq):", handler.ghost_validAccepted());
        console.log("forged rejected (last seq):", handler.ghost_forgedRejected());
    }

    // Deterministic non-vacuity + behavior proof: exercise each handler action
    // once and assert the oracle reacts as the invariants require.
    function test_oracle_handlerNonVacuous() public {
        // valid update -> accepted, publishTime stored.
        handler.pushValid(0, int64(15230000000), uint64(block.timestamp));
        bytes32 f = handler.feeds(0);
        assertGt(handler._storedPublishTime(f), 0, "valid update not stored");
        assertGt(handler.ghost_validAccepted(), 0, "no valid accepted");

        // wrong-key update at a higher publishTime -> must be rejected, stored
        // publishTime unchanged, forgery flag stays false.
        uint64 before = handler._storedPublishTime(f);
        vm.warp(block.timestamp + 5);
        handler.pushWrongSigner(0, 0xBEEF, int64(99), uint64(block.timestamp));
        assertEq(handler._storedPublishTime(f), before, "wrong signer mutated state");
        assertGt(handler.ghost_forgedRejected(), 0, "no forged rejection recorded");
        assertFalse(handler.ghost_forgedAccepted(), "forgery accepted");

        // random-sig update -> rejected (or no-op), never a forged write.
        handler.pushForgedRandomSig(
            0,
            int64(7),
            uint64(block.timestamp),
            27,
            bytes32(uint256(0xdead)),
            bytes32(uint256(0xbeef))
        );
        assertFalse(handler.ghost_forgedAccepted(), "random sig forged write");
        assertFalse(handler.ghost_monotonicViolated(), "monotonic violated");
    }
}
