# Belief Markets / Escrowed Seriousness

This document summarizes the **motivation**, **design principles**, and **core mechanisms** for a belief‑market primitive intended to support *serious social discourse* without devolving into gambling, speculation, or engagement farming.

It is written to be handed directly to an implementation agent (e.g. Claude Code) as a starting point for Solidity contract design.

---

## 1. Motivation

### The Problem

Modern social platforms optimize for:
- short‑term engagement
- cheap expression
- virality and dunk culture

This results in:
- weak signal
- no accountability
- no durable representation of belief

Prediction markets solve signal extraction, but:
- require objective resolution
- are adversarial and zero‑sum
- feel like gambling

Pure SocialFi attempts fail because:
- they reward pre‑existing social capital
- they create bubbles around people
- incentives collapse when tokens go to zero

### Goal

Create a **belief‑coordination primitive** where:
- expressing conviction has a cost
- belief strength is legible
- disagreement is invited but bounded
- money disciplines behavior without dominating it

This is summarized as:

> **Escrowed seriousness** — capital temporarily locked to signal durable belief.

---

## 2. Design Principles

1. **No objective truth resolution**
   - Beliefs are subjective
   - Markets never settle to “true / false”

2. **Non‑zero‑sum by default**
   - No forced transfer of principal
   - Rewards come from bounded fees, not others’ losses

3. **Time > Volatility**
   - Signal is created by *how long* capital stays, not how fast it moves

4. **Bounded adversariality**
   - Enough economic tension to invite counter‑staking
   - Never enough to feel like gambling or dunking

5. **Patience is rewarded**
   - Early exits earn little
   - Flash moves are dampened

6. **Explicit safety rails**
   - Caps on rewards
   - No leverage
   - No liquidation

---

## 3. Core Concept: Belief Curve

A **belief curve** represents where time‑weighted capital sits across opposing stances on a claim.

### v0 Stance Space

Binary:
- SUPPORT
- OPPOSE

(Generalization to multi‑bucket confidence can come later.)

---

## 4. Market Structure

Each post / research note creates **one BeliefMarket**.

Each BeliefMarket contains:
- Support pool
- Oppose pool
- Signal Reward Pool (SRP)

Users interact by staking USDC into either pool.

---

## 5. Escrowed Commitment

### Deposits

When a user stakes:
- Principal is **locked** for `LOCK_PERIOD` (e.g. 30 days)
- After lock, principal becomes withdrawable
- An entry fee is deducted and routed to the SRP; only the net amount is recorded as principal
- The first staker pays no entry fee; the fee scales upward with total principal already staked

### Early Withdrawal

If a user withdraws before `LOCK_PERIOD` expires:
- A **penalty** (configurable, e.g. 5% of principal) is deducted
- The penalty is routed to the SRP (only if remaining stakers exist to receive it)
- All previously minted **reputation tokens** are burned (see §8a)
- Pending USDC rewards are forfeited
- Set `earlyWithdrawPenaltyBps = 0` to disable early withdrawal entirely

### Purpose

- Lock creates seriousness
- Normal withdrawal ensures non‑punitive design
- Early withdrawal is allowed but costly — it penalizes impatience while keeping the door open
- Silence ≠ loss

---

## 6. Time‑Weighted Signal (Weight Accumulator)

Each side maintains aggregate values:

- `P` = total principal
- `S` = sum of (deposit_amount × deposit_timestamp)

At time `t`:

```
W(t) = t * P - S
```

Where:
- `W(t)` = time‑weighted signal

This can be computed in O(1) without iterating deposits.

### Belief Curve Value

```
p(t) = W_support(t) / (W_support(t) + W_oppose(t))
```

Interpretation:
> Where has capital *sat long enough to count*?

---

## 7. Economic Incentives (Who Earns and Why)

### Funding Sources

Three fee sources fund the SRP in v0:

1. **Author Challenge Premium**
   - Small % (e.g. 1–3%) of author's initial commit
   - Signals willingness to be challenged

2. **Entry Fee (Sliding Scale)**
   - Fee charged on every stake (except the first staker, who pays nothing)
   - Scales with total principal already in the market: `feeBps = min(baseFee + totalPrincipal / scale, maxFee)`
   - Early participants pay less; later participants pay more

3. **Early Withdrawal Penalty**
   - Penalty % of principal forfeited by impatient stakers (see §5)
   - Only collected when remaining stakers exist to receive it

All fees go into the **Signal Reward Pool (SRP)**.

