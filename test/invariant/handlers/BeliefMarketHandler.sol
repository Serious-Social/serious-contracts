// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BeliefMarket} from "../../../src/BeliefMarket.sol";
import {BeliefVault} from "../../../src/BeliefVault.sol";
import {MockUSDC} from "../../../src/mock/MockUSDC.sol";
import {MarketParams, Position} from "../../../src/types/BeliefTypes.sol";

/// @notice Single handler over a fixed set of markets created in the test's setUp.
///         Every fuzzed action takes a seed that selects the market (and actor / position).
contract BeliefMarketHandler is Test {
    MockUSDC public usdc;
    BeliefVault public vault;
    BeliefMarket[] public markets;
    address[] public actors;

    /*//////////////////////////////////////////////////////////////
                           POSITION TRACKING
    //////////////////////////////////////////////////////////////*/

    /// @dev Every position ever opened per market (creator's #1 included). Withdrawn ones stay in.
    mapping(BeliefMarket => uint256[]) internal _positionIds;
    mapping(BeliefMarket => mapping(uint256 => address)) internal _ownerOf;

    /*//////////////////////////////////////////////////////////////
                             GHOST VARIABLES
    //////////////////////////////////////////////////////////////*/

    // TODO: per-market ghosts, e.g.
    // mapping(BeliefMarket => uint256) public ghost_...;

    /*//////////////////////////////////////////////////////////////
                              CALL COUNTERS
    //////////////////////////////////////////////////////////////*/

    mapping(bytes32 => uint256) public calls;

    modifier countCall(bytes32 key) {
        calls[key]++;
        _;
    }

    constructor(
        MockUSDC _usdc,
        BeliefVault _vault,
        BeliefMarket[] memory _markets,
        address[] memory _creators,
        address[] memory _actors
    ) {
        usdc = _usdc;
        vault = _vault;
        actors = _actors;
        for (uint256 i; i < _markets.length; i++) {
            markets.push(_markets[i]);
            // initialize() opened position 1 for the creator
            _trackPosition(_markets[i], 1, _creators[i]);
            // TODO: seed ghosts with the creator's commit (principal, creator premium)
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 ACTIONS
    //////////////////////////////////////////////////////////////*/

    function commit(uint256 marketSeed, uint256 actorSeed, uint256 amount, bool support) external countCall("commit") {
        BeliefMarket market = _market(marketSeed);
        address actor = _actor(actorSeed);
        MarketParams memory p = market.getMarketParams();
        amount = bound(amount, p.minStake, p.maxStake);

        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(vault), amount);
        uint256 positionId = support ? market.commitSupport(amount) : market.commitOppose(amount);
        vm.stopPrank();

        _trackPosition(market, positionId, actor);
        // TODO: ghost updates (gross in, entry fee to SRP, net principal)
    }

    function withdraw(uint256 marketSeed, uint256 positionSeed) external countCall("withdraw") {
        BeliefMarket market = _market(marketSeed);
        (uint256 positionId, address owner) = _position(market, positionSeed);
        Position memory pos = market.getPosition(positionId);
        if (pos.withdrawn) {
            calls["withdraw.skipped"]++;
            return;
        }

        // TODO: snapshot whatever you need before the call (early vs normal, pending rewards, balances)
        vm.prank(owner);
        market.withdraw(positionId);
        // TODO: ghost updates (principal out, penalty, auto-claimed or forfeited rewards)
    }

    function claimRewards(uint256 marketSeed, uint256 positionSeed) external countCall("claimRewards") {
        BeliefMarket market = _market(marketSeed);
        (uint256 positionId, address owner) = _position(market, positionSeed);

        // TODO: preconditions so this doesn't revert under fail_on_revert
        //       (see MinRewardDurationNotMet / NoRewardsToClaim in claimRewards)

        vm.prank(owner);
        uint256 claimed = market.claimRewards(positionId);
        // TODO: ghost updates
        claimed;
    }

    function warp(uint256 secs) external countCall("warp") {
        // TODO: choose a range that lets positions cross minRewardDuration and lockPeriod within `depth`
        secs = bound(secs, 1 hours, 10 days);
        vm.warp(block.timestamp + secs);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function marketsLength() external view returns (uint256) {
        return markets.length;
    }

    function positionIds(BeliefMarket market) external view returns (uint256[] memory) {
        return _positionIds[market];
    }

    function ownerOf(BeliefMarket market, uint256 positionId) external view returns (address) {
        return _ownerOf[market][positionId];
    }

    function _market(uint256 seed) internal view returns (BeliefMarket) {
        return markets[seed % markets.length];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Never empty: every market starts with the creator's position.
    function _position(BeliefMarket market, uint256 seed) internal view returns (uint256 id, address owner) {
        uint256[] storage ids = _positionIds[market];
        id = ids[seed % ids.length];
        owner = _ownerOf[market][id];
    }

    function _trackPosition(BeliefMarket market, uint256 positionId, address owner) internal {
        _positionIds[market].push(positionId);
        _ownerOf[market][positionId] = owner;
    }
}
