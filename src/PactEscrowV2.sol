// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PactEscrow v2 — Trustless service agreements between autonomous agents
/// @notice Adversarially reviewed. Threat model: /opt/praxis/contracts/escrow-v2-threat-model.md
///
/// KEY DIFFERENCES FROM v1:
///  - No self-verified mode. All releases require creator approval or timeout.
///  - Work submission starts a dispute clock, not instant payment.
///  - Creator CANNOT reclaim once work is submitted. This is the core v1 fix.
///  - Arbitration is opt-in, set at creation time by mutual agreement.
///  - Arbitrator timeout defaults to recipient (prevents arbitrator griefing).
///  - Anyone can trigger timeout-based releases (resilient to agent restarts).

interface IERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

contract PactEscrowV2 {

    // ──────────────────── Constants ─────────────────────────────

    /// @notice Minimum time creator has to dispute after work submitted (1 hour)
    uint256 public constant MIN_DISPUTE_WINDOW = 3600;

    /// @notice Minimum time arbitrator has to rule after dispute raised (24 hours)
    uint256 public constant MIN_ARBITRATION_WINDOW = 86400;

    // ──────────────────── Types ─────────────────────────────────

    enum Status {
        Active,          // Tokens locked, waiting for work
        WorkSubmitted,   // Recipient submitted evidence, dispute window running
        Disputed,        // Creator disputed, arbitration running
        Complete,        // Recipient received tokens (work accepted)
        Refunded         // Creator received tokens back (reclaimed or arbitration loss)
    }

    struct Pact {
        address creator;
        address recipient;
        address arbitrator;          // address(0) = no arbitration capability
        uint256 amount;              // Total PACT tokens locked
        uint256 arbitratorFee;       // Paid to arbitrator if arbitration invoked (from amount)
        uint256 deadline;            // Unix timestamp: work must be submitted before this
        uint256 disputeWindow;       // Seconds creator has to dispute after work submitted
        uint256 arbitrationWindow;   // Seconds arbitrator has to rule after dispute raised
        uint256 workSubmittedAt;     // Timestamp when submitWork() was called
        uint256 disputeRaisedAt;     // Timestamp when dispute() was called
        bytes32 workHash;            // Commitment to off-chain evidence (IPFS CID, commit hash, etc.)
        Status  status;
    }

    // ──────────────────── Storage ───────────────────────────────

    IERC20 public immutable pactToken;

    uint256 public nextPactId;

    mapping(uint256 => Pact) public pacts;

    // ──────────────────── Events ────────────────────────────────

    event PactCreated(
        uint256 indexed pactId,
        address indexed creator,
        address indexed recipient,
        address arbitrator,
        uint256 amount,
        uint256 arbitratorFee,
        uint256 deadline,
        uint256 disputeWindow,
        uint256 arbitrationWindow
    );

    event WorkSubmitted(uint256 indexed pactId, address indexed recipient, bytes32 workHash);
    event PactApproved(uint256 indexed pactId, address indexed creator);
    event PactDisputed(uint256 indexed pactId, address indexed creator);
    event ArbitrationRuled(uint256 indexed pactId, address indexed arbitrator, bool favorRecipient);
    event PactReleased(uint256 indexed pactId, address indexed recipient, uint256 amount);
    event PactRefunded(uint256 indexed pactId, address indexed creator, uint256 amount);
    event ArbitrationFinalized(uint256 indexed pactId);

    // ──────────────────── Constructor ───────────────────────────

    constructor(address _pactToken) {
        require(_pactToken != address(0), "EscrowV2: zero token address");
        pactToken = IERC20(_pactToken);
    }

    // ──────────────────── Create ────────────────────────────────

    /// @notice Create a new escrow pact.
    /// @param recipient         Agent who does the work
    /// @param arbitrator        Agent who resolves disputes. address(0) = no dispute capability.
    /// @param amount            PACT tokens to lock (must have approved this contract)
    /// @param arbitratorFee     Paid to arbitrator from `amount` if invoked. Must be 0 if no arbitrator.
    /// @param deadline          Work must be submitted before this timestamp
    /// @param disputeWindow     Seconds creator has to dispute after work submitted (>= 1 hour)
    /// @param arbitrationWindow Seconds arbitrator has to rule after dispute raised (>= 24 hours)
    function create(
        address recipient,
        address arbitrator,
        uint256 amount,
        uint256 arbitratorFee,
        uint256 deadline,
        uint256 disputeWindow,
        uint256 arbitrationWindow
    ) external returns (uint256 pactId) {
        require(recipient != address(0), "EscrowV2: zero recipient");
        require(msg.sender != recipient, "EscrowV2: creator cannot be recipient");
        require(amount > 0, "EscrowV2: zero amount");
        require(deadline > block.timestamp, "EscrowV2: deadline in past");
        require(disputeWindow >= MIN_DISPUTE_WINDOW, "EscrowV2: dispute window too short");

        if (arbitrator == address(0)) {
            // No arbitration: fee must be zero
            require(arbitratorFee == 0, "EscrowV2: fee without arbitrator");
            // arbitrationWindow is irrelevant but we allow any value (it won't be used)
        } else {
            require(arbitrator != msg.sender, "EscrowV2: arbitrator cannot be creator");
            require(arbitrator != recipient, "EscrowV2: arbitrator cannot be recipient");
            // Fee cannot exceed half the locked amount (T12 protection)
            // arbitratorFee <= amount/2 means winner always gets at least as much as the fee
            require(arbitratorFee <= amount / 2, "EscrowV2: fee too high (max 50%)");
            require(arbitrationWindow >= MIN_ARBITRATION_WINDOW, "EscrowV2: arbitration window too short");
        }

        pactId = nextPactId++;

        pacts[pactId] = Pact({
            creator:           msg.sender,
            recipient:         recipient,
            arbitrator:        arbitrator,
            amount:            amount,
            arbitratorFee:     arbitratorFee,
            deadline:          deadline,
            disputeWindow:     disputeWindow,
            arbitrationWindow: arbitrationWindow,
            workSubmittedAt:   0,
            disputeRaisedAt:   0,
            workHash:          bytes32(0),
            status:            Status.Active
        });

        // Checks-effects-interactions: state written before external call
        require(pactToken.transferFrom(msg.sender, address(this), amount), "EscrowV2: transfer failed");

        emit PactCreated(
            pactId, msg.sender, recipient, arbitrator,
            amount, arbitratorFee, deadline, disputeWindow, arbitrationWindow
        );
    }

    // ──────────────────── Submit Work ───────────────────────────

    /// @notice Recipient submits evidence of completion. Starts the dispute window.
    /// @param pactId    The pact to mark as work submitted
    /// @param workHash  bytes32 commitment to off-chain evidence (IPFS CID, commit SHA, URL hash, etc.)
    function submitWork(uint256 pactId, bytes32 workHash) external {
        Pact storage p = pacts[pactId];
        require(p.status == Status.Active, "EscrowV2: not active");
        require(msg.sender == p.recipient, "EscrowV2: not recipient");
        require(block.timestamp <= p.deadline, "EscrowV2: deadline passed");

        // State change before any potential callbacks
        p.status = Status.WorkSubmitted;
        p.workSubmittedAt = block.timestamp;
        p.workHash = workHash;

        emit WorkSubmitted(pactId, msg.sender, workHash);
    }

    // ──────────────────── Approve (creator accepts work) ────────

    /// @notice Creator accepts the submitted work and releases tokens immediately.
    /// @param pactId The pact to approve
    function approve(uint256 pactId) external {
        Pact storage p = pacts[pactId];
        require(p.status == Status.WorkSubmitted, "EscrowV2: not in WorkSubmitted");
        require(msg.sender == p.creator, "EscrowV2: not creator");

        address recipient = p.recipient;
        uint256 amount = p.amount;

        p.status = Status.Complete;

        require(pactToken.transfer(recipient, amount), "EscrowV2: release failed");

        emit PactApproved(pactId, msg.sender);
        emit PactReleased(pactId, recipient, amount);
    }

    // ──────────────────── Dispute (creator contests work) ───────

    /// @notice Creator disputes the submitted work and invokes arbitration.
    ///         Requires arbitrator != address(0) to have been set at creation.
    ///         Must be called within the dispute window.
    /// @param pactId The pact to dispute
    function dispute(uint256 pactId) external {
        Pact storage p = pacts[pactId];
        require(p.status == Status.WorkSubmitted, "EscrowV2: not in WorkSubmitted");
        require(msg.sender == p.creator, "EscrowV2: not creator");
        require(p.arbitrator != address(0), "EscrowV2: no arbitrator set");
        require(
            block.timestamp <= p.workSubmittedAt + p.disputeWindow,
            "EscrowV2: dispute window has closed"
        );

        p.status = Status.Disputed;
        p.disputeRaisedAt = block.timestamp;

        emit PactDisputed(pactId, msg.sender);
    }

    // ──────────────────── Release (dispute window elapsed) ──────

    /// @notice Releases tokens to recipient after dispute window expires without dispute.
    ///         Callable by anyone — recipient doesn't need to be online at this exact moment.
    /// @param pactId The pact to release
    function release(uint256 pactId) external {
        Pact storage p = pacts[pactId];
        require(p.status == Status.WorkSubmitted, "EscrowV2: not in WorkSubmitted");
        require(
            block.timestamp > p.workSubmittedAt + p.disputeWindow,
            "EscrowV2: dispute window still open"
        );

        address recipient = p.recipient;
        uint256 amount = p.amount;

        p.status = Status.Complete;

        require(pactToken.transfer(recipient, amount), "EscrowV2: release failed");

        emit PactReleased(pactId, recipient, amount);
    }

    // ──────────────────── Rule (arbitrator decides) ─────────────

    /// @notice Arbitrator rules on the dispute.
    /// @param pactId          The disputed pact
    /// @param favorRecipient  true = recipient wins, false = creator wins
    function rule(uint256 pactId, bool favorRecipient) external {
        Pact storage p = pacts[pactId];
        require(p.status == Status.Disputed, "EscrowV2: not disputed");
        require(msg.sender == p.arbitrator, "EscrowV2: not arbitrator");
        require(
            block.timestamp <= p.disputeRaisedAt + p.arbitrationWindow,
            "EscrowV2: arbitration window closed"
        );

        address arbitrator = p.arbitrator;
        uint256 fee = p.arbitratorFee;
        uint256 remainder = p.amount - fee;

        if (favorRecipient) {
            address recipient = p.recipient;
            p.status = Status.Complete;

            if (fee > 0) require(pactToken.transfer(arbitrator, fee), "EscrowV2: fee transfer failed");
            require(pactToken.transfer(recipient, remainder), "EscrowV2: recipient release failed");

            emit ArbitrationRuled(pactId, arbitrator, true);
            emit PactReleased(pactId, recipient, remainder);
        } else {
            address creator = p.creator;
            p.status = Status.Refunded;

            if (fee > 0) require(pactToken.transfer(arbitrator, fee), "EscrowV2: fee transfer failed");
            require(pactToken.transfer(creator, remainder), "EscrowV2: creator refund failed");

            emit ArbitrationRuled(pactId, arbitrator, false);
            emit PactRefunded(pactId, creator, remainder);
        }
    }

    // ──────────────────── Finalize Arbitration (timeout) ────────

    /// @notice If arbitrator doesn't rule in time, anyone can finalize and release to recipient.
    ///         Arbitrator forfeits their fee by inaction. Full amount goes to recipient.
    ///         Callable by anyone — resilient to agent restarts.
    /// @param pactId The disputed pact to finalize
    function finalizeArbitration(uint256 pactId) external {
        Pact storage p = pacts[pactId];
        require(p.status == Status.Disputed, "EscrowV2: not disputed");
        require(
            block.timestamp > p.disputeRaisedAt + p.arbitrationWindow,
            "EscrowV2: arbitration window still open"
        );

        address recipient = p.recipient;
        uint256 amount = p.amount; // Arbitrator gets nothing for not acting

        p.status = Status.Complete;

        require(pactToken.transfer(recipient, amount), "EscrowV2: release failed");

        emit ArbitrationFinalized(pactId);
        emit PactReleased(pactId, recipient, amount);
    }

    // ──────────────────── Reclaim (deadline, no work) ───────────

    /// @notice Creator reclaims tokens after deadline passes without work being submitted.
    ///         Only valid from Active state — cannot reclaim after work is submitted.
    ///         This is the core v1 fix: creator cannot reclaim once recipient has acted.
    /// @param pactId The pact to reclaim
    function reclaim(uint256 pactId) external {
        Pact storage p = pacts[pactId];
        require(p.status == Status.Active, "EscrowV2: work already submitted");
        require(msg.sender == p.creator, "EscrowV2: not creator");
        require(block.timestamp > p.deadline, "EscrowV2: deadline not passed");

        address creator = p.creator;
        uint256 amount = p.amount;

        p.status = Status.Refunded;

        require(pactToken.transfer(creator, amount), "EscrowV2: refund failed");

        emit PactRefunded(pactId, creator, amount);
    }

    // ──────────────────── View ───────────────────────────────────

    /// @notice Returns full pact details
    function getPact(uint256 pactId) external view returns (Pact memory) {
        return pacts[pactId];
    }

    /// @notice Returns true if the dispute window has elapsed without a dispute being raised
    function isReleaseable(uint256 pactId) external view returns (bool) {
        Pact storage p = pacts[pactId];
        return p.status == Status.WorkSubmitted &&
               block.timestamp > p.workSubmittedAt + p.disputeWindow;
    }

    /// @notice Returns true if arbitration has timed out and finalizeArbitration() can be called
    function isArbitrationTimedOut(uint256 pactId) external view returns (bool) {
        Pact storage p = pacts[pactId];
        return p.status == Status.Disputed &&
               block.timestamp > p.disputeRaisedAt + p.arbitrationWindow;
    }
}
