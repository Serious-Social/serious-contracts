// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {BeliefFactory} from "../../src/BeliefFactory.sol";
import {BeliefMarket} from "../../src/BeliefMarket.sol";
import {BeliefVault} from "../../src/BeliefVault.sol";
import {Side, MarketParams, MarketState, Position} from "../../src/types/BeliefTypes.sol";
import {MockUSDC} from "../../src/mock/MockUSDC.sol";
import {BeliefMarketHandler} from "./handlers/BeliefMarketHandler.sol";

/// @title SeriousInvariantTest
/// @notice Stateful fuzz (invariant) tests for BeliefMarket + BeliefVault.
///
/// SETUP
/// - Two markets are created up front through the factory. Market 1 has no early-withdraw penalty,
///   so both penalty branches get fuzzed.
/// - Only the handler is fuzzed (targetContract). Direct calls to the markets would skip the
///   handler's ghost bookkeeping, and Foundry can't fuzz EIP-1167 clones directly anyway.
///
/// THE FOUR INVARIANTS (checked after every handler call)
/// 1. vaultBalanceMatchesMarkets: every USDC is accounted for (custody and conservation).
/// 2. srpFullyAccounted:          the reward pool can pay everything it owes, and nothing is
///                                stranded beyond rounding dust.
/// 3. poolsMatchOpenPositions:    the pool totals that drive belief and rewards match the positions.
/// 4. rewardsBoundedByFees:       non-zero-sum; rewards come only from fees, never from principal.
///
/// TWO KINDS OF CHECK
/// - Consistency:  the contract against its own records (e.g. pool total vs sum of positions).
/// - Conservation: the contract against the handler's ghosts, i.e. USDC actually seen moving.
///   This catches bugs that keep the contract's books internally consistent.
///
/// KNOWN GAPS
/// - Rewards are checked in total, not per position: a bug that paid the right total to the wrong
///   positions would pass. Closing that needs a brute-force reference model of each entitlement.
/// - With these params the late-entry fee never reaches its cap (lateEntryFeeMaxBps).
/// - No end-of-run check that every position can still withdraw (liveness).
contract SeriousInvariantTest is Test {
    MockUSDC public usdc;
    BeliefFactory public factory;
    BeliefVault public vault;
    BeliefMarketHandler public handler;

    BeliefMarket[] public markets;
    address[] public creators;
    uint256[] public creatorCommitments;
    Side[] public creatorSides;

    // Actors
    address ALICE = makeAddr("alice");
    address BOB = makeAddr("bob");
    address CAROL = makeAddr("carol");
    address[] actors = [ALICE, BOB, CAROL];

    uint256 constant CREATOR_COMMITMENT = 50e6;

    function setUp() public {
        usdc = new MockUSDC();
        factory = new BeliefFactory(address(usdc), _defaultParams());
        vault = BeliefVault(factory.getVault());

        // Market 0: default params
        _createMarket("market-0", Side.Support);

        // Market 1: no early-withdraw penalty (exercises the penalty-free branch)
        MarketParams memory p = _defaultParams();
        p.earlyWithdrawPenaltyBps = 0;
        factory.setDefaultParams(p);
        _createMarket("market-1", Side.Oppose);

        // TODO: more variants? (e.g. small lateEntryFeeScale to reach the fee cap, minRewardDuration == lockPeriod)

        // The handler gets the creator data so its ghosts start from the state setUp left behind
        handler = new BeliefMarketHandler(usdc, vault, markets, creators, creatorCommitments, creatorSides, actors);
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                               INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Property: every USDC is accounted for, checked three ways.
    ///        a) Per market: the market's books (SRP + principal) == the vault's books for that market.
    ///        b) Per market: that amount == ghost USDC in - USDC out (conservation, from observed transfers).
    ///        c) Global:     the vault's real token balance == the sum over all markets.
    ///      Catches: money leaving without being booked, one market credited with another's funds,
    ///      fees or principal miscounted in a way the contract's own books agree with.
    function invariant_vaultBalanceMatchesMarkets() public view {
        uint256 vaultBalance = usdc.balanceOf(address(vault));
        uint256 totalMarketBalance = 0;
        for (uint256 i = 0; i < markets.length; i++) {
            BeliefMarket market = markets[i];
            MarketState memory state = market.getMarketState();
            // srpBalance already includes unallocatedSrp
            uint256 marketBalance = state.srpBalance + state.supportPrincipal + state.opposePrincipal;
            assertEq(marketBalance, vault.marketBalance(address(market)), "market balance mismatch");
            assertEq(
                marketBalance,
                handler.ghost_grossIn(market) - handler.ghost_principalReturned(market)
                    - handler.ghost_totalClaimedRewards(market),
                "market balance != ghost in - out"
            );
            totalMarketBalance += marketBalance;
        }
        assertEq(vaultBalance, totalMarketBalance, "vault balance mismatch");
    }

    /// @dev Property: the reward pool (SRP) is solvent and nothing in it is stranded.
    ///        owed = unallocatedSrp + what every open position could claim
    ///        owed <= srpBalance <= owed + rounding dust
    ///      Catches: promising more rewards than the pool holds; funds stuck with no one able to
    ///      claim them (the bug fixed in PR #5, where forfeited rewards were stranded).
    ///      Owed is recomputed from the accumulators, not pendingRewards(): that view returns 0
    ///      before minRewardDuration, but those rewards are already earmarked in srpBalance.
    function invariant_srpFullyAccounted() public view {
        // Why there is dust: the contract always rounds down, so it never owes more than it holds.
        //  - Each open position's owed amount is rounded down: < 1 unit each (temporary).
        //  - Each payout or forfeit rounds down and the leftover fraction stays in srpBalance with
        //    no owner: < 1 unit each (permanent).
        // 1 unit = 1e-6 USDC. Measured slack was about 50-75% of this bound, as expected if each
        // round-down loses ~0.5 units on average. Counters span all markets (loose but sound).
        uint256 payoutEvents =
            handler.calls("claimRewards.paid") + handler.calls("withdraw.early") + handler.calls("withdraw.normal");

        for (uint256 i = 0; i < markets.length; i++) {
            BeliefMarket market = markets[i];
            uint256[] memory openIds = handler.openPositionIds(market);
            uint256 owed = market.unallocatedSrp();
            for (uint256 j = 0; j < openIds.length; j++) {
                owed += _owedUngated(market, openIds[j]);
            }

            uint256 srp = market.srpBalance();
            assertGe(srp, owed, "SRP owes more than it holds");
            assertLe(srp - owed, openIds.length + payoutEvents, "SRP holds funds no one can claim");
        }
    }

    /// @dev Property: each pool's totals equal the sum over its open positions, per side.
    ///        principal            == sum of amount
    ///        weightedTimestampSum == sum of amount x depositTimestamp   (the S in W(t) = t x P - S)
    ///      Also: principal == the handler's ghost_openPrincipal.
    ///      Why it matters: W(t) drives both the belief curve and every reward split, so a wrong
    ///      P or S silently skews belief and rewards.
    ///      Catches: wrong amount removed on withdraw, principal booked to the wrong side,
    ///      net/gross mix-ups.
    ///      Loops over ALL positions and uses the contract's own `withdrawn` flag, so the
    ///      sum doesn't depend on the handler's open list.
    function invariant_poolsMatchOpenPositions() public view {
        for (uint256 i = 0; i < markets.length; i++) {
            BeliefMarket market = markets[i];
            (uint256 supportPrincipal, uint256 supportWeightedTs) = market.supportPool();
            (uint256 opposePrincipal, uint256 opposeWeightedTs) = market.opposePool();
            uint256 supportSum = 0;
            uint256 opposeSum = 0;
            uint256 supportWeightedTsSum = 0;
            uint256 opposeWeightedTsSum = 0;
            uint256[] memory positionIds = handler.positionIds(market);
            for (uint256 j = 0; j < positionIds.length; j++) {
                Position memory pos = market.getPosition(positionIds[j]);
                if (!pos.withdrawn) {
                    if (pos.side == Side.Support) {
                        supportSum += pos.amount;
                        supportWeightedTsSum += pos.amount * pos.depositTimestamp;
                    } else {
                        opposeSum += pos.amount;
                        opposeWeightedTsSum += pos.amount * pos.depositTimestamp;
                    }
                }
            }
            // Contract vs its own position records
            assertEq(supportPrincipal, supportSum, "support principal mismatch");
            assertEq(opposePrincipal, opposeSum, "oppose principal mismatch");
            assertEq(supportWeightedTs, supportWeightedTsSum, "support weightedTimestampSum mismatch");
            assertEq(opposeWeightedTs, opposeWeightedTsSum, "oppose weightedTimestampSum mismatch");
            // Contract vs what the handler observed
            assertEq(supportPrincipal, handler.ghost_openPrincipal(market, Side.Support), "support ghost mismatch");
            assertEq(opposePrincipal, handler.ghost_openPrincipal(market, Side.Oppose), "oppose ghost mismatch");
        }
    }

    /// @dev Property (non-zero-sum, a core design principle of the spec): rewards come only from fees.
    ///        rewards paid <= premium + entry fees + penalties
    ///        srpBalance   == premium + entry fees + penalties - rewards paid   (exact, from ghosts)
    ///      The equality already implies the inequality; the inequality is kept because it states
    ///      the design principle directly.
    ///      Catches: rewards paid out of principal, fees not reaching the SRP, payouts not deducted.
    function invariant_rewardsBoundedByFees() public view {
        for (uint256 i = 0; i < markets.length; i++) {
            BeliefMarket market = markets[i];
            uint256 srpIn = handler.ghost_creatorPremium(market) + handler.ghost_totalEntryFees(market)
                + handler.ghost_totalPenalties(market);
            uint256 paid = handler.ghost_totalClaimedRewards(market);

            assertLe(paid, srpIn, "rewards paid exceed fees collected");
            assertEq(market.srpBalance(), srpIn - paid, "srpBalance != ghost fees in - rewards out");
        }
    }

    /// @dev Coverage report: how many calls took each path, so we can see every path is reached.
    ///      Shows the LAST run only: handler state, counters included, resets between runs.
    ///      The Calls/Reverts table Foundry prints is the total across all runs.
    function afterInvariant() external view {
        console.log("commit       ", handler.calls("commit"));
        console.log("withdraw     ", handler.calls("withdraw"));
        console.log("  noOpen     ", handler.calls("withdraw.noOpenPositions"));
        console.log("  heldEarly  ", handler.calls("withdraw.heldEarly"));
        console.log("  early      ", handler.calls("withdraw.early"));
        console.log("  normal     ", handler.calls("withdraw.normal"));
        console.log("claimRewards ", handler.calls("claimRewards"));
        console.log("  noOpen     ", handler.calls("claimRewards.noOpenPositions"));
        console.log("  tooEarly   ", handler.calls("claimRewards.tooEarly"));
        console.log("  nothing    ", handler.calls("claimRewards.nothing"));
        console.log("  paid       ", handler.calls("claimRewards.paid"));
        console.log("warp         ", handler.calls("warp"));
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev The creator is one of the actors (market 0: Alice, market 1: Bob), so the fuzzer can also
    ///      have a creator stake again in their own market, or in another market.
    function _createMarket(string memory label, Side side) internal {
        address creator = actors[markets.length % actors.length];
        usdc.mint(creator, CREATOR_COMMITMENT);

        vm.startPrank(creator);
        usdc.approve(address(vault), CREATOR_COMMITMENT);
        address market = factory.createMarket(keccak256(bytes(label)), CREATOR_COMMITMENT, side);
        vm.stopPrank();

        markets.push(BeliefMarket(market));
        creators.push(creator);
        creatorCommitments.push(CREATOR_COMMITMENT);
        creatorSides.push(side);
    }

    /// @dev What a position could claim right now, ignoring the minRewardDuration gate.
    ///        pending = amount x (deltaA - depositTimestamp x deltaB) / RAY
    ///      A and B are the contract's two reward accumulators; the deltas are measured since the
    ///      position's last snapshot (taken at deposit or last claim).
    function _owedUngated(BeliefMarket market, uint256 positionId) internal view returns (uint256) {
        Position memory pos = market.getPosition(positionId);
        uint256 dA = market.rewardPerPrincipalTime() - market.positionRewardPerPrincipalTimePaid(positionId);
        uint256 dB = market.rewardPerPrincipalPerTime() - market.positionRewardPerPrincipalPerTimePaid(positionId);
        return (pos.amount * (dA - uint256(pos.depositTimestamp) * dB)) / 1e27;
    }

    function _defaultParams() internal pure returns (MarketParams memory) {
        return MarketParams({
            lockPeriod: 30 days,
            minRewardDuration: 7 days,
            lateEntryFeeBaseBps: 50,
            lateEntryFeeMaxBps: 500,
            lateEntryFeeScale: 1000e6,
            creatorPremiumBps: 200,
            earlyWithdrawPenaltyBps: 500,
            yieldBearingEscrow: false,
            minStake: 5e6,
            maxStake: 100e6
        });
    }
}