---

### Reward Philosophy

Stakers are **not betting on outcomes**.
They are compensated for **providing durable signal**.

---

## 8. Reward Distribution Mechanism

Rewards are distributed from the SRP using an **O(1) dual accumulator** pattern (adapted from Synthetix `StakingRewards`), extended to weight rewards by each position's *time in the market*.

### Accumulators

The contract maintains two global accumulators, updated each time fees enter the SRP:

```
A += (fee × t_checkpoint × RAY) / W_total(t)
B += (fee × RAY) / W_total(t)
```

Where `W_total(t) = W_support(t) + W_oppose(t)` is the total time‑weighted signal across both sides at the checkpoint, and `RAY = 1e27` provides high‑precision fixed‑point math.

### Per‑Position Reward Calculation

When a position is created or claims rewards, it snapshots `(A₀, B₀)`. Pending rewards at any later point are:

```
pending = amount × (ΔA − t_deposit × ΔB) / RAY
```

Where `ΔA = A − A₀` and `ΔB = B − B₀`.

This is equivalent to summing `amount × (t_checkpoint − t_deposit) × fee / W_total` over every fee event — but computed in O(1) regardless of how many fee events or positions exist.

### Effects

- Early + patient stakers earn more (larger `t_checkpoint − t_deposit`)
- Flash stakers earn little
- Both support and oppose can earn
- Rewards are claimable only after `minRewardDuration` has elapsed

No one "wins" — they earn for staying.

### Minimum Reward Duration

Positions must wait at least `minRewardDuration` (e.g. 7 days) after deposit before any rewards can be claimed. This prevents micro‑staking to farm fee events.

---

## 8a. Seriousness Reputation Token (SRS)

A **non‑transferable (soulbound) ERC‑20** token that accrues proportionally to stake amount and duration.

### Accrual

```
reputation = amount × elapsed_seconds × REPUTATION_SCALE / SECONDS_PER_DAY
```

Where `REPUTATION_SCALE = 1e12` bridges USDC's 6 decimals to SRS's 18 decimals. In human terms: **1 SRS per USD‑day staked**.

### Minting

- Reputation is minted lazily when a position claims USDC rewards or withdraws normally
- Only accrues after `minRewardDuration` has elapsed

### Burning

- On **early withdrawal**, all previously minted SRS for that position is burned
- This makes early exit costly in reputation, not just in USDC penalty

### Properties

- Soulbound: only mint and burn — no transfers between addresses
- Only registered BeliefMarkets can mint / burn (enforced via the BeliefVault registry)

---

## 8b. Optional Enhancement: Yield‑Bearing Escrow (Aave)

**Idea:** While staked, committed USDC can be deposited into a conservative lending protocol (e.g., Aave) so that generated yield *automatically funds the Signal Reward Pool (SRP)*.

**Rationale:**
- Reduces opportunity cost of long‑term commitment
- Makes rewards endogenous to time and scale of commitment
- Decreases reliance on author challenge premiums alone
- Preserves non‑zero‑sum economics (principal is never at risk)

**Mechanism:**
- All committed principal is held in a yield‑bearing vault adapter
- Principal remains fully attributable to users for withdrawal after lock
- Net yield (interest minus protocol fees) is periodically skimmed
- Skimmed yield is routed to the SRP for the associated BeliefMarket

**Safety & Constraints:**
- Use only audited, conservative markets (e.g., USDC on Aave)
- No rehypothecation beyond lending
- Yield use is *additive*; lack of yield must not break incentives
- Emergency pause must allow immediate withdrawal of principal

**v0 Recommendation:**
- Feature‑flagged via `yieldBearingEscrow` in `MarketParams` — disabled by default
- Enable only after base belief mechanics are validated

---

## 9. Counter‑Staking (Bounded Adversariality)

Counter‑staking is incentivized but bounded.

### Why Counter‑Stake?

- Provide resistance
- Prevent unchecked drift
- Improve epistemic clarity

### Why It's Not Gambling

- No principal transfer
- No resolution event
- Time‑weighted rewards from SRP — same accumulators, same math
- Both sides earn from the same pool; the heavier side simply earns a larger share

---

## 10. Configurable Parameters and Safety Rails

Each market is created with a `MarketParams` struct:

