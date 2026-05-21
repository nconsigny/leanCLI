// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title  SphincsAccountFactoryDev — Sepolia-only factory for hybrid ECDSA+SPHINCS- accounts
/// @notice This is a self-contained Sepolia-testing fallback. The canonical source for the
///         on-chain SphincsAccount design is the upstream
///         `nconsigny/SPHINCS-/src/SphincsAccountFactory.sol`. We re-implement the same
///         createAccount / getAddress shape here without account-abstraction or OpenZeppelin
///         dependencies so a forge build needs no extra `lib/` checkout. CREATE2 salt and
///         codeHash computation match upstream verbatim so a factory deployed here is
///         interchangeable with the upstream contract from the bundler's perspective.
contract SphincsAccountFactoryDev {
    address public immutable ENTRY_POINT;
    address public immutable VERIFIER;

    event AccountCreated(address indexed account, address indexed owner);

    constructor(address ep, address verifier) {
        require(block.chainid == 11155111, "Sepolia only");
        ENTRY_POINT = ep;
        VERIFIER = verifier;
    }

    function createAccount(address owner, bytes32 pkSeed, bytes32 pkRoot)
        external
        returns (SphincsAccountDev account)
    {
        bytes32 salt = keccak256(abi.encodePacked(owner, pkSeed, pkRoot));
        account = new SphincsAccountDev{salt: salt}(ENTRY_POINT, owner, VERIFIER, pkSeed, pkRoot);
        emit AccountCreated(address(account), owner);
    }

    function getAddress(address owner, bytes32 pkSeed, bytes32 pkRoot)
        external
        view
        returns (address)
    {
        bytes32 salt = keccak256(abi.encodePacked(owner, pkSeed, pkRoot));
        bytes32 codeHash = keccak256(
            abi.encodePacked(
                type(SphincsAccountDev).creationCode,
                abi.encode(ENTRY_POINT, owner, VERIFIER, pkSeed, pkRoot)
            )
        );
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash))
                )
            )
        );
    }
}

/// @notice Minimal hybrid ECDSA + SPHINCS- ERC-4337 account. Implements the
///         v0.9 `validateUserOp` callback inline (no BaseAccount import) and
///         delegates SPHINCS- verification to a shared on-chain verifier
///         contract via `staticcall`.
contract SphincsAccountDev {
    // Static EntryPoint + verifier baked in at deploy time.
    address public immutable ENTRY_POINT;
    address public immutable VERIFIER;

    // Mutable for key rotation.
    address public owner;
    bytes32 public pkSeed;
    bytes32 public pkRoot;

    error NotEntryPoint();
    error NotSelfOrEntryPoint();
    error ZeroAddress();

    constructor(
        address ep,
        address _owner,
        address _verifier,
        bytes32 _pkSeed,
        bytes32 _pkRoot
    ) {
        ENTRY_POINT = ep;
        VERIFIER = _verifier;
        owner = _owner;
        pkSeed = _pkSeed;
        pkRoot = _pkRoot;
    }

    /// @notice v0.9 ERC-4337 validation callback.
    /// @dev    Returns `0` on success and `1` on signature-validation failure,
    ///         matching the SIG_VALIDATION_SUCCESS / SIG_VALIDATION_FAILED
    ///         convention in `account-abstraction/core/Helpers.sol`.
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external returns (uint256 validationData) {
        if (msg.sender != ENTRY_POINT) revert NotEntryPoint();

        // Track validity locally; the prefund-payment step at the end MUST
        // run regardless of signature outcome. The canonical
        // `BaseAccount.validateUserOp` pattern from
        // eth-infinitism/account-abstraction does exactly this — bundlers
        // run `eth_estimateUserOperationGas` with a DUMMY signature, and
        // expect the account to still pay prefund so the simulator can
        // measure verification gas. An early return that skips prefund
        // surfaces to the bundler as `AA21 didn't pay prefund`, even when
        // the on-chain failure mode is "bad sig".
        validationData = 0;

        // 1) Decode the hybrid signature: abi.encode(bytes ecdsaSig, bytes sphincsSig).
        // Wrap in try/catch via low-level call would be ideal; using direct
        // abi.decode here would revert on a malformed dummy sig. The dummy
        // shape we expect from estimators is well-formed (just zero-filled),
        // so a plain decode is safe.
        (bytes memory ecdsaSig, bytes memory sphincsSig) =
            abi.decode(userOp.signature, (bytes, bytes));

        // 2) ECDSA recover and equality check against the rotatable owner.
        address recovered = _recover(userOpHash, ecdsaSig);
        if (recovered != owner) {
            validationData = 1;
        } else {
            // 3) SPHINCS- via shared verifier (staticcall to avoid storage writes).
            (bool ok, bytes memory result) = VERIFIER.staticcall(
                abi.encodeWithSignature(
                    "verify(bytes32,bytes32,bytes32,bytes)",
                    pkSeed,
                    pkRoot,
                    userOpHash,
                    sphincsSig
                )
            );
            if (!ok || result.length < 32 || !abi.decode(result, (bool))) {
                validationData = 1;
            }
        }

        // 4) Pre-fund the EntryPoint with any missing gas — UNCONDITIONAL.
        if (missingAccountFunds > 0) {
            (bool sent, ) = msg.sender.call{value: missingAccountFunds}("");
            (sent); // ignore — failure here surfaces as out-of-gas downstream
        }
    }

    function execute(address target, uint256 value, bytes calldata data) external {
        if (msg.sender != ENTRY_POINT) revert NotEntryPoint();
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function rotateKeys(bytes32 newPkSeed, bytes32 newPkRoot) external {
        if (msg.sender != address(this) && msg.sender != ENTRY_POINT) revert NotSelfOrEntryPoint();
        pkSeed = newPkSeed;
        pkRoot = newPkRoot;
    }

    function rotateOwner(address newOwner) external {
        if (msg.sender != address(this) && msg.sender != ENTRY_POINT) revert NotSelfOrEntryPoint();
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    function _recover(bytes32 hash, bytes memory sig) internal pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        if (v < 27) v += 27;
        return ecrecover(hash, v, r, s);
    }

    receive() external payable {}
}

/// @notice v0.9 PackedUserOperation — mirrors the EntryPoint's struct so the
///         on-chain ABI decoders line up. Keep field order identical.
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}
