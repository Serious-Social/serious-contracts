// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {BeliefFactory} from "../../src/BeliefFactory.sol";
import {BeliefMarket} from "../../src/BeliefMarket.sol";
import {BeliefVault} from "../../src/BeliefVault.sol";
import {Side, MarketParams, MarketState, Position} from "../../src/types/BeliefTypes.sol";
import {MockUSDC} from "../../src/mock/MockUSDC.sol";
import {BeliefMarketHandler} from "./handlers/BeliefMarketHandler.sol";

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

        // TODO: more variants? (e.g. zero entry fees, minRewardDuration == lockPeriod)

        handler = new BeliefMarketHandler(usdc, vault, markets, creators, creatorCommitments, creatorSides, actors);
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                               INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Cross-market: vault custody matches what each market thinks it holds.
    function invariant_vaultBalanceMatchesMarkets() public view {
        uint256 vaultBalance = usdc.balanceOf(address(vault));
        uint256 totalMarketBalance = 0;
        for (uint256 i = 0; i < markets.length; i++) {
            BeliefMarket market = markets[i];
            MarketState memory state = market.getMarketState();
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

    /// @dev Per market: srpBalance == unallocatedSrp + Σ owed to open positions (within dust).
    ///      Owed is recomputed from the accumulators, not pendingRewards(): that view returns 0
    ///      before minRewardDuration, but those rewards are already earmarked in srpBalance.
    function invariant_srpFullyAccounted() public view {
        // Dust bound: each open position's owed amount is floored (< 1 unit each), and each paid claim,
        // auto-claim and forfeit permanently orphans its floored remainder (< 1 unit each).
        // Counters span all markets, so this is looser than a per-market bound but still sound.
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

    /// @dev Per market and side: pool principal and weightedTimestampSum (the S in W = t·P − S)
    ///      == Σ amount and Σ amount × depositTimestamp of non-withdrawn positions.
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
            assertEq(supportPrincipal, supportSum, "support principal mismatch");
            assertEq(opposePrincipal, opposeSum, "oppose principal mismatch");
            assertEq(supportWeightedTs, supportWeightedTsSum, "support weightedTimestampSum mismatch");
            assertEq(opposeWeightedTs, opposeWeightedTsSum, "oppose weightedTimestampSum mismatch");
            assertEq(supportPrincipal, handler.ghost_openPrincipal(market, Side.Support), "support ghost mismatch");
            assertEq(opposePrincipal, handler.ghost_openPrincipal(market, Side.Oppose), "oppose ghost mismatch");
        }
    }

    /// @dev Non-zero-sum: rewards paid out never exceed fees paid in.
    ///      Exact form: srpBalance == premium + entry fees + penalties - rewards paid (all observed by the handler).
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

    /// @dev pending = amount × (ΔA − depositTimestamp × ΔB) / RAY, without the minRewardDuration gate.
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
