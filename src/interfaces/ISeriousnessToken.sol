// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ISeriousnessToken
/// @notice Interface for the soulbound reputation token minted by belief markets
interface ISeriousnessToken {
    /// @notice Thrown when a transfer is attempted (token is soulbound)
    error TransferNotAllowed();

    /// @notice Thrown when caller is not a registered market
    error NotRegisteredMarket();

    /// @notice Mint reputation tokens to a user (only callable by registered markets)
    /// @param to The recipient address
    /// @param amount The amount to mint
    function mint(address to, uint256 amount) external;

    /// @notice Burn reputation tokens from a user (only callable by registered markets)
    /// @param from The address to burn from
    /// @param amount The amount to burn
    function burn(address from, uint256 amount) external;

    /// @notice Get the vault address
    /// @return The vault that controls market registration
    function vault() external view returns (address);
}
