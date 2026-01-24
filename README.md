# Belief Markets: An Escrowed Seriousness Primitive

Smart contracts for serious belief coordination on Ethereum. Users stake USDC to signal durable belief on claims, with time-weighted mechanisms that reward patience over speed.

## Motivation

Modern social platforms optimize for short-term engagement, cheap expression, and virality. This results in weak signal, no accountability, and no durable representation of belief.

Prediction markets solve signal extraction but require objective resolution, are adversarial and zero-sum, and feel like gambling.

**Escrowed seriousness** is a different approach: capital temporarily locked to signal durable belief. The key insight is that *how long* capital stays matters more than how fast it moves.

### Design Principles

- **No objective truth resolution** — beliefs are subjective, markets never settle to "true/false"
- **Non-zero-sum** — rewards come from bounded fees, not others' losses
- **Time > Volatility** — signal is created by duration, not speed
- **Patience is rewarded** — early exits earn little, flash moves are dampened
- **Explicit safety rails** — caps on rewards, no leverage, no liquidation

## Architecture

```
BeliefFactory
    └── creates BeliefMarket (one per post)
            ├── Support Pool
            ├── Oppose Pool
            └── Signal Reward Pool (SRP)
```

### Core Contracts

| Contract | Description |
|----------|-------------|
| `BeliefFactory` | Creates BeliefMarket instances using EIP-1167 minimal proxies |
| `BeliefMarket` | Holds pools, manages positions, calculates belief curve and rewards |

## Key Formulas

### Time-Weighted Signal

Each side (Support/Oppose) maintains:
- `P` = total principal
- `S` = sum of (deposit_amount × deposit_timestamp)

The time-weighted signal at time `t`:

```
W(t) = t × P - S
```

This is O(1) — no iteration over deposits required.

### Belief Curve

```
belief(t) = W_support(t) / (W_support(t) + W_oppose(t))
```

Returns a value from 0 to 1, representing where time-weighted capital sits across stances.

### Reward Calculation (O(1) Synthetix-style)

Rewards use a dual-accumulator pattern adapted for time-weighted stakes:

```
A = Σ (reward × timestamp / totalWeight)    // global accumulator
B = Σ (reward / totalWeight)                // global accumulator

pending = amount × (ΔA - depositTime × ΔB)
```

Each position snapshots A and B at deposit/claim time. This achieves constant-time reward calculation regardless of how many fee events have occurred.

### Late Entry Fee

```
feeBps = min(baseFee + totalPrincipal / scale, maxFee)
```

Scales with market size. First staker pays no fee.

## Fee Sources

1. **Author Challenge Premium** — percentage of author's initial commitment (signals willingness to be challenged)
2. **Late Entry Fee** — small fee when joining an already-active market

All fees flow to the Signal Reward Pool and are distributed to stakers based on time-weighted contribution.

## Safety Rails

| Parameter | Purpose |
|-----------|---------|
| `lockPeriod` | Principal locked for duration (e.g., 30 days) |
| `minRewardDuration` | Minimum stake time before rewards accrue |
| `maxSrpBps` | Cap on SRP as % of total principal |
| `maxUserRewardBps` | Cap on per-user rewards as multiple of fees paid |
| `minStake` / `maxStake` | Bounds on individual stake amounts |

## Usage

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Format

```shell
forge fmt
```

## What This Is Not

- Not prediction markets (no resolution)
- Not creator tokens (no speculation on people)
- Not engagement farming (cost to participate)
- Not gambling (non-zero-sum, capped rewards)

This is **infrastructure for serious belief coordination**.

## License

MIT
