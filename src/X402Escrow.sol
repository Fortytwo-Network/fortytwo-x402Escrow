// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/// @dev EIP-3009 receiveWithAuthorization — USDC-specific, not in OpenZeppelin.
/// Uses receiveWithAuthorization (not transferWithAuthorization) so that only this contract
/// (msg.sender == to) can execute the transfer, preventing frontrun griefing by MEV bots.
/// The client must sign the ReceiveWithAuthorization typehash (not TransferWithAuthorization).
/// https://eips.ethereum.org/EIPS/eip-3009
interface IERC3009 {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/// @title X402Escrow (V2 — Permissionless Facilitator)
/// @author Aleksei Ivashov (aivashov@fortytwo.network)
/// @notice UUPS-upgradeable escrow for the x402 (HTTP 402) payment pattern for swarm MCP services.
///
/// @dev V2 changes (Permissionless Facilitator):
///   - settle() and release() are fully permissionless.
///   - Facilitator binding is cryptographic: nonce = keccak256(TAG, chainId, escrow, facilitator, refundTimeout, salt).
///   - Per-escrow refundTimeoutSecs (within [MIN_TIMEOUT, MAX_TIMEOUT]) replaces global timeout.
///   - Only the facilitator who settled can release (proven via nonce reconstruction).
///   - No admin roles — only owner for UUPS upgrades.
///
/// @dev Upgrade notes (V1 → V2):
///   The Escrow struct layout is unchanged. V2 is deployed as a new proxy (not upgraded from V1).
///
/// Flow:
///   1. Facilitator generates salt, computes nonce, sends params to client.
///   2. Client signs EIP-3009 ReceiveWithAuthorization with the computed nonce.
///   3. Facilitator calls settle() — contract verifies nonce binding and pulls USDC into escrow.
///   4. After request completes, facilitator calls release() with same refundTimeoutSecs and salt.
///   5. If facilitator never calls release(), client self-refunds after per-escrow timeout.
///
/// Roles:
///   - Owner (Ownable2StepUpgradeable): can upgrade the contract (UUPS). Two-step transfer.
///
/// Token: USDC on Base (6 decimals). Uses SafeERC20 for transfer safety.
contract X402Escrow is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Contract version for upgrade tracking.
    uint256 public constant VERSION = 2;

    /// @notice Domain tag for V2 nonce-binding. Prevents cross-protocol replay.
    bytes32 public constant NONCE_TAG = keccak256("X402_ESCROW_FACILITATOR_NONCE_V1");

    /// @notice Minimum allowed per-escrow refund timeout (5 minutes).
    uint256 public constant MIN_TIMEOUT = 300;

    /// @notice Maximum allowed per-escrow refund timeout (48 hours).
    uint256 public constant MAX_TIMEOUT = 172_800;

    /// @notice USDC token address (supports both ERC-20 and EIP-3009).
    address public usdc;

    /// @notice Packed escrow data in a single storage slot (32 bytes).
    /// @dev client (160 bits) + refundAt (uint40, ~36812 year max) + amount (uint56, ~72B USDC max).
    ///      refundAt is set at settle time: block.timestamp + refundTimeoutSecs.
    struct Escrow {
        address client; // 20 bytes — who deposited USDC
        uint40 refundAt; // 5 bytes  — timestamp after which client can self-refund
        uint56 amount; // 7 bytes  — total USDC locked (6 decimals, max ~72B USDC)
    }

    /// @notice View-only struct returned by getEscrow(). Uses full-width types for convenience.
    struct EscrowView {
        address client;
        uint256 amount;
        uint256 refundAt; // timestamp after which client can self-refund
        bool canRefund; // true if client can call refundAfterTimeout() right now
        uint256 timeUntilRefund; // seconds until refund is available (0 if already eligible)
    }

    /// @notice Active escrows by ID. ID = keccak256(client, nonce).
    /// Entries are deleted on release or refund.
    mapping(bytes32 => Escrow) public activeEscrows;

    // ─── Events ──────────────────────────────────────────────

