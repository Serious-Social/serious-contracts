// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBeliefVault} from "./interfaces/IBeliefVault.sol";

/// @title BeliefVault
/// @notice Centralized USDC custody for all belief markets
/// @dev Per-market balance isolation prevents a compromised market from draining others
contract BeliefVault is IBeliefVault, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The factory that deployed this vault
    address public immutable factory;

    /// @notice The USDC token
    IERC20 private immutable _usdc;

    /// @notice Whether a market is registered
    mapping(address => bool) private _registeredMarkets;

    /// @notice Per-market USDC balance tracking
    mapping(address => uint256) private _marketBalances;

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier onlyRegisteredMarket() {
        if (!_registeredMarkets[msg.sender]) revert NotRegisteredMarket();
        _;
    }

    /// @notice Deploy the vault
    /// @param factory_ The factory address
    /// @param usdc_ The USDC token address
    constructor(address factory_, address usdc_) {
        factory = factory_;
        _usdc = IERC20(usdc_);
    }

    /// @inheritdoc IBeliefVault
    function registerMarket(address market) external onlyFactory {
        if (_registeredMarkets[market]) revert MarketAlreadyRegistered();
        _registeredMarkets[market] = true;
        emit MarketRegistered(market);
    }

    /// @inheritdoc IBeliefVault
    function pauseVault() external onlyFactory {
        _pause();
    }

    /// @inheritdoc IBeliefVault
    function unpauseVault() external onlyFactory {
        _unpause();
    }

    /// @inheritdoc IBeliefVault
    function lockForMarket(address user, uint256 amount) external onlyRegisteredMarket whenNotPaused nonReentrant {
        _usdc.safeTransferFrom(user, address(this), amount);
        _marketBalances[msg.sender] += amount;
        emit Locked(msg.sender, user, amount);
    }

    /// @inheritdoc IBeliefVault
    function releaseFromMarket(address user, uint256 amount) external onlyRegisteredMarket nonReentrant {
        if (_marketBalances[msg.sender] < amount) revert InsufficientMarketBalance();
        _marketBalances[msg.sender] -= amount;
        _usdc.safeTransfer(user, amount);
        emit Released(msg.sender, user, amount);
    }

    /// @inheritdoc IBeliefVault
    function usdc() external view returns (address) {
        return address(_usdc);
    }

    /// @inheritdoc IBeliefVault
    function marketBalance(address market) external view returns (uint256) {
        return _marketBalances[market];
    }

    /// @inheritdoc IBeliefVault
    function isMarketRegistered(address market) external view returns (bool) {
        return _registeredMarkets[market];
    }
}
