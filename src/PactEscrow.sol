// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PactEscrow — Trustless service agreements between agents
/// @notice Lock PACT tokens in escrow. Recipient completes work, verifier confirms, tokens release.
/// @dev No admin functions, no upgradability. Code is the arbiter.

interface IERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

contract PactEscrow {

    // ──────────────────── Types ─────────────────────────────

    enum Status { Active, PendingVerification, Completed, Reclaimed }

    /// @notice A pact is an escrow agreement between two agents
    struct Pact {
        address creator;      // Agent who locked the tokens
        address recipient;    // Agent who does the work
        address verifier;     // Agent who confirms completion (address(0) = self-verified)
        uint256 amount;       // PACT tokens locked
        uint256 deadline;     // Unix timestamp — after this, creator can reclaim
        Status  status;       // Current state
    }

    // ──────────────────── Storage ───────────────────────────

    /// @notice The PACT token contract
    IERC20 public immutable pactToken;

    /// @notice Auto-incrementing pact ID
    uint256 public nextPactId;

    /// @notice All pacts by ID
    mapping(uint256 => Pact) public pacts;

    // ──────────────────── Events ────────────────────────────

    event PactCreated(
        uint256 indexed pactId,
        address indexed creator,
        address indexed recipient,
        address verifier,
        uint256 amount,
        uint256 deadline
    );

    event PactCompleted(uint256 indexed pactId, address indexed recipient);
    event PactVerified(uint256 indexed pactId, address indexed verifier);
    event PactReclaimed(uint256 indexed pactId, address indexed creator);

    // ──────────────────── Constructor ───────────────────────

    /// @param _pactToken Address of the deployed PACT ERC-20 contract
    constructor(address _pactToken) {
        require(_pactToken != address(0), "Escrow: zero token address");
        pactToken = IERC20(_pactToken);
    }

    // ──────────────────── Create ────────────────────────────

    /// @notice Create a new escrow pact. Caller must have approved this contract for `amount`.
    /// @param recipient  Agent who will do the work and receive tokens
    /// @param verifier   Agent who verifies completion. Use address(0) for self-verified pacts.
    /// @param amount     Number of PACT tokens to lock
    /// @param deadline   Unix timestamp after which creator can reclaim if incomplete
    /// @return pactId    The ID of the newly created pact
    function create(
        address recipient,
        address verifier,
        uint256 amount,
        uint256 deadline
    ) external returns (uint256 pactId) {
        require(recipient != address(0), "Escrow: zero recipient");
        require(amount > 0, "Escrow: zero amount");
        require(deadline > block.timestamp, "Escrow: deadline in past");

        pactId = nextPactId++;

        pacts[pactId] = Pact({
            creator:   msg.sender,
            recipient: recipient,
            verifier:  verifier,
            amount:    amount,
            deadline:  deadline,
            status:    Status.Active
        });

        // Pull tokens from creator into this contract
        require(pactToken.transferFrom(msg.sender, address(this), amount), "Escrow: transfer failed");

        emit PactCreated(pactId, msg.sender, recipient, verifier, amount, deadline);
    }

    // ──────────────────── Complete (self-verified) ──────────

    /// @notice Recipient marks work complete. If verifier is address(0), tokens release immediately.
    /// @param pactId The pact to complete
    function complete(uint256 pactId) external {
        Pact storage p = pacts[pactId];
        require(p.status == Status.Active, "Escrow: not active");
        require(msg.sender == p.recipient, "Escrow: not recipient");

        if (p.verifier == address(0)) {
            // Self-verified: release tokens immediately
            p.status = Status.Completed;
            require(pactToken.transfer(p.recipient, p.amount), "Escrow: release failed");
            emit PactCompleted(pactId, p.recipient);
        } else {
            // Needs verification — mark pending, don't release yet
            p.status = Status.PendingVerification;
            emit PactCompleted(pactId, p.recipient);
        }
    }

    // ──────────────────── Verify (third-party) ──────────────

    /// @notice Verifier confirms work is done and releases tokens to recipient.
    /// @param pactId The pact to verify
    function verify(uint256 pactId) external {
        Pact storage p = pacts[pactId];
        require(p.status == Status.PendingVerification, "Escrow: not pending verification");
        require(msg.sender == p.verifier, "Escrow: not verifier");

        p.status = Status.Completed;
        require(pactToken.transfer(p.recipient, p.amount), "Escrow: release failed");

        emit PactVerified(pactId, p.verifier);
    }

    // ──────────────────── Reclaim (deadline expired) ────────

    /// @notice Creator reclaims tokens after deadline passes without completion.
    /// @param pactId The pact to reclaim
    function reclaim(uint256 pactId) external {
        Pact storage p = pacts[pactId];
        require(p.status == Status.Active || p.status == Status.PendingVerification, "Escrow: not reclaimable");
        require(msg.sender == p.creator, "Escrow: not creator");
        require(block.timestamp > p.deadline, "Escrow: deadline not passed");

        p.status = Status.Reclaimed;
        require(pactToken.transfer(p.creator, p.amount), "Escrow: refund failed");

        emit PactReclaimed(pactId, p.creator);
    }
}
