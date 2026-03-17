// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
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

/// @dev Minimal V2 implementation for upgrade test
contract X402EscrowV2 is X402Escrow {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract X402EscrowTest is Test {
    X402Escrow public escrow;
    MockUSDC public usdc;

    address facilitator = address(0xBEEF);
    address admin = address(0xAD01);
    address owner = address(0x0123);
    address client = address(0xC0FE);

    bytes32 constant FACILITATOR_ROLE = keccak256("FACILITATOR_ROLE");
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;

    uint256 constant ONE_USDC = 1_000_000;

    function setUp() public {
        usdc = new MockUSDC();

        // Deploy implementation + proxy
        X402Escrow impl = new X402Escrow();
        bytes memory initData = abi.encodeCall(X402Escrow.initialize, (address(usdc), facilitator, admin, owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        escrow = X402Escrow(address(proxy));

        // Fund client with 100 USDC
        usdc.mint(client, 100 * ONE_USDC);
    }

    // ─── initialize ─────────────────────────────────────────

    function test_initialize_setsState() public view {
        assertEq(escrow.usdc(), address(usdc));
        assertEq(escrow.timeoutSecs(), 5400);
        assertEq(escrow.owner(), owner);
        assertTrue(escrow.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(escrow.hasRole(FACILITATOR_ROLE, facilitator));
    }

    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert();
        escrow.initialize(address(usdc), facilitator, admin, owner);
    }

    function test_initialize_reverts_zeroUsdc() public {
        X402Escrow impl = new X402Escrow();
        vm.expectRevert(X402Escrow.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(X402Escrow.initialize, (address(0), facilitator, admin, owner)));
    }

    function test_initialize_reverts_eoaUsdc() public {
        X402Escrow impl = new X402Escrow();
        vm.expectRevert(X402Escrow.NotContract.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(X402Escrow.initialize, (address(0xDEAD), facilitator, admin, owner))
        );
    }

    function test_initialize_reverts_zeroFacilitator() public {
        X402Escrow impl = new X402Escrow();
        vm.expectRevert(X402Escrow.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(X402Escrow.initialize, (address(usdc), address(0), admin, owner))
        );
    }

    function test_initialize_reverts_zeroAdmin() public {
        X402Escrow impl = new X402Escrow();
        vm.expectRevert(X402Escrow.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(X402Escrow.initialize, (address(usdc), facilitator, address(0), owner))
        );
    }

    function test_initialize_reverts_zeroOwner() public {
        X402Escrow impl = new X402Escrow();
        vm.expectRevert(X402Escrow.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(X402Escrow.initialize, (address(usdc), facilitator, admin, address(0)))
        );
    }

    // ─── settle ──────────────────────────────────────────────

    function test_settle_success() public {
        uint256 amount = 10 * ONE_USDC;
        bytes32 nonce = keccak256("nonce1");

        vm.prank(facilitator);
        bytes32 escrowId = escrow.settle(client, amount, 0, block.timestamp + 3600, nonce, 0, bytes32(0), bytes32(0));

        X402Escrow.EscrowView memory v = escrow.getEscrow(escrowId);

        assertEq(v.client, client);
        assertEq(v.amount, amount);
        assertEq(v.refundAt, block.timestamp + 5400);
        assertFalse(v.canRefund);
        assertEq(v.timeUntilRefund, 5400);
        assertEq(usdc.balanceOf(address(escrow)), amount);
    }

    function test_settle_reverts_notFacilitator() public {
        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, client, FACILITATOR_ROLE)
        );
        escrow.settle(client, ONE_USDC, 0, block.timestamp + 3600, bytes32(0), 0, bytes32(0), bytes32(0));
    }

    function test_settle_reverts_zeroAmount() public {
        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.InvalidAmount.selector);
        escrow.settle(client, 0, 0, block.timestamp + 3600, bytes32(0), 0, bytes32(0), bytes32(0));
    }

    function test_settle_reverts_expired() public {
        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.TimeoutExpired.selector);
        escrow.settle(client, ONE_USDC, 0, block.timestamp - 1, bytes32(0), 0, bytes32(0), bytes32(0));
    }

    function test_settle_reverts_notYetValid() public {
        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.NotYetValid.selector);
        escrow.settle(
            client,
            ONE_USDC,
            block.timestamp + 100, // validAfter in the future
            block.timestamp + 3600,
            keccak256("notyet"),
            0,
            bytes32(0),
            bytes32(0)
        );
    }

    function test_settle_reverts_amountExceedsUint56() public {
        uint256 tooMuch = uint256(type(uint56).max) + 1;
        usdc.mint(client, tooMuch);

        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.InvalidAmount.selector);
        escrow.settle(client, tooMuch, 0, block.timestamp + 3600, keccak256("big"), 0, bytes32(0), bytes32(0));
    }

    function test_settle_reverts_escrowAlreadyExists() public {
        bytes32 nonce = keccak256("duplicate");
        vm.prank(facilitator);
        escrow.settle(client, ONE_USDC, 0, block.timestamp + 3600, nonce, 0, bytes32(0), bytes32(0));

        // Same client + nonce → same escrowId → revert
        // (MockUSDC also blocks reused nonce, but EscrowAlreadyExists fires first)
        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.EscrowAlreadyExists.selector);
        escrow.settle(client, ONE_USDC, 0, block.timestamp + 3600, nonce, 0, bytes32(0), bytes32(0));
    }

    function test_settle_reverts_transferMismatch() public {
        // Deploy escrow with fee-on-transfer token
        FeeOnTransferUSDC feeToken = new FeeOnTransferUSDC();
        X402Escrow impl = new X402Escrow();
        bytes memory initData = abi.encodeCall(X402Escrow.initialize, (address(feeToken), facilitator, admin, owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        X402Escrow feeEscrow = X402Escrow(address(proxy));

        feeToken.mint(client, 100 * ONE_USDC);

        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.TransferMismatch.selector);
        feeEscrow.settle(client, 10 * ONE_USDC, 0, block.timestamp + 3600, keccak256("fee"), 0, bytes32(0), bytes32(0));
    }

    // ─── release ─────────────────────────────────────────────

    function test_release_partial() public {
        uint256 amount = 10 * ONE_USDC;
        uint256 facilitatorTake = 7 * ONE_USDC;
        bytes32 nonce = keccak256("nonce2");

        vm.prank(facilitator);
        bytes32 escrowId = escrow.settle(client, amount, 0, block.timestamp + 3600, nonce, 0, bytes32(0), bytes32(0));

        uint256 facilitatorBefore = usdc.balanceOf(facilitator);
        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(facilitator);
        escrow.release(escrowId, facilitatorTake);

        // Payment goes to msg.sender (facilitator)
        assertEq(usdc.balanceOf(facilitator), facilitatorBefore + facilitatorTake);
        assertEq(usdc.balanceOf(client), clientBefore + (amount - facilitatorTake));

        // Storage cleared after release
        X402Escrow.EscrowView memory v = escrow.getEscrow(escrowId);
        assertEq(v.client, address(0));
        assertEq(v.amount, 0);
    }

    function test_release_full() public {
        uint256 amount = 5 * ONE_USDC;
        bytes32 nonce = keccak256("nonce3");

        vm.prank(facilitator);
        bytes32 escrowId = escrow.settle(client, amount, 0, block.timestamp + 3600, nonce, 0, bytes32(0), bytes32(0));

        uint256 facilitatorBefore = usdc.balanceOf(facilitator);
        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(facilitator);
        escrow.release(escrowId, amount);

        assertEq(usdc.balanceOf(facilitator), facilitatorBefore + amount);
        assertEq(usdc.balanceOf(client), clientBefore);

        // Storage cleared after release
        X402Escrow.EscrowView memory v = escrow.getEscrow(escrowId);
        assertEq(v.client, address(0));
    }

    function test_release_paysCallerNotStoredAddress() public {
        bytes32 escrowId = _createEscrow(10 * ONE_USDC, "nonce_caller");

        // Grant FACILITATOR_ROLE to a second facilitator
        address facilitator2 = address(0xBEE2);
        vm.prank(admin);
        escrow.grantRole(FACILITATOR_ROLE, facilitator2);

        uint256 f2Before = usdc.balanceOf(facilitator2);

        // facilitator2 calls release — payment should go to facilitator2, not facilitator
        vm.prank(facilitator2);
        escrow.release(escrowId, 10 * ONE_USDC);

        assertEq(usdc.balanceOf(facilitator2), f2Before + 10 * ONE_USDC);
    }

    function test_release_reverts_notFacilitator() public {
        bytes32 escrowId = _createEscrow(ONE_USDC, "nonce4");

        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, client, FACILITATOR_ROLE)
        );
        escrow.release(escrowId, ONE_USDC);
    }

    function test_release_reverts_overAmount() public {
        bytes32 escrowId = _createEscrow(ONE_USDC, "nonce5");

        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.InvalidAmount.selector);
        escrow.release(escrowId, 2 * ONE_USDC);
    }

    function test_release_reverts_doubleRelease() public {
        bytes32 escrowId = _createEscrow(ONE_USDC, "nonce6");

        vm.prank(facilitator);
        escrow.release(escrowId, ONE_USDC);

        // After delete: client=address(0), so EscrowNotFound reverts
        vm.prank(facilitator);
        vm.expectRevert(X402Escrow.EscrowNotFound.selector);
        escrow.release(escrowId, ONE_USDC);
    }

    // ─── refundAfterTimeout ──────────────────────────────────

    function test_refund_reverts_beforeTimeout() public {
        bytes32 escrowId = _createEscrow(5 * ONE_USDC, "nonce7");

        vm.prank(client);
        vm.expectRevert(X402Escrow.TimeoutNotReached.selector);
        escrow.refundAfterTimeout(escrowId);
    }

    function test_refund_succeeds_afterTimeout() public {
        uint256 amount = 5 * ONE_USDC;
        bytes32 escrowId = _createEscrow(amount, "nonce8");

        uint256 clientBefore = usdc.balanceOf(client);

        vm.warp(block.timestamp + 5401);

        vm.prank(client);
        escrow.refundAfterTimeout(escrowId);

        assertEq(usdc.balanceOf(client), clientBefore + amount);

        // Storage cleared after refund
        X402Escrow.EscrowView memory v = escrow.getEscrow(escrowId);
        assertEq(v.client, address(0));
        assertEq(v.amount, 0);
    }

    function test_refund_notAffectedByTimeoutChange() public {
        // Create escrow with default 5400s timeout → refundAt = now + 5400
        uint256 amount = 5 * ONE_USDC;
        bytes32 escrowId = _createEscrow(amount, "nonce_noretro");

        // Admin increases timeout to 86400s — should NOT affect existing escrow
        vm.prank(admin);
        escrow.setTimeout(86400);

        uint256 clientBefore = usdc.balanceOf(client);

        // Warp past original 5400s deadline
        vm.warp(block.timestamp + 5401);

        // Client can still refund using original deadline
        vm.prank(client);
        escrow.refundAfterTimeout(escrowId);

        assertEq(usdc.balanceOf(client), clientBefore + amount);
    }

    function test_refund_callableByAnyone() public {
        uint256 amount = 5 * ONE_USDC;
        bytes32 escrowId = _createEscrow(amount, "nonce9");
        uint256 clientBefore = usdc.balanceOf(client);

        vm.warp(block.timestamp + 5401);

        // Random address triggers refund — funds go to client, not caller
        address anyone = address(0xAAAA);
        vm.prank(anyone);
        escrow.refundAfterTimeout(escrowId);

        assertEq(usdc.balanceOf(client), clientBefore + amount);
        assertEq(usdc.balanceOf(anyone), 0);
    }

    function test_refund_reverts_alreadyReleased() public {
        bytes32 escrowId = _createEscrow(ONE_USDC, "nonce10");

        vm.prank(facilitator);
        escrow.release(escrowId, ONE_USDC);

        vm.warp(block.timestamp + 5401);

        // After delete: client=address(0), so EscrowNotFound
        vm.prank(client);
        vm.expectRevert(X402Escrow.EscrowNotFound.selector);
        escrow.refundAfterTimeout(escrowId);
    }

    // ─── setTimeout ──────────────────────────────────────────

    function test_setTimeout_success() public {
        vm.prank(admin);
        escrow.setTimeout(600);
        assertEq(escrow.timeoutSecs(), 600);
    }

    function test_setTimeout_reverts_notAdmin() public {
        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, client, DEFAULT_ADMIN_ROLE)
        );
        escrow.setTimeout(600);
    }

    function test_setTimeout_reverts_tooLow() public {
        vm.prank(admin);
        vm.expectRevert(X402Escrow.InvalidTimeout.selector);
        escrow.setTimeout(299);
    }

    function test_setTimeout_reverts_tooHigh() public {
        vm.prank(admin);
        vm.expectRevert(X402Escrow.InvalidTimeout.selector);
        escrow.setTimeout(86401);
    }

    function test_setTimeout_boundary_min() public {
        vm.prank(admin);
        escrow.setTimeout(300);
        assertEq(escrow.timeoutSecs(), 300);
    }

    function test_setTimeout_boundary_max() public {
        vm.prank(admin);
        escrow.setTimeout(86400);
        assertEq(escrow.timeoutSecs(), 86400);
    }

    // ─── admin role transfer ─────────────────────────────────

    function test_adminRole_grantAndRevoke() public {
        address newAdmin = address(0xAD02);

        vm.startPrank(admin);
        escrow.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        escrow.revokeRole(DEFAULT_ADMIN_ROLE, admin);
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, DEFAULT_ADMIN_ROLE)
        );
        escrow.setTimeout(600);

        vm.prank(newAdmin);
        escrow.setTimeout(600);
    }

    function test_grantRole_reverts_notAdmin() public {
        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, client, DEFAULT_ADMIN_ROLE)
        );
        escrow.grantRole(DEFAULT_ADMIN_ROLE, client);
    }

    // ─── getEscrow (EscrowView) ──────────────────────────────

    function test_getEscrow_timeUntilRefund() public {
        bytes32 escrowId = _createEscrow(ONE_USDC, "nonce11");

        X402Escrow.EscrowView memory v = escrow.getEscrow(escrowId);
        assertEq(v.timeUntilRefund, 5400);
        assertEq(v.refundAt, block.timestamp + 5400);
        assertFalse(v.canRefund);

        vm.warp(block.timestamp + 2700);
        v = escrow.getEscrow(escrowId);
        assertEq(v.timeUntilRefund, 2700);
        assertFalse(v.canRefund);

        vm.warp(block.timestamp + 2700);
        v = escrow.getEscrow(escrowId);
        assertEq(v.timeUntilRefund, 0);
        assertTrue(v.canRefund);
    }

    // ─── UUPS upgrade ────────────────────────────────────────

    function test_upgrade_byOwner() public {
        // Create an escrow before upgrade to verify state persists
        bytes32 escrowId = _createEscrow(5 * ONE_USDC, "nonce_upgrade");

        // Deploy V2 and upgrade
        X402EscrowV2 implV2 = new X402EscrowV2();

        vm.prank(owner);
        escrow.upgradeToAndCall(address(implV2), "");

        // State persists through upgrade
        X402Escrow.EscrowView memory v = escrow.getEscrow(escrowId);
        assertEq(v.amount, 5 * ONE_USDC);
        assertEq(v.client, client);

        // New V2 function is accessible
        assertEq(X402EscrowV2(address(escrow)).version(), 2);
    }

    function test_upgrade_reverts_notOwner() public {
        X402EscrowV2 implV2 = new X402EscrowV2();

        vm.prank(admin); // admin != owner
        vm.expectRevert();
        escrow.upgradeToAndCall(address(implV2), "");

        vm.prank(client);
        vm.expectRevert();
        escrow.upgradeToAndCall(address(implV2), "");
    }

    function test_ownerTransfer_twoStep() public {
        address newOwner = address(0x9999);

        // Step 1: current owner initiates transfer
        vm.prank(owner);
        escrow.transferOwnership(newOwner);

        // Owner hasn't changed yet (pending)
        assertEq(escrow.owner(), owner);

        // Step 2: new owner accepts
        vm.prank(newOwner);
        escrow.acceptOwnership();

        assertEq(escrow.owner(), newOwner);

        // Old owner can no longer upgrade
        X402EscrowV2 implV2 = new X402EscrowV2();
        vm.prank(owner);
        vm.expectRevert();
        escrow.upgradeToAndCall(address(implV2), "");

        // New owner can
        vm.prank(newOwner);
        escrow.upgradeToAndCall(address(implV2), "");
    }

    // ─── rescueTokens ─────────────────────────────────────────

    function test_rescueTokens_success() public {
        // Simulate stuck tokens (e.g. from frontrun griefing)
        usdc.mint(address(escrow), 5 * ONE_USDC);

        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(admin);
        escrow.rescueTokens(address(usdc), client, 5 * ONE_USDC);

        assertEq(usdc.balanceOf(client), clientBefore + 5 * ONE_USDC);
    }

    function test_rescueTokens_reverts_notAdmin() public {
        usdc.mint(address(escrow), ONE_USDC);

        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, client, DEFAULT_ADMIN_ROLE)
        );
        escrow.rescueTokens(address(usdc), client, ONE_USDC);
    }

    // ─── helpers ─────────────────────────────────────────────

    function _createEscrow(uint256 amount, bytes memory nonceSeed) internal returns (bytes32) {
        bytes32 nonce = keccak256(nonceSeed);
        vm.prank(facilitator);
        return escrow.settle(client, amount, 0, block.timestamp + 3600, nonce, 0, bytes32(0), bytes32(0));
    }
}