| Parameter | Description | Default |
|---|---|---|
| `lockPeriod` | Duration principal is locked (seconds) | 30 days |
| `minRewardDuration` | Time before rewards start accruing | 3 days |
| `lateEntryFeeBaseBps` | Base entry fee (bps) | 100 (1%) |
| `lateEntryFeeMaxBps` | Maximum entry fee (bps) | 750 (7.5%) |
| `lateEntryFeeScale` | Principal amount that adds 1 bps | $1,000 USDC |
| `authorPremiumBps` | Author challenge premium (bps) | 1000 (10%) |
| `earlyWithdrawPenaltyBps` | Early withdrawal penalty (bps); 0 = disabled | 1500 (15%) |
| `yieldBearingEscrow` | Enable Aave yield integration | false |
| `minStake` | Minimum stake amount | $5 USDC |
| `maxStake` | Maximum stake amount | $1,000 USDC |

### Mandatory Safety Rails

- Min/max stake bounds prevent dust attacks and whale dominance
- `minRewardDuration` prevents micro‑staking to farm fee events
- Entry fee cap prevents excessive extraction
- No leverage
- No liquidation

The factory owner can update default parameters for new markets via `setDefaultParams`.

---

## 11. Withdrawals and Exits

### Normal Withdrawal (after lock period)

- Principal is fully returned via the vault
- Pending SRP rewards are auto‑claimed in the same transaction
- Accrued reputation (SRS) is minted before release
- The position's principal and weighted timestamp are removed from the pool, shifting the belief curve

### Early Withdrawal (before lock period)

- A penalty (e.g. 15%) is deducted from principal and routed to the SRP
- All pending USDC rewards are forfeited
- All previously minted SRS reputation is burned
- Remaining principal is returned to the user
- Disabled when `earlyWithdrawPenaltyBps = 0`

In both cases, exits shift the belief curve — this is information, not punishment.

---

## 12. Contract Architecture

### BeliefFactory (`Ownable`)

- Deploys a single **BeliefMarket** implementation contract at construction
- Deploys a single **BeliefVault** for centralized USDC custody
- Deploys a single **SeriousnessToken** (SRS) for reputation
- Creates new markets as **EIP‑1167 minimal proxy** clones for gas‑efficient deployment
- Maps `postId → market address`
- Holds default `MarketParams`; owner can update via `setDefaultParams`

### BeliefVault

- Centralized USDC custody across all markets
- Per‑market balance isolation prevents a compromised market from draining others
- Only the factory can register new markets
- Only registered markets can lock / release USDC
- Also serves as the authority for SRS mint/burn permissions

### BeliefMarket (clone)

State:
- Support pool: `principal`, `weightedTimestampSum`
- Oppose pool: `principal`, `weightedTimestampSum`
- SRP balance
- Dual reward accumulators: `rewardPerPrincipalTime`, `rewardPerPrincipalPerTime`
- Per‑position records (side, timestamps, amount, claimed rewards)
- Per‑position reward accumulator snapshots
- Per‑position reputation tracking

Functions:
- `commitSupport(amount)` / `commitOppose(amount)` — stake USDC to a side
- `withdraw(positionId)` — withdraw principal (normal or early)
- `claimRewards(positionId)` — claim pending SRP rewards + mint accrued SRS
- `belief()` — view current belief curve value (0 to 1e18)
- `getWeight(side)` — view time‑weighted signal for a side
- `getMarketState()` — view full market snapshot
- `pendingRewards(positionId)` — view claimable USDC rewards
- `pendingReputation(positionId)` — view mintable SRS
- `getCurrentEntryFeeBps()` — view current entry fee

### SeriousnessToken (SRS)

- Non‑transferable (soulbound) ERC‑20
- Only registered markets can mint / burn
- See §8a for accrual and burn mechanics

### Token

- USDC (ERC‑20, 6 decimals)

---

## 13. What This Is *Not*

- Not prediction markets
- Not creator tokens
- Not engagement farming
- Not pay‑to‑post
- Not a casino

This is **infrastructure for serious belief coordination**.

---

## 14. v0 Scope

- Binary belief only (SUPPORT / OPPOSE)
- One market per post
- No author revenue (author pays premium like everyone else)
- No governance
- No composability promises
- Yield‑bearing escrow disabled by default
- Deploying on Base (USDC: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`)

Goal of v0:
> Validate that humans will pay for seriousness — not maximize growth.

---

## 15. Core Intuition (for implementers)

If you are unsure how to implement a rule, ask:

> Does this reward patience and conviction, or speed and cleverness?

If it rewards speed or cleverness, it is probably wrong.

---

End of spec.

