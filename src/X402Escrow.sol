// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

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

/// @title X402Escrow (V1)
/// @author Aleksei Ivashov (aivashov@fortytwo.network)
/// @notice UUPS-upgradeable escrow for the x402 (HTTP 402) payment pattern for swarm MCP services.
///
/// @dev Upgrade notes (V1 → V2):
///   The Escrow struct stores `refundAt` (uint40) directly instead of computing it from a global
///   `timeoutSecs`. If a future version changes the struct layout, a storage-migration function
///   must be included in V2's initializer to convert any active escrows. As long as the struct
///   layout stays the same, standard UUPS upgrades are safe.
///
/// Flow:
///   1. Client signs an EIP-3009 authorization off-chain (approve max spend).
///   2. Facilitator calls settle() — pulls USDC from client into escrow via receiveWithAuthorization.
///   3. After swarm MCP request completes, facilitator calls release() — splits USDC between
///      facilitator (msg.sender, actual cost) and client (unused remainder).
///   4. If the facilitator never calls release(), client can self-refund after timeout via refundAfterTimeout().
///
/// Roles:
///   - Owner (Ownable2StepUpgradeable): can upgrade the contract (UUPS). Two-step transfer.
///   - DEFAULT_ADMIN_ROLE: can change timeout, manage roles (grant/revoke facilitator).
///   - FACILITATOR_ROLE: can call settle() and release(). Payment goes to msg.sender.
///
/// Token: USDC on Base (6 decimals). Uses SafeERC20 for transfer safety.
contract X402Escrow is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    /// @notice Contract version for upgrade tracking.
    uint256 public constant VERSION = 1;

    /// @notice Role identifier for the facilitator that settles and releases escrows.
    bytes32 public constant FACILITATOR_ROLE = keccak256("FACILITATOR_ROLE");

    /// @notice USDC token address (supports both ERC-20 and EIP-3009).
    address public usdc;

    /// @notice Seconds before a client can self-refund an unreleased escrow.
    /// Default 5400 (90 min). Admin can set between 300 (5 min) and 86400 (24 h).
    /// Only applies to new escrows; existing escrows keep their refundAt deadline.
    uint256 public timeoutSecs;

    /// @notice Packed escrow data in a single storage slot (32 bytes).
    /// @dev client (160 bits) + refundAt (uint40, ~36812 year max) + amount (uint56, ~72B USDC max).
    ///      refundAt is set at settle time: block.timestamp + timeoutSecs. Changes to timeoutSecs
    ///      do not affect existing escrows.
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
    event TimeoutUpdated(uint256 newTimeoutSecs);

    // ─── Errors ──────────────────────────────────────────────

    error ZeroAddress(); // address(0) passed to initialize()
    error NotContract(); // _usdc is not a contract (EOA or empty address)
    error EscrowNotFound(); // escrow does not exist (already released/refunded or invalid ID)
    error EscrowAlreadyExists(); // escrowId collision (same client + nonce)
    error TimeoutNotReached(); // too early for client self-refund
    error TimeoutExpired(); // EIP-3009 authorization expired before settle()
    error NotYetValid(); // EIP-3009 authorization not yet valid (block.timestamp < validAfter)
    error InvalidAmount(); // zero amount or facilitatorAmount > escrow amount
    error InvalidTimeout(); // timeout outside [300, 86400] range
    error TransferMismatch(); // actual USDC received != expected (fee-on-transfer protection)

    // ─── Initializer (replaces constructor for UUPS proxy) ───

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the escrow (called once via proxy).
    /// @param _usdc         USDC token address (must support EIP-3009, must be a contract).
    /// @param _facilitator  Initial facilitator address. Gets FACILITATOR_ROLE.
    /// @param _admin        Gets DEFAULT_ADMIN_ROLE (can manage roles & timeout).
    /// @param _owner        Gets contract ownership (can upgrade via UUPS).
    function initialize(address _usdc, address _facilitator, address _admin, address _owner) external initializer {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_usdc.code.length == 0) revert NotContract();
        if (_facilitator == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        __Ownable_init(_owner);
        __Ownable2Step_init();
        __AccessControl_init();

        usdc = _usdc;
        timeoutSecs = 5400; // 90 min default

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(FACILITATOR_ROLE, _facilitator);
    }

    // ─── UUPS upgrade authorization ─────────────────────────

    /// @dev Only the owner can authorize contract upgrades.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ─── Admin ───────────────────────────────────────────────

    /// @notice Update the timeout window for client self-refund.
    /// @dev Only affects new escrows. Existing escrows keep their refundAt deadline.
    /// @param _timeoutSecs Must be between 300 (5 min) and 86400 (24 h).
    function setTimeout(uint256 _timeoutSecs) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_timeoutSecs < 300 || _timeoutSecs > 86400) revert InvalidTimeout();
        timeoutSecs = _timeoutSecs;
        emit TimeoutUpdated(_timeoutSecs);
    }

    /// @notice Temporary (pre-audit) method to rescue tokens stuck in the contract (e.g. from EIP-3009 frontrun griefing).
    /// @dev Only callable by admin. Use with caution — verify the tokens are truly unowned.
    /// @param token  ERC-20 token address to rescue.
    /// @param to     Recipient address.
    /// @param amount Amount to transfer.
    function rescueTokens(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(token).safeTransfer(to, amount);
    }

    // ─── Core: settle → release / refund ─────────────────────

    /// @notice Pull USDC from client into escrow using EIP-3009 signed authorization.
    /// @dev Called by the facilitator when it receives an HTTP 402 payment header from the client.
    ///      The client signs receiveWithAuthorization off-chain; facilitator submits it here.
    /// @param client     Client address that signed the authorization.
    /// @param maxAmount  Max USDC to lock (6 decimals). Actual cost may be less.
    /// @param validAfter  EIP-3009: authorization valid after this timestamp.
    /// @param validBefore EIP-3009: authorization valid before this timestamp.
    /// @param nonce      EIP-3009: unique nonce to prevent replay.
    /// @param v,r,s      EIP-3009: client's ECDSA signature.
    /// @return escrowId  Unique identifier for this escrow.
    function settle(
        address client,
        uint256 maxAmount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external onlyRole(FACILITATOR_ROLE) nonReentrant returns (bytes32 escrowId) {
        if (maxAmount == 0 || maxAmount > type(uint56).max) revert InvalidAmount();
        if (block.timestamp < validAfter) revert NotYetValid();
        if (block.timestamp >= validBefore) revert TimeoutExpired();

        escrowId = keccak256(abi.encodePacked(client, nonce));
        if (activeEscrows[escrowId].client != address(0)) revert EscrowAlreadyExists();

        // Check balance before/after to guard against fee-on-transfer tokens
        uint256 balBefore = IERC20(usdc).balanceOf(address(this));

        // Pull USDC from client → this contract via EIP-3009 (receiveWithAuthorization: msg.sender == to)
        IERC3009(usdc)
            .receiveWithAuthorization(client, address(this), maxAmount, validAfter, validBefore, nonce, v, r, s);

        uint256 received = IERC20(usdc).balanceOf(address(this)) - balBefore;
        if (received != maxAmount) revert TransferMismatch();

        // `timeoutSecs` is bounded by setTimeout() to <= 86400, so this cast is safe for current timestamps.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 refundAt = uint40(block.timestamp + timeoutSecs);
        // `maxAmount` is validated above to be <= type(uint56).max.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint56 amount = uint56(maxAmount);

        activeEscrows[escrowId] = Escrow({client: client, refundAt: refundAt, amount: amount});

        emit Deposited(escrowId, client, maxAmount);
    }

    /// @notice Release escrowed funds: pay facilitator (msg.sender) for actual usage, refund remainder to client.
    /// @dev Called by the facilitator after the swarm MCP request completes.
    ///      Payment goes to msg.sender (must have FACILITATOR_ROLE), not a stored address.
    /// @param escrowId          The escrow to release.
    /// @param facilitatorAmount USDC to send to facilitator (actual cost). Remainder goes back to client.
    ///                          Can be 0 (full refund) up to esc.amount (full payment).
    function release(bytes32 escrowId, uint256 facilitatorAmount) external onlyRole(FACILITATOR_ROLE) nonReentrant {
        Escrow memory esc = activeEscrows[escrowId];
        if (esc.client == address(0)) revert EscrowNotFound();
        if (facilitatorAmount > esc.amount) revert InvalidAmount();

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
    /// @dev Safety net: if facilitator goes offline or never calls release(), client isn't stuck.
    ///      Anyone can trigger this (funds always go to esc.client), enabling gasless refunds via relayers.
    ///      Uses the refundAt deadline stored at settle time — not affected by later setTimeout() calls.
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
