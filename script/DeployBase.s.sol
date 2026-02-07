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
        address usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

        console.log("Deploying from:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Default market params
        MarketParams memory defaultParams = MarketParams({
            lockPeriod: 30 days,
            minRewardDuration: 3 days,
            lateEntryFeeBaseBps: 100, // 1%
            lateEntryFeeMaxBps: 750, // 7.5%
            lateEntryFeeScale: 1000e6, // +1 bps per $1000
            authorPremiumBps: 1000, // 10%
            earlyWithdrawPenaltyBps: 1500, // 15%
            yieldBearingEscrow: false,
            minStake: 5e6, // $5 USDC
            maxStake: 1000e6 // $1000 USDC
        });

        // Deploy BeliefFactory with USDC and default params
        BeliefFactory factory = new BeliefFactory(address(usdc), defaultParams);
        console.log("BeliefFactory deployed at:", address(factory));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("BeliefFactory:", address(factory));
        console.log("BeliefVault:", factory.getVault());
    }
}
