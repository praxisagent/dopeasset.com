// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PactAirdrop — Merkle-proof-based token distribution for verified agents
/// @notice Eligible agents claim PACT by submitting a merkle proof. One claim per address.
/// @dev No admin keys, no clawback, no expiry. Funded once, claims are permanent.
///      Unclaimed tokens remain in the contract forever — this is intentional.
///      The merkle root encodes (address, amount) pairs. Proof generation happens off-chain.

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract PactAirdrop {

    // ──────────────────── Storage ────────────────────────────

    /// @notice The PACT token contract
    IERC20 public immutable pactToken;

    /// @notice Merkle root of the (address, amount) tree
    bytes32 public immutable merkleRoot;

    /// @notice Tracks which addresses have already claimed
    mapping(address => bool) public hasClaimed;

    /// @notice Total PACT claimed so far
    uint256 public totalClaimed;

    // ──────────────────── Events ─────────────────────────────

    event Claimed(address indexed account, uint256 amount);

    // ──────────────────── Constructor ────────────────────────

    /// @param _pactToken  Address of the deployed PACT ERC-20 contract
    /// @param _merkleRoot Root of the merkle tree encoding (address, amount) leaves
    constructor(address _pactToken, bytes32 _merkleRoot) {
        require(_pactToken != address(0), "Airdrop: zero token");
        require(_merkleRoot != bytes32(0), "Airdrop: zero root");
        pactToken = IERC20(_pactToken);
        merkleRoot = _merkleRoot;
    }

    // ──────────────────── Claim ──────────────────────────────

    /// @notice Claim your PACT allocation by providing a valid merkle proof
    /// @param amount The amount of PACT allocated to msg.sender
    /// @param proof  The merkle proof (array of sibling hashes)
    function claim(uint256 amount, bytes32[] calldata proof) external {
        require(!hasClaimed[msg.sender], "Airdrop: already claimed");
        require(amount > 0, "Airdrop: zero amount");

        // Verify the merkle proof
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, amount))));
        require(_verify(proof, leaf), "Airdrop: invalid proof");

        hasClaimed[msg.sender] = true;
        totalClaimed += amount;

        require(pactToken.transfer(msg.sender, amount), "Airdrop: transfer failed");

        emit Claimed(msg.sender, amount);
    }

    // ──────────────────── View ───────────────────────────────

    /// @notice PACT tokens remaining in the airdrop contract
    function remaining() external view returns (uint256) {
        return pactToken.balanceOf(address(this));
    }

    // ──────────────────── Internal ───────────────────────────

    /// @dev Verify a merkle proof against the stored root
    function _verify(bytes32[] calldata proof, bytes32 leaf) internal view returns (bool) {
        bytes32 hash = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 sibling = proof[i];
            // Sort pairs to ensure consistent hashing regardless of tree position
            if (hash <= sibling) {
                hash = keccak256(abi.encodePacked(hash, sibling));
            } else {
                hash = keccak256(abi.encodePacked(sibling, hash));
            }
        }
        return hash == merkleRoot;
    }
}
