// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @notice Temporary Sepolia-only R1 account for TPM P-256 testing.
/// @dev This is NOT the canonical contract source. The source of truth is
/// `Contracts/R1Account/R1Account.lean`; this fallback exists only until the
/// Verity compile path is wired.
contract R1AccountDev {
    bytes32 public immutable QX;
    bytes32 public immutable QY;
    uint256 public nonce;

    event Executed(address indexed target, uint256 value, bytes32 digest);

    constructor(bytes32 qx_, bytes32 qy_) payable {
        require(block.chainid == 11155111, "R1AccountDev: Sepolia only");
        QX = qx_;
        QY = qy_;
    }

    receive() external payable {}

    function digestFor(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 nonce_
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                "leanCLI.r1.sepolia.execute",
                address(this),
                block.chainid,
                nonce_,
                target,
                value,
                keccak256(data)
            )
        );
    }

    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 r,
        bytes32 s
    ) external returns (bytes memory result) {
        bytes32 digest = digestFor(target, value, data, nonce);
        require(_verifyP256(digest, r, s), "R1AccountDev: invalid P-256 signature");

        unchecked {
            nonce += 1;
        }

        (bool ok, bytes memory out) = target.call{value: value}(data);
        require(ok, "R1AccountDev: target call failed");
        emit Executed(target, value, digest);
        return out;
    }

    function _verifyP256(bytes32 h, bytes32 r, bytes32 s) internal view returns (bool) {
        bytes memory input = abi.encodePacked(h, r, s, QX, QY);
        bytes memory output = new bytes(32);
        bool ok;
        uint256 word;

        assembly {
            ok := staticcall(6900, 0x100, add(input, 0x20), 160, add(output, 0x20), 32)
            word := mload(add(output, 0x20))
        }

        return ok && output.length == 32 && word == 1;
    }
}
