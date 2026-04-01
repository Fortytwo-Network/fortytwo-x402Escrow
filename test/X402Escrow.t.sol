// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {X402Escrow} from "../src/X402Escrow.sol";

/// @dev Mock USDC that supports receiveWithAuthorization (EIP-3009)
contract MockUSDC {
    string public name = "USD Coin";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;

    mapping(bytes32 => bool) public authorizationUsed;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        require(balanceOf[msg.sender] >= value, "insufficient balance");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        return true;
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256, /* validAfter */
        uint256, /* validBefore */
        bytes32 nonce,
        uint8,
        bytes32,
        bytes32
    ) external {
        require(msg.sender == to, "caller must be the payee");
        require(!authorizationUsed[nonce], "authorization already used");
        require(balanceOf[from] >= value, "insufficient balance");
        authorizationUsed[nonce] = true;
        balanceOf[from] -= value;
        balanceOf[to] += value;
    }
}

/// @dev Mock USDC that takes a 1% fee on receiveWithAuthorization (fee-on-transfer)
contract FeeOnTransferUSDC {
    string public name = "USD Coin";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256,
        uint256,
        bytes32,
        uint8,
        bytes32,
        bytes32
    ) external {
        require(balanceOf[from] >= value, "insufficient balance");
        uint256 fee = value / 100; // 1% fee
        balanceOf[from] -= value;
        balanceOf[to] += value - fee; // recipient gets less
    }
}

/// @dev Minimal V3 mock for upgrade test
contract X402EscrowV3Mock is X402Escrow {
    function v3Version() external pure returns (uint256) {
        return 3;
    }
}

