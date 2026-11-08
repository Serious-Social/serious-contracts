// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BeliefMarket} from "../../../src/BeliefMarket.sol";
import {BeliefVault} from "../../../src/BeliefVault.sol";
import {IBeliefMarket} from "../../../src/interfaces/IBeliefMarket.sol";
import {MockUSDC} from "../../../src/mock/MockUSDC.sol";
import {MarketParams, Position, Side} from "../../../src/types/BeliefTypes.sol";

/// @title BeliefMarketHandler
/// @notice The fuzzer's only way into the system. Markets are created in the test's setUp.
///
/// HOW IT WORKS
/// - Foundry calls these functions in random order with random arguments, then checks every
///   invariant after each call.
/// - Each function turns random inputs into a VALID action: a real market, a real actor, an open
///   position, an in-range amount. Random input then exercises logic instead of hitting input checks.
/// - fail_on_revert = true (foundry.toml): any revert fails the run. So each function skips the
///   reverts that are legal, and an assertEq inside a function is a real check.
///
/// GHOST VARIABLES
/// - The handler's own record of what happened, built from USDC it SAW MOVE (balance before/after),
///   not from the contract's internal numbers.
/// - The invariants compare the contract against these. A bug that keeps the contract's books
///   internally consistent but moves the wrong amount of money still gets caught.
contract BeliefMarketHandler is Test {
    MockUSDC public usdc;
    BeliefVault public vault;
    BeliefMarket[] public markets;
    address[] public actors;

    /// @dev An early exit goes through 1 in EARLY_EXIT_ODDS attempts (see withdraw).
    ///      Without this, positions were withdrawn before maturing and normal withdraws were rare.
    uint256 constant EARLY_EXIT_ODDS = 2;

    /*//////////////////////////////////////////////////////////////
                           POSITION TRACKING
    //////////////////////////////////////////////////////////////*/

    /// @dev Every position ever opened per market (creator's #1 included). Withdrawn ones stay in.
    ///      Used by invariants that need to look at all positions.
    mapping(BeliefMarket => uint256[]) internal _positionIds;
    mapping(BeliefMarket => mapping(uint256 => address)) internal _ownerOf;

    /// @dev Positions not yet withdrawn; withdraw/claimRewards pick from here so calls aren't wasted.
    ///      Index is stored +1 so 0 means "not open" (swap-and-pop removal).
    mapping(BeliefMarket => uint256[]) internal _openPositionIds;
    mapping(BeliefMarket => mapping(uint256 => uint256)) internal _openIndexPlusOne;

    /*//////////////////////////////////////////////////////////////
                             GHOST VARIABLES
    //////////////////////////////////////////////////////////////*/

    // Money flow per market:
    //   USDC in  = grossIn                              -> net principal (pools) + fees/premium (SRP)
    //   SRP in   = creatorPremium + entryFees + penalties
    //   USDC out = principalReturned + claimedRewards

    // Running totals; these only ever go up
    mapping(BeliefMarket => uint256) public ghost_grossIn; // USDC pulled from stakers, creator's commit included (before fees/premium)
    mapping(BeliefMarket => uint256) public ghost_totalEntryFees; // late-entry fees routed to SRP
    mapping(BeliefMarket => uint256) public ghost_creatorPremium; // creator premium routed to SRP (fixed at market creation)
    mapping(BeliefMarket => uint256) public ghost_totalPenalties; // early-withdraw penalties routed to SRP (0 when waived)
    mapping(BeliefMarket => uint256) public ghost_totalClaimedRewards; // rewards paid out, incl. auto-claim on normal withdraw
    mapping(BeliefMarket => uint256) public ghost_principalReturned; // principal paid back to users (net of penalties)

    // Current state; goes up on commit, down on withdraw
    mapping(BeliefMarket => mapping(Side => uint256)) public ghost_openPrincipal; // net principal of non-withdrawn positions

    /*//////////////////////////////////////////////////////////////
                              CALL COUNTERS
    //////////////////////////////////////////////////////////////*/

    /// @dev How many calls took each path (e.g. "withdraw.early"). Logged in afterInvariant to show
    ///      every path is reached. Also used for the SRP rounding-dust bound.
    mapping(bytes32 => uint256) public calls;

    modifier countCall(bytes32 key) {
        calls[key]++;
        _;
    }

    /// @dev The ghosts must start from the state setUp left behind: each market already holds its
    ///      creator's commit. The premium is computed from the params, not read back from the contract.
    constructor(
        MockUSDC _usdc,
        BeliefVault _vault,
        BeliefMarket[] memory _markets,
        address[] memory _creators,
        uint256[] memory _creatorCommitments,
        Side[] memory _creatorSides,
        address[] memory _actors
    ) {
        usdc = _usdc;
        vault = _vault;
        actors = _actors;
        for (uint256 i; i < _markets.length; i++) {
            BeliefMarket market = _markets[i];
            markets.push(market);
            // initialize() opened position 1 for the creator
            _trackPosition(market, 1, _creators[i]);

            // Creator's commit: premium is deducted from the commitment, no late-entry fee
            uint256 gross = _creatorCommitments[i];
            uint256 premium = gross * market.getMarketParams().creatorPremiumBps / 10_000;
            ghost_grossIn[market] = gross;
            ghost_creatorPremium[market] = premium;
            ghost_openPrincipal[market][_creatorSides[i]] = gross - premium;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice A random actor stakes a random in-range amount on a random side.
    /// @dev Also checks the late-entry fee against the spec formula. The expected fee is worked out
    ///      BEFORE the call from ghost state, so it doesn't depend on the contract's own fee code.
    function commit(uint256 marketSeed, uint256 actorSeed, uint256 amount, bool support) external countCall("commit") {
        BeliefMarket market = _market(marketSeed);
        address actor = _actor(actorSeed);
        MarketParams memory p = market.getMarketParams();
        amount = bound(amount, p.minStake, p.maxStake); // out-of-range amounts would just revert
        uint256 expectedFee = _expectedEntryFee(market, p, amount);

        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(vault), amount);
        uint256 positionId = support ? market.commitSupport(amount) : market.commitOppose(amount);
        vm.stopPrank();

        _trackPosition(market, positionId, actor);
        ghost_grossIn[market] += amount;
        uint256 positionAmount = market.getPosition(positionId).amount;
        ghost_openPrincipal[market][support ? Side.Support : Side.Oppose] += positionAmount; // net of entry fee
        uint256 entryFee = amount - positionAmount;
        assertEq(entryFee, expectedFee, "entry fee != spec formula");
        ghost_totalEntryFees[market] += entryFee;
    }

    /// @notice Withdraw a random open position: normal if its lock has expired, early otherwise.
    /// @dev The USDC the owner receives means different things on each path:
    ///        early:  received = amount - penalty   (pending rewards are forfeited and stay in the SRP)
    ///        normal: received = amount + rewards   (normal withdraw auto-claims)
    ///      The penalty is measured, not computed as amount x bps, because the contract waives it
    ///      when no weight remains. Both subtractions below double as checks: if an early exit paid
    ///      rewards, or a normal exit shorted the principal, the subtraction underflows, the call
    ///      reverts, and fail_on_revert fails the run.
    function withdraw(uint256 marketSeed, uint256 positionSeed) external countCall("withdraw") {
        BeliefMarket market = _market(marketSeed);
        (bool found, uint256 positionId, address owner) = _openPosition(market, positionSeed);
        if (!found) {
            calls["withdraw.noOpenPositions"]++;
            return;
        }
        Position memory pos = market.getPosition(positionId);
        assertFalse(pos.withdrawn, "handler: open list holds a withdrawn position");

        bool early = block.timestamp < pos.unlockTimestamp;
        // Let positions mature: early exits go through 1 in EARLY_EXIT_ODDS attempts, matured ones always.
        // Hashed: the fuzzer favours small/edge-case seeds, so raw seed bits are far from uniform.
        if (early && uint256(keccak256(abi.encode(positionSeed))) % EARLY_EXIT_ODDS != 0) {
            calls["withdraw.heldEarly"]++;
            return;
        }

        uint256 balanceBefore = usdc.balanceOf(owner);
        vm.prank(owner);
        market.withdraw(positionId);
        uint256 received = usdc.balanceOf(owner) - balanceBefore;

        _untrackOpen(market, positionId);
        ghost_openPrincipal[market][pos.side] -= pos.amount;
        if (early) {
            // received = principal - penalty; pending rewards are forfeited (they stay in the SRP)
            ghost_principalReturned[market] += received;
            ghost_totalPenalties[market] += pos.amount - received;
            calls["withdraw.early"]++;
        } else {
            // received = full principal + auto-claimed rewards
            ghost_principalReturned[market] += pos.amount;
            ghost_totalClaimedRewards[market] += received - pos.amount;
            calls["withdraw.normal"]++;
        }
    }

    /// @notice Claim rewards on a random open position.
    /// @dev Two reverts are legal and must not fail the run:
    ///        MinRewardDurationNotMet: checked up front and skipped.
    ///        NoRewardsToClaim:        caught. Any OTHER revert is re-thrown, so it still fails the run.
    ///      Also checks that the USDC actually received equals what claimRewards() reports.
    function claimRewards(uint256 marketSeed, uint256 positionSeed) external countCall("claimRewards") {
        BeliefMarket market = _market(marketSeed);
        (bool found, uint256 positionId, address owner) = _openPosition(market, positionSeed);
        if (!found) {
            calls["claimRewards.noOpenPositions"]++;
            return;
        }

        Position memory pos = market.getPosition(positionId);
        if (block.timestamp < pos.depositTimestamp + market.getMarketParams().minRewardDuration) {
            calls["claimRewards.tooEarly"]++;
            return;
        }

        // Not guarded with pendingRewards(): that view skips the unallocated-SRP flush that
        // claimRewards() performs first, so it can read 0 when the claim would pay.
        uint256 balanceBefore = usdc.balanceOf(owner);
        vm.prank(owner);
        try market.claimRewards(positionId) returns (uint256 claimed) {
            uint256 received = usdc.balanceOf(owner) - balanceBefore;
            assertEq(received, claimed, "claimRewards: USDC received != return value");
            ghost_totalClaimedRewards[market] += received;
            calls["claimRewards.paid"]++;
        } catch (bytes memory err) {
            if (bytes4(err) != IBeliefMarket.NoRewardsToClaim.selector) {
                // Re-throw the original revert data unchanged
                assembly {
                    revert(add(err, 32), mload(err))
                }
            }
            calls["claimRewards.nothing"]++;
        }
    }

    /// @notice Move time forward 1 hour to 10 days.
    /// @dev About 25 warps per 100-call run comes to ~4 months, so positions regularly pass
    ///      minRewardDuration (7 days) and lockPeriod (30 days). Without warps every exit would be early.
    function warp(uint256 secs) external countCall("warp") {
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

    function openPositionIds(BeliefMarket market) external view returns (uint256[] memory) {
        return _openPositionIds[market];
    }

    function ownerOf(BeliefMarket market, uint256 positionId) external view returns (address) {
        return _ownerOf[market][positionId];
    }

    function _market(uint256 seed) internal view returns (BeliefMarket) {
        return markets[seed % markets.length];
    }

    /// @dev Spec §7, from ghost state rather than the market's pools:
    ///      feeBps = min(baseFee + totalPrincipal / scale, maxFee), and no fee when the market is empty.
    ///      Written from the spec, not copied from the contract, so a contract bug isn't copied too.
    function _expectedEntryFee(BeliefMarket market, MarketParams memory p, uint256 amount)
        internal
        view
        returns (uint256)
    {
        uint256 total = ghost_openPrincipal[market][Side.Support] + ghost_openPrincipal[market][Side.Oppose];
        if (total == 0) return 0;
        uint256 feeBps = p.lateEntryFeeBaseBps + total / p.lateEntryFeeScale;
        if (feeBps > p.lateEntryFeeMaxBps) feeBps = p.lateEntryFeeMaxBps;
        return amount * feeBps / 10_000;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Can be empty once every position in the market has been withdrawn.
    function _openPosition(BeliefMarket market, uint256 seed)
        internal
        view
        returns (bool found, uint256 id, address owner)
    {
        uint256[] storage ids = _openPositionIds[market];
        if (ids.length == 0) return (false, 0, address(0));
        id = ids[seed % ids.length];
        owner = _ownerOf[market][id];
        found = true;
    }

    function _trackPosition(BeliefMarket market, uint256 positionId, address owner) internal {
        _positionIds[market].push(positionId);
        _ownerOf[market][positionId] = owner;
        _openPositionIds[market].push(positionId);
        _openIndexPlusOne[market][positionId] = _openPositionIds[market].length;
    }

    /// @dev Swap-and-pop: move the last id into the removed id's slot, then shrink the array. O(1).
    function _untrackOpen(BeliefMarket market, uint256 positionId) internal {
        uint256[] storage ids = _openPositionIds[market];
        uint256 index = _openIndexPlusOne[market][positionId] - 1;
        uint256 last = ids[ids.length - 1];
        ids[index] = last;
        _openIndexPlusOne[market][last] = index + 1;
        ids.pop();
        delete _openIndexPlusOne[market][positionId];
    }
}
