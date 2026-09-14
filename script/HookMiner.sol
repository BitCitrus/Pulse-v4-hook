// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title HookMiner
/// @notice Utility for finding a CREATE2 salt that produces a hook address with the required
///         permission bits set in its lower 14 bits.
///         Used in deployment scripts and tests.
library HookMiner {
    /// @notice Find a CREATE2 salt such that the resulting hook address satisfies the permission flags.
    /// @param deployer     The account actually executing CREATE2 (the factory during broadcast)
    /// @param flags        Required lower-14-bit mask (e.g. 0x10C4 for PulseV4Hook)
    /// @param creationCode The contract's creation code (type(Hook).creationCode)
    /// @param constructorArgs ABI-encoded constructor arguments
    /// @param startNonce   Starting nonce for the search loop
    /// @return hookAddress The mined hook address
    /// @return salt        The corresponding CREATE2 salt
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs,
        uint256 startNonce
    ) internal pure returns (address hookAddress, bytes32 salt) {
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        bytes32 initcodeHash = keccak256(bytecode);
        uint160 mask = 0x3FFF; // lower 14 bits

        uint256 nonce = startNonce;
        while (true) {
            salt = bytes32(nonce);
            hookAddress = _computeCreate2Address(deployer, salt, initcodeHash);
            if (uint160(hookAddress) & mask == flags) break;
            unchecked {
                nonce++;
            }
        }
    }

    function _computeCreate2Address(address deployer, bytes32 salt, bytes32 initcodeHash)
        private
        pure
        returns (address)
    {
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initcodeHash)))
            )
        );
    }

    /// @notice Deploy through the deterministic deployment proxy using salt || initcode.
    /// @dev Calling the factory explicitly makes the mining and broadcast deployer identical.
    function deploy(address factory, bytes32 salt, bytes memory initcode)
        internal
        returns (address deployed)
    {
        require(factory.code.length != 0, "Deploy: CREATE2 factory missing");
        (bool ok, bytes memory result) = factory.call(abi.encodePacked(salt, initcode));
        require(ok && result.length == 20, "Deploy: CREATE2 failed");
        deployed = address(bytes20(result));
        require(
            deployed == _computeCreate2Address(factory, salt, keccak256(initcode))
                && deployed.code.length != 0,
            "Deploy: address mismatch"
        );
    }
}