contract X402EscrowTest is Test {
    X402Escrow public escrow;
    MockUSDC public usdc;

    address facilitator = address(0xBEEF);
    address owner = address(0x0123);
    address client = address(0xC0FE);

    bytes32 constant NONCE_TAG = keccak256("X402_ESCROW_FACILITATOR_NONCE_V1");

    uint256 constant ONE_USDC = 1_000_000;
    uint256 constant DEFAULT_TIMEOUT = 3600;

    function setUp() public {
        usdc = new MockUSDC();

        X402Escrow impl = new X402Escrow();
        bytes memory initData = abi.encodeCall(X402Escrow.initialize, (address(usdc), owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        escrow = X402Escrow(address(proxy));

        usdc.mint(client, 100 * ONE_USDC);
    }

    // ─── helpers ─────────────────────────────────────────────

    function _computeNonce(address fac, uint256 timeout, bytes32 salt) internal view returns (bytes32) {
        return keccak256(abi.encode(NONCE_TAG, block.chainid, address(escrow), fac, timeout, salt));
    }

    function _createEscrow(uint256 amount, bytes32 salt) internal returns (bytes32) {
        bytes32 nonce = _computeNonce(facilitator, DEFAULT_TIMEOUT, salt);
        vm.prank(facilitator);
        return escrow.settle(
            client, amount, 0, block.timestamp + 7200, DEFAULT_TIMEOUT, nonce, salt, 0, bytes32(0), bytes32(0)
        );
    }

    function _createEscrowWithTimeout(uint256 amount, bytes32 salt, uint256 timeout) internal returns (bytes32) {
        bytes32 nonce = _computeNonce(facilitator, timeout, salt);
        vm.prank(facilitator);
        return escrow.settle(
            client, amount, 0, block.timestamp + 7200, timeout, nonce, salt, 0, bytes32(0), bytes32(0)
        );
    }

    // ─── initialize ─────────────────────────────────────────

    function test_initialize_setsState() public view {
        assertEq(escrow.usdc(), address(usdc));
        assertEq(escrow.owner(), owner);
    }

    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert();
        escrow.initialize(address(usdc), owner);
    }

    function test_initialize_reverts_zeroUsdc() public {
        X402Escrow impl = new X402Escrow();
        vm.expectRevert(X402Escrow.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(X402Escrow.initialize, (address(0), owner)));
    }

    function test_initialize_reverts_eoaUsdc() public {
        X402Escrow impl = new X402Escrow();
        vm.expectRevert(X402Escrow.NotContract.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(X402Escrow.initialize, (address(0xDEAD), owner)));
    }

    function test_initialize_reverts_zeroOwner() public {
        X402Escrow impl = new X402Escrow();
        vm.expectRevert(X402Escrow.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(X402Escrow.initialize, (address(usdc), address(0))));
    }

    // ─── settle: success ────────────────────────────────────

    function test_settle_success() public {
        uint256 amount = 10 * ONE_USDC;
        bytes32 salt = keccak256("salt1");
        bytes32 nonce = _computeNonce(facilitator, DEFAULT_TIMEOUT, salt);

        vm.prank(facilitator);
        bytes32 escrowId = escrow.settle(
            client, amount, 0, block.timestamp + 3600, DEFAULT_TIMEOUT, nonce, salt, 0, bytes32(0), bytes32(0)
        );

        X402Escrow.EscrowView memory v = escrow.getEscrow(escrowId);

        assertEq(v.client, client);
        assertEq(v.amount, amount);
        assertEq(v.refundAt, block.timestamp + DEFAULT_TIMEOUT);
        assertFalse(v.canRefund);
        assertEq(v.timeUntilRefund, DEFAULT_TIMEOUT);
        assertEq(usdc.balanceOf(address(escrow)), amount);
    }

    function test_settle_anyAddressCanSettle() public {
        address anyFacilitator = address(0xFAC1);
        usdc.mint(client, 10 * ONE_USDC);
        bytes32 salt = keccak256("anysettle");
        bytes32 nonce = _computeNonce(anyFacilitator, DEFAULT_TIMEOUT, salt);

        vm.prank(anyFacilitator);
        bytes32 escrowId = escrow.settle(
            client, ONE_USDC, 0, block.timestamp + 3600, DEFAULT_TIMEOUT, nonce, salt, 0, bytes32(0), bytes32(0)
        );

        X402Escrow.EscrowView memory v = escrow.getEscrow(escrowId);
        assertEq(v.client, client);
        assertEq(v.amount, ONE_USDC);
    }

    function test_settle_perEscrowTimeout() public {
        bytes32 salt = keccak256("timeout_test");
        uint256 customTimeout = 600;
        bytes32 nonce = _computeNonce(facilitator, customTimeout, salt);

        vm.prank(facilitator);
        bytes32 escrowId = escrow.settle(
            client, ONE_USDC, 0, block.timestamp + 3600, customTimeout, nonce, salt, 0, bytes32(0), bytes32(0)
        );

        X402Escrow.EscrowView memory v = escrow.getEscrow(escrowId);
        assertEq(v.refundAt, block.timestamp + customTimeout);
        assertEq(v.timeUntilRefund, customTimeout);
    }

    // ─── settle: nonce-binding reverts ───────────────────────

    function test_settle_reverts_wrongSalt() public {
        bytes32 salt = keccak256("real_salt");
        bytes32 wrongSalt = keccak256("wrong_salt");
        bytes32 nonce = _computeNonce(facilitator, DEFAULT_TIMEOUT, salt);

        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.InvalidFacilitatorNonce.selector);
        escrow.settle(
            client, ONE_USDC, 0, block.timestamp + 3600, DEFAULT_TIMEOUT, nonce, wrongSalt, 0, bytes32(0), bytes32(0)
        );
    }

    function test_settle_reverts_differentSender() public {
        bytes32 salt = keccak256("frontrun");
        bytes32 nonce = _computeNonce(facilitator, DEFAULT_TIMEOUT, salt);
        address attacker = address(0xBAD);

        vm.prank(attacker);
        vm.expectRevert(X402Escrow.InvalidFacilitatorNonce.selector);
        escrow.settle(
            client, ONE_USDC, 0, block.timestamp + 3600, DEFAULT_TIMEOUT, nonce, salt, 0, bytes32(0), bytes32(0)
        );
    }

    function test_settle_reverts_timeoutTooLow() public {
        bytes32 salt = keccak256("low_timeout");
        uint256 tooLow = 299;
        bytes32 nonce = _computeNonce(facilitator, tooLow, salt);

        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.InvalidTimeout.selector);
        escrow.settle(
            client, ONE_USDC, 0, block.timestamp + 3600, tooLow, nonce, salt, 0, bytes32(0), bytes32(0)
        );
    }

    function test_settle_reverts_timeoutTooHigh() public {
        bytes32 salt = keccak256("high_timeout");
        uint256 tooHigh = 172_801;
        bytes32 nonce = _computeNonce(facilitator, tooHigh, salt);

        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.InvalidTimeout.selector);
        escrow.settle(
            client, ONE_USDC, 0, block.timestamp + 3600, tooHigh, nonce, salt, 0, bytes32(0), bytes32(0)
        );
    }

    function test_settle_timeoutAtMaxBoundary() public {
        bytes32 salt = keccak256("max_boundary");
        bytes32 nonce = _computeNonce(facilitator, 172_800, salt);

        vm.prank(facilitator);
        bytes32 escrowId = escrow.settle(
            client, ONE_USDC, 0, block.timestamp + 3600, 172_800, nonce, salt, 0, bytes32(0), bytes32(0)
        );

        X402Escrow.EscrowView memory v = escrow.getEscrow(escrowId);
        assertEq(v.refundAt, block.timestamp + 172_800);
    }

    // ─── settle: existing reverts ────────────────────────────

    function test_settle_reverts_zeroAmount() public {
        bytes32 salt = keccak256("zero_amt");
        bytes32 nonce = _computeNonce(facilitator, DEFAULT_TIMEOUT, salt);

        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.InvalidAmount.selector);
        escrow.settle(
            client, 0, 0, block.timestamp + 3600, DEFAULT_TIMEOUT, nonce, salt, 0, bytes32(0), bytes32(0)
        );
    }

    function test_settle_reverts_expired() public {
        bytes32 salt = keccak256("expired");
        bytes32 nonce = _computeNonce(facilitator, DEFAULT_TIMEOUT, salt);

        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.TimeoutExpired.selector);
        escrow.settle(
            client, ONE_USDC, 0, block.timestamp - 1, DEFAULT_TIMEOUT, nonce, salt, 0, bytes32(0), bytes32(0)
        );
    }

    function test_settle_reverts_notYetValid() public {
        bytes32 salt = keccak256("notyet");
        bytes32 nonce = _computeNonce(facilitator, DEFAULT_TIMEOUT, salt);

        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.NotYetValid.selector);
        escrow.settle(
            client,
            ONE_USDC,
            block.timestamp + 100,
            block.timestamp + 3600,
            DEFAULT_TIMEOUT,
            nonce,
            salt,
            0,
            bytes32(0),
            bytes32(0)
        );
    }

    function test_settle_reverts_amountExceedsUint56() public {
        uint256 tooMuch = uint256(type(uint56).max) + 1;
        usdc.mint(client, tooMuch);
        bytes32 salt = keccak256("big");
        bytes32 nonce = _computeNonce(facilitator, DEFAULT_TIMEOUT, salt);

        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.InvalidAmount.selector);
        escrow.settle(
            client, tooMuch, 0, block.timestamp + 3600, DEFAULT_TIMEOUT, nonce, salt, 0, bytes32(0), bytes32(0)
        );
    }

    function test_settle_reverts_escrowAlreadyExists() public {
        bytes32 salt = keccak256("duplicate");
        _createEscrow(ONE_USDC, salt);

        bytes32 nonce = _computeNonce(facilitator, DEFAULT_TIMEOUT, salt);
        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.EscrowAlreadyExists.selector);
        escrow.settle(
            client, ONE_USDC, 0, block.timestamp + 3600, DEFAULT_TIMEOUT, nonce, salt, 0, bytes32(0), bytes32(0)
        );
    }

    function test_settle_reverts_transferMismatch() public {
        FeeOnTransferUSDC feeToken = new FeeOnTransferUSDC();
        X402Escrow impl = new X402Escrow();
        bytes memory initData = abi.encodeCall(X402Escrow.initialize, (address(feeToken), owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        X402Escrow feeEscrow = X402Escrow(address(proxy));

        feeToken.mint(client, 100 * ONE_USDC);

        bytes32 salt = keccak256("fee");
        bytes32 nonce =
            keccak256(abi.encode(NONCE_TAG, block.chainid, address(feeEscrow), facilitator, DEFAULT_TIMEOUT, salt));

        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.TransferMismatch.selector);
        feeEscrow.settle(
            client, 10 * ONE_USDC, 0, block.timestamp + 3600, DEFAULT_TIMEOUT, nonce, salt, 0, bytes32(0), bytes32(0)
        );
    }

    // ─── release: success ───────────────────────────────────

    function test_release_partial() public {
        uint256 amount = 10 * ONE_USDC;
        uint256 facilitatorTake = 7 * ONE_USDC;
        bytes32 salt = keccak256("release_partial");

        bytes32 escrowId = _createEscrow(amount, salt);

        uint256 facilitatorBefore = usdc.balanceOf(facilitator);
        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(facilitator);
        escrow.release(escrowId, facilitatorTake, DEFAULT_TIMEOUT, salt);

        assertEq(usdc.balanceOf(facilitator), facilitatorBefore + facilitatorTake);
        assertEq(usdc.balanceOf(client), clientBefore + (amount - facilitatorTake));

        X402Escrow.EscrowView memory v = escrow.getEscrow(escrowId);
        assertEq(v.client, address(0));
        assertEq(v.amount, 0);
    }

    function test_release_full() public {
        uint256 amount = 5 * ONE_USDC;
        bytes32 salt = keccak256("release_full");

        bytes32 escrowId = _createEscrow(amount, salt);

        uint256 facilitatorBefore = usdc.balanceOf(facilitator);
        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(facilitator);
        escrow.release(escrowId, amount, DEFAULT_TIMEOUT, salt);

        assertEq(usdc.balanceOf(facilitator), facilitatorBefore + amount);
        assertEq(usdc.balanceOf(client), clientBefore);

        X402Escrow.EscrowView memory v = escrow.getEscrow(escrowId);
        assertEq(v.client, address(0));
    }

    // ─── release: nonce-binding reverts ──────────────────────

    function test_release_reverts_wrongFacilitator() public {
        bytes32 salt = keccak256("wrong_fac");
        bytes32 escrowId = _createEscrow(ONE_USDC, salt);

        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(X402Escrow.NotEscrowFacilitator.selector);
        escrow.release(escrowId, ONE_USDC, DEFAULT_TIMEOUT, salt);
    }

    function test_release_reverts_wrongSalt() public {
        bytes32 salt = keccak256("correct_salt");
        bytes32 wrongSalt = keccak256("wrong_salt");
        bytes32 escrowId = _createEscrow(ONE_USDC, salt);

        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.NotEscrowFacilitator.selector);
        escrow.release(escrowId, ONE_USDC, DEFAULT_TIMEOUT, wrongSalt);
    }

    function test_release_reverts_wrongTimeout() public {
        bytes32 salt = keccak256("wrong_timeout");
        bytes32 escrowId = _createEscrow(ONE_USDC, salt);

        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.NotEscrowFacilitator.selector);
        escrow.release(escrowId, ONE_USDC, DEFAULT_TIMEOUT + 1, salt);
    }

    function test_release_reverts_overAmount() public {
        bytes32 salt = keccak256("over_amt");
        bytes32 escrowId = _createEscrow(ONE_USDC, salt);

        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.InvalidAmount.selector);
        escrow.release(escrowId, 2 * ONE_USDC, DEFAULT_TIMEOUT, salt);
    }

    function test_release_reverts_doubleRelease() public {
        bytes32 salt = keccak256("double_release");
        bytes32 escrowId = _createEscrow(ONE_USDC, salt);

        vm.prank(facilitator);
        escrow.release(escrowId, ONE_USDC, DEFAULT_TIMEOUT, salt);

        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.EscrowNotFound.selector);
        escrow.release(escrowId, ONE_USDC, DEFAULT_TIMEOUT, salt);
    }

    function test_release_reverts_afterTimeout() public {
        bytes32 salt = keccak256("release_expired");
        bytes32 escrowId = _createEscrow(ONE_USDC, salt);

        vm.warp(block.timestamp + DEFAULT_TIMEOUT);

        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.TimeoutExpired.selector);
        escrow.release(escrowId, ONE_USDC, DEFAULT_TIMEOUT, salt);
    }

    // ─── refundAfterTimeout ──────────────────────────────────

    function test_refund_reverts_beforeTimeout() public {
        bytes32 salt = keccak256("refund_early");
        bytes32 escrowId = _createEscrow(5 * ONE_USDC, salt);

        vm.prank(client);
        vm.expectRevert(X402Escrow.TimeoutNotReached.selector);
        escrow.refundAfterTimeout(escrowId);
    }

    function test_refund_succeeds_afterTimeout() public {
        uint256 amount = 5 * ONE_USDC;
        bytes32 salt = keccak256("refund_ok");
        bytes32 escrowId = _createEscrow(amount, salt);

        uint256 clientBefore = usdc.balanceOf(client);

        vm.warp(block.timestamp + DEFAULT_TIMEOUT + 1);

        vm.prank(client);
        escrow.refundAfterTimeout(escrowId);

        assertEq(usdc.balanceOf(client), clientBefore + amount);

        X402Escrow.EscrowView memory v = escrow.getEscrow(escrowId);
        assertEq(v.client, address(0));
        assertEq(v.amount, 0);
    }

    function test_refund_usesPerEscrowTimeout() public {
        uint256 amount = 5 * ONE_USDC;
        bytes32 salt = keccak256("per_escrow_timeout");
        bytes32 escrowId = _createEscrowWithTimeout(amount, salt, 600);

        vm.warp(block.timestamp + 601);

        uint256 clientBefore = usdc.balanceOf(client);
        vm.prank(client);
        escrow.refundAfterTimeout(escrowId);

        assertEq(usdc.balanceOf(client), clientBefore + amount);
    }

    function test_refund_callableByAnyone() public {
        uint256 amount = 5 * ONE_USDC;
        bytes32 salt = keccak256("anyone_refund");
        bytes32 escrowId = _createEscrow(amount, salt);
        uint256 clientBefore = usdc.balanceOf(client);

        vm.warp(block.timestamp + DEFAULT_TIMEOUT + 1);

        address anyone = address(0xAAAA);
        vm.prank(anyone);
        escrow.refundAfterTimeout(escrowId);

        assertEq(usdc.balanceOf(client), clientBefore + amount);
        assertEq(usdc.balanceOf(anyone), 0);
    }

    function test_refund_reverts_alreadyReleased() public {
        bytes32 salt = keccak256("already_released");
        bytes32 escrowId = _createEscrow(ONE_USDC, salt);

        vm.prank(facilitator);
        escrow.release(escrowId, ONE_USDC, DEFAULT_TIMEOUT, salt);

        vm.warp(block.timestamp + DEFAULT_TIMEOUT + 1);

        vm.prank(client);
        vm.expectRevert(X402Escrow.EscrowNotFound.selector);
        escrow.refundAfterTimeout(escrowId);
    }

    // ─── getEscrow (EscrowView) ──────────────────────────────

    function test_getEscrow_timeUntilRefund() public {
        bytes32 salt = keccak256("view_test");
        bytes32 escrowId = _createEscrow(ONE_USDC, salt);

        X402Escrow.EscrowView memory v = escrow.getEscrow(escrowId);
        assertEq(v.timeUntilRefund, DEFAULT_TIMEOUT);
        assertEq(v.refundAt, block.timestamp + DEFAULT_TIMEOUT);
        assertFalse(v.canRefund);

        vm.warp(block.timestamp + DEFAULT_TIMEOUT / 2);
        v = escrow.getEscrow(escrowId);
        assertEq(v.timeUntilRefund, DEFAULT_TIMEOUT / 2);
        assertFalse(v.canRefund);

        vm.warp(block.timestamp + DEFAULT_TIMEOUT / 2);
        v = escrow.getEscrow(escrowId);
        assertEq(v.timeUntilRefund, 0);
        assertTrue(v.canRefund);
    }

    // ─── UUPS upgrade ────────────────────────────────────────

    function test_upgrade_byOwner() public {
        bytes32 salt = keccak256("upgrade_test");
        bytes32 escrowId = _createEscrow(5 * ONE_USDC, salt);

        X402EscrowV3Mock implV3 = new X402EscrowV3Mock();

        vm.prank(owner);
        escrow.upgradeToAndCall(address(implV3), "");

        X402Escrow.EscrowView memory v = escrow.getEscrow(escrowId);
        assertEq(v.amount, 5 * ONE_USDC);
        assertEq(v.client, client);

        assertEq(X402EscrowV3Mock(address(escrow)).v3Version(), 3);
    }

    function test_upgrade_reverts_notOwner() public {
        X402EscrowV3Mock implV3 = new X402EscrowV3Mock();

        vm.prank(facilitator);
        vm.expectRevert();
        escrow.upgradeToAndCall(address(implV3), "");

        vm.prank(client);
        vm.expectRevert();
        escrow.upgradeToAndCall(address(implV3), "");
    }

    function test_ownerTransfer_twoStep() public {
        address newOwner = address(0x9999);

        vm.prank(owner);
        escrow.transferOwnership(newOwner);
        assertEq(escrow.owner(), owner);

        vm.prank(newOwner);
        escrow.acceptOwnership();
        assertEq(escrow.owner(), newOwner);

        X402EscrowV3Mock implV3 = new X402EscrowV3Mock();
        vm.prank(owner);
        vm.expectRevert();
        escrow.upgradeToAndCall(address(implV3), "");

        vm.prank(newOwner);
        escrow.upgradeToAndCall(address(implV3), "");
    }

    // ─── V2 constants ────────────────────────────────────────

    function test_version() public view {
        assertEq(escrow.VERSION(), 2);
    }

    function test_nonceTag() public view {
        assertEq(escrow.NONCE_TAG(), keccak256("X402_ESCROW_FACILITATOR_NONCE_V1"));
    }

    function test_minTimeout() public view {
        assertEq(escrow.MIN_TIMEOUT(), 300);
    }

    function test_maxTimeout() public view {
        assertEq(escrow.MAX_TIMEOUT(), 172_800);
    }
}