    event Deposited(bytes32 indexed escrowId, address indexed client, uint256 amount);
    event Released(bytes32 indexed escrowId, address indexed facilitator, uint256 toFacilitator, uint256 toClient);
    event Refunded(bytes32 indexed escrowId, address indexed client, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────

    error ZeroAddress(); // address(0) passed to initialize()
    error NotContract(); // _usdc is not a contract (EOA or empty address)
    error EscrowNotFound(); // escrow does not exist (already released/refunded or invalid ID)
    error EscrowAlreadyExists(); // escrowId collision (same client + nonce)
    error TimeoutNotReached(); // too early for client self-refund
    error TimeoutExpired(); // EIP-3009 auth expired (settle) or escrow past refundAt (release)
    error NotYetValid(); // EIP-3009 authorization not yet valid (block.timestamp < validAfter)
    error InvalidAmount(); // zero amount or facilitatorAmount > escrow amount
    error InvalidTimeout(); // timeout outside allowed range
    error TransferMismatch(); // actual USDC received != expected (fee-on-transfer protection)
    error InvalidFacilitatorNonce(); // nonce does not match V2 formula for msg.sender
    error NotEscrowFacilitator(); // release called by wrong facilitator (nonce mismatch)

    // ─── Initializer (replaces constructor for UUPS proxy) ───

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the escrow (called once via proxy).
    /// @param _usdc  USDC token address (must support EIP-3009, must be a contract).
    /// @param _owner Gets contract ownership (can upgrade via UUPS).
    function initialize(address _usdc, address _owner) external initializer {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_usdc.code.length == 0) revert NotContract();
        if (_owner == address(0)) revert ZeroAddress();

        __Ownable_init(_owner);
        __Ownable2Step_init();

        usdc = _usdc;
    }

    // ─── UUPS upgrade authorization ─────────────────────────

    /// @dev Only the owner can authorize contract upgrades.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ─── Internal: nonce computation ─────────────────────────

