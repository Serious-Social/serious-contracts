// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IBeliefVault} from "./interfaces/IBeliefVault.sol";
import {ISeriousnessToken} from "./interfaces/ISeriousnessToken.sol";

/// @title SeriousnessToken
/// @notice Non-transferable (soulbound) ERC-20 reputation token for belief markets
/// @dev Accrues proportionally to stake amount and duration (1 SRS per USD-day)
contract SeriousnessToken is ERC20, ISeriousnessToken {
    /// @notice The vault that controls market registration
    address public immutable vault;

    /// @param vault_ The BeliefVault address (used to check registered markets)
    constructor(address vault_) ERC20("Seriousness", "SRS") {
        vault = vault_;
    }

    /// @inheritdoc ISeriousnessToken
    function mint(address to, uint256 amount) external {
        if (!IBeliefVault(vault).isMarketRegistered(msg.sender)) revert NotRegisteredMarket();
        _mint(to, amount);
    }

    /// @inheritdoc ISeriousnessToken
    function burn(address from, uint256 amount) external {
        if (!IBeliefVault(vault).isMarketRegistered(msg.sender)) revert NotRegisteredMarket();
        _burn(from, amount);
    }

    /// @dev Override _update to make the token soulbound (only mint and burn allowed)
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) revert TransferNotAllowed();
        super._update(from, to, value);
    }
}
