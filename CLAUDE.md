# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the **Belief Markets / Escrowed Seriousness** project - a Solidity smart contract system for serious belief coordination on Ethereum. Users stake USDC to signal durable belief on claims (SUPPORT or OPPOSE), with time-weighted mechanisms that reward patience over speed.

The specification is in `belief_markets_motivation_mechanism_spec.md`.

## Commands

```bash
forge build          # Compile contracts
forge test           # Run all tests
forge test -vvv      # Run tests with verbose output
forge test --match-test testFunctionName  # Run a single test
forge test --match-contract ContractName  # Run tests in a specific contract
forge fmt            # Format Solidity code
forge fmt --check    # Check formatting without modifying
```

## Architecture

### Project Structure

- `src/` - Contract source files
- `test/` - Foundry tests
- `script/` - Deployment scripts
- `lib/` - Dependencies (forge-std)

### Core Contracts

- **BeliefFactory**: Creates one BeliefMarket per post, maps postId to market address
- **BeliefMarket**: Holds Support/Oppose pools, Signal Reward Pool (SRP), and per-user position records

### Key Mechanisms

- **Time-Weighted Signal**: `W(t) = t * P - S` where P = total principal, S = sum of (amount × timestamp)
- **Belief Curve**: `p(t) = W_support(t) / (W_support(t) + W_oppose(t))`
- **Lock Period**: Principal locked for configurable period (e.g., 30 days)
- **Non-zero-sum**: Rewards from SRP, no principal transfer between sides

### BeliefMarket Functions

- `commitSupport(amount)` / `commitOppose(amount)` - Stake USDC to a side
- `withdraw(positionId)` - Withdraw principal after lock period
- `claimRewards(positionId)` - Claim earned SRP rewards
- `belief(now)` - View current belief curve value

## Design Principles

When implementing, if unsure about a design decision, ask:

> Does this reward patience and conviction, or speed and cleverness?

If it rewards speed or cleverness, it is probably wrong.

### Mandatory Safety Rails

- Max SRP per post (e.g., ≤10% of total principal)
- Max per-user reward cap
- Minimum stake duration before rewards accrue
- No leverage, no liquidation

## v0 Scope

Keep v0 minimal:
- Binary belief only (SUPPORT/OPPOSE)
- One market per post
- No author revenue
- No governance
- No composability promises

Goal: Validate that humans will pay for seriousness.

## Optional Features (Feature-Flagged)

- **Yield-Bearing Escrow**: Deposit principal to Aave, skim yield to SRP. Disabled by default until base mechanics are validated.
