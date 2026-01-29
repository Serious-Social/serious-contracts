// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDC} from "../src/mock/MockUSDC.sol";
import {BeliefFactory} from "../src/BeliefFactory.sol";
import {MarketParams} from "../src/types/BeliefTypes.sol";

/// @notice Deploy MockUSDC and BeliefFactory to Base Sepolia
contract DeployBaseSepolia is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying from:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy MockUSDC
        MockUSDC usdc = new MockUSDC();
        console.log("MockUSDC deployed at:", address(usdc));

        // Mint some USDC to deployer for testing
        usdc.mint(deployer, 1_000_000e6); // 1M USDC
        console.log("Minted 1M USDC to deployer");

        // Default market params
        MarketParams memory defaultParams = MarketParams({
            lockPeriod: 30 days,
            minRewardDuration: 7 days,
            maxUserRewardBps: 20000, // 200% of fees
            lateEntryFeeBaseBps: 50, // 0.5%
            lateEntryFeeMaxBps: 500, // 5%
            lateEntryFeeScale: 1000e6, // +1 bps per $1000
            authorPremiumBps: 200, // 2%
            earlyWithdrawPenaltyBps: 500, // 5%
            yieldBearingEscrow: false,
            minStake: 5e6, // $5 USDC
            maxStake: 100_000e6 // $100k USDC
        });

        // Deploy BeliefFactory with USDC and default params
        BeliefFactory factory = new BeliefFactory(address(usdc), defaultParams);
        console.log("BeliefFactory deployed at:", address(factory));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("MockUSDC:", address(usdc));
        console.log("BeliefFactory:", address(factory));
        console.log("Deployer balance:", usdc.balanceOf(deployer) / 1e6, "USDC");
    }
}
