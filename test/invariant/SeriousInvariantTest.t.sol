// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {BeliefFactory} from "../../src/BeliefFactory.sol";
import {BeliefMarket} from "../../src/BeliefMarket.sol";
import {BeliefVault} from "../../src/BeliefVault.sol";
import {Side, MarketParams} from "../../src/types/BeliefTypes.sol";
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
        // TODO
    }

    /// @dev Per market: srpBalance == unallocatedSrp + Σ owed to open positions (within dust).
    function invariant_srpFullyAccounted() public view {
        // TODO
    }

    /// @dev Per market: pool principal == Σ amount of non-withdrawn positions, per side.
    function invariant_poolsMatchOpenPositions() public view {
        // TODO
    }

    /// @dev Non-zero-sum: rewards paid out never exceed fees paid in.
    function invariant_rewardsBoundedByFees() public view {
        // TODO
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
