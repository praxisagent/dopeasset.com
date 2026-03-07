// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PACT — Trust infrastructure for autonomous agents
/// @notice Fixed-supply ERC-20 with EIP-2612 permit. No admin keys, no mint, no pause.
/// @dev Standalone implementation. Deploy with solc, verify on Arbiscan, trust the code.
contract PACT {

    // ──────────────────── ERC-20 Storage ────────────────────

    string public constant name     = "PACT";
    string public constant symbol   = "PACT";
    uint8  public constant decimals = 18;

    uint256 public constant totalSupply = 1_000_000_000e18; // 1 billion, fixed forever

    mapping(address => uint256)                      public balanceOf;
    mapping(address => mapping(address => uint256))  public allowance;

    // ──────────────────── EIP-2612 Storage ──────────────────

    /// @notice EIP-712 domain separator, computed once at construction
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @notice EIP-2612 permit typehash
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /// @notice Per-address nonce for permit replay protection
    mapping(address => uint256) public nonces;

    // ──────────────────── Events ────────────────────────────

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ──────────────────── Constructor ───────────────────────

    constructor() {
        // Entire supply to deployer. No further minting possible.
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    // ──────────────────── ERC-20 Core ───────────────────────

    /// @notice Transfer tokens to `to`
    function transfer(address to, uint256 value) external returns (bool) {
        return _transfer(msg.sender, to, value);
    }

    /// @notice Approve `spender` to spend `value` tokens on your behalf
    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /// @notice Transfer `value` tokens from `from` to `to`, consuming allowance
    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        // Infinite approval pattern: skip deduction if max uint256
        if (allowed != type(uint256).max) {
            require(allowed >= value, "PACT: allowance exceeded");
            unchecked { allowance[from][msg.sender] = allowed - value; }
        }
        return _transfer(from, to, value);
    }

    // ──────────────────── EIP-2612 Permit ───────────────────

    /// @notice Gasless approval via off-chain signature (EIP-2612)
    /// @param owner     Token holder granting approval
    /// @param spender   Address being approved
    /// @param value     Amount of tokens approved
    /// @param deadline  Unix timestamp after which the signature expires
    /// @param v         Recovery byte of the signature
    /// @param r         First 32 bytes of the signature
    /// @param s         Second 32 bytes of the signature
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(block.timestamp <= deadline, "PACT: permit expired");

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );

        address recovered = ecrecover(digest, v, r, s);
        require(recovered != address(0) && recovered == owner, "PACT: invalid signature");

        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    // ──────────────────── Internal ──────────────────────────

    function _transfer(address from, address to, uint256 value) internal returns (bool) {
        require(to != address(0), "PACT: transfer to zero address");
        require(balanceOf[from] >= value, "PACT: insufficient balance");

        unchecked {
            balanceOf[from] -= value;
            // totalSupply is fixed so balanceOf[to] can never overflow
            balanceOf[to] += value;
        }

        emit Transfer(from, to, value);
        return true;
    }
}