    /// @dev Compute the expected EIP-3009 nonce for facilitator binding.
    ///      nonce = keccak256(TAG, chainId, escrowAddress, facilitatorAddress, refundTimeoutSecs, salt)
    function _computeFacilitatorNonce(address facilitatorAddr, uint256 refundTimeoutSecs, bytes32 salt)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(NONCE_TAG, block.chainid, address(this), facilitatorAddr, refundTimeoutSecs, salt));
    }

    // ─── Core: settle → release / refund ─────────────────────

    /// @notice Pull USDC from client into escrow using EIP-3009 signed authorization.
    /// @dev Permissionless: any address can call, but the nonce cryptographically binds msg.sender
    ///      as the facilitator for this escrow. A different address cannot reuse the client's signature.
    /// @param client            Client address that signed the authorization.
    /// @param maxAmount         Max USDC to lock (6 decimals). Actual cost may be less.
    /// @param validAfter        EIP-3009: authorization valid after this timestamp.
    /// @param validBefore       EIP-3009: authorization valid before this timestamp.
    /// @param refundTimeoutSecs Per-escrow refund window in seconds. Must be in [MIN_TIMEOUT, MAX_TIMEOUT].
    /// @param nonce             EIP-3009 nonce (must equal keccak256(TAG, chainId, this, msg.sender, refundTimeoutSecs, salt)).
    /// @param salt              Random bytes32 used in nonce computation.
    /// @param v,r,s             EIP-3009: client's ECDSA signature.
    /// @return escrowId         Unique identifier for this escrow.
    function settle(
        address client,
        uint256 maxAmount,
        uint256 validAfter,
        uint256 validBefore,
        uint256 refundTimeoutSecs,
        bytes32 nonce,
        bytes32 salt,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (bytes32 escrowId) {
        if (maxAmount == 0 || maxAmount > type(uint56).max) revert InvalidAmount();
        if (block.timestamp < validAfter) revert NotYetValid();
        if (block.timestamp >= validBefore) revert TimeoutExpired();
        if (refundTimeoutSecs < MIN_TIMEOUT || refundTimeoutSecs > MAX_TIMEOUT) revert InvalidTimeout();

        // Verify nonce binds msg.sender as facilitator
        if (nonce != _computeFacilitatorNonce(msg.sender, refundTimeoutSecs, salt)) {
            revert InvalidFacilitatorNonce();
        }

        escrowId = keccak256(abi.encodePacked(client, nonce));
        if (activeEscrows[escrowId].client != address(0)) revert EscrowAlreadyExists();

        // Pull USDC and verify no fee-on-transfer
        {
            uint256 balBefore = IERC20(usdc).balanceOf(address(this));
            IERC3009(usdc)
                .receiveWithAuthorization(client, address(this), maxAmount, validAfter, validBefore, nonce, v, r, s);
            if (IERC20(usdc).balanceOf(address(this)) - balBefore != maxAmount) revert TransferMismatch();
        }

        // Both casts are safe: refundTimeoutSecs <= MAX_TIMEOUT, maxAmount <= type(uint56).max
        activeEscrows[escrowId] =
            Escrow({client: client, refundAt: uint40(block.timestamp + refundTimeoutSecs), amount: uint56(maxAmount)});

        emit Deposited(escrowId, client, maxAmount);
    }

    /// @notice Release escrowed funds: pay facilitator for actual usage, refund remainder to client.
    /// @dev Permissionless: only the facilitator cryptographically bound at settle time can succeed.
    ///      The contract reconstructs the nonce from (msg.sender, refundTimeoutSecs, salt) and verifies
    ///      it matches the escrowId. A different address or altered parameters will revert.
    /// @param escrowId          The escrow to release.
    /// @param facilitatorAmount USDC to send to facilitator (actual cost). Remainder goes to client.
    /// @param refundTimeoutSecs Must match the value used in settle().
    /// @param salt              Must match the value used in settle().
    function release(bytes32 escrowId, uint256 facilitatorAmount, uint256 refundTimeoutSecs, bytes32 salt)
        external
        nonReentrant
    {
        Escrow memory esc = activeEscrows[escrowId];
        if (esc.client == address(0)) revert EscrowNotFound();
        if (block.timestamp >= uint256(esc.refundAt)) revert TimeoutExpired();
        if (facilitatorAmount > esc.amount) revert InvalidAmount();

        // Verify caller is the bound facilitator by reconstructing nonce and checking escrowId
        bytes32 nonce = _computeFacilitatorNonce(msg.sender, refundTimeoutSecs, salt);
        bytes32 expectedEscrowId = keccak256(abi.encodePacked(esc.client, nonce));
        if (escrowId != expectedEscrowId) revert NotEscrowFacilitator();

        uint256 clientRefund = esc.amount - facilitatorAmount;

        // Clear storage before transfers (gas refund + prevents reentrancy on stale data)
        delete activeEscrows[escrowId];

        // Pay facilitator (msg.sender) for actual usage
        if (facilitatorAmount > 0) IERC20(usdc).safeTransfer(msg.sender, facilitatorAmount);
        // Return unused portion to client
        if (clientRefund > 0) IERC20(usdc).safeTransfer(esc.client, clientRefund);

        emit Released(escrowId, msg.sender, facilitatorAmount, clientRefund);
    }

    /// @notice Refund escrowed funds to client after timeout. Callable by anyone.
    /// @dev Safety net: if facilitator goes offline or loses salt, client isn't stuck.
    ///      Anyone can trigger this (funds always go to esc.client), enabling gasless refunds via relayers.
    ///      Uses the refundAt deadline stored at settle time.
    /// @param escrowId The escrow to refund.
    function refundAfterTimeout(bytes32 escrowId) external nonReentrant {
        Escrow memory esc = activeEscrows[escrowId];
        if (esc.client == address(0)) revert EscrowNotFound();
        if (block.timestamp < uint256(esc.refundAt)) revert TimeoutNotReached();

        // Clear storage before transfer (gas refund)
        delete activeEscrows[escrowId];

        IERC20(usdc).safeTransfer(esc.client, esc.amount);

        emit Refunded(escrowId, esc.client, esc.amount);
    }

    // ─── Views ───────────────────────────────────────────────

    /// @notice Get full escrow info as a single struct.
    function getEscrow(bytes32 escrowId) external view returns (EscrowView memory) {
        Escrow memory esc = activeEscrows[escrowId];
        uint256 deadline = uint256(esc.refundAt);
        bool canRefund = esc.client != address(0) && block.timestamp >= deadline;
        uint256 remaining = block.timestamp >= deadline ? 0 : deadline - block.timestamp;

        return EscrowView({
            client: esc.client,
            amount: uint256(esc.amount),
            refundAt: deadline,
            canRefund: canRefund,
            timeUntilRefund: remaining
        });
    }
}
