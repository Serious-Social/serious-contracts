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

### Purpose

- Lock creates seriousness
- Withdrawal ensures non‑punitive design
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

Only two fee sources exist in v0:

1. **Author Challenge Premium**
   - Small % (e.g. 1–3%) of author’s initial commit
   - Signals willingness to be challenged

2. **Late‑Entry Friction**
   - Small fee when joining an already‑active market

All fees go into the **Signal Reward Pool (SRP)**.

---

### Reward Philosophy

Stakers are **not betting on outcomes**.
They are compensated for **providing durable signal**.

---

## 8. Reward Distribution Mechanism

### Optional Enhancement: Yield-Bearing Escrow (Aave)

**Idea:** While staked, committed USDC can be deposited into a conservative lending protocol (e.g., Aave) so that generated yield *automatically funds the Signal Reward Pool (SRP)*.

**Rationale:**
- Reduces opportunity cost of long-term commitment
- Makes rewards endogenous to time and scale of commitment
- Decreases reliance on author challenge premiums alone
- Preserves non-zero-sum economics (principal is never at risk)

**Mechanism:**
- All committed principal is held in a yield-bearing vault adapter
- Principal remains fully attributable to users for withdrawal after lock
- Net yield (interest minus protocol fees) is periodically skimmed
- Skimmed yield is routed to the SRP for the associated BeliefMarket

**Distribution:**
- Yield-derived SRP funds are streamed using the same time-weighted rule:
  - Pro-rata by side weight `W_side(t)`
  - Then pro-rata by individual contribution to that side

**Safety & Constraints:**
- Use only audited, conservative markets (e.g., USDC on Aave)
- No rehypothecation beyond lending
- Yield use is *additive*; lack of yield must not break incentives
- Emergency pause must allow immediate withdrawal of principal

**v0 Recommendation:**
- Make yield-bearing escrow **feature-flagged** or disabled by default
- Enable only after base belief mechanics are validated

---

## 8. Reward Distribution Mechanism

Rewards stream out of the SRP over time.

At any time `t`:

```
RewardRate_side(t) = SRP_rate * W_side(t) / (W_support(t) + W_oppose(t))
```

Within a side:
- Rewards are distributed pro‑rata by individual contribution to `W_side`

Effects:
- Early + patient stakers earn more
- Flash stakers earn little
- Both support and oppose can earn

No one "wins" — they earn for staying.

---

## 9. Counter‑Staking (Bounded Adversariality)

Counter‑staking is incentivized but capped.

### Why Counter‑Stake?

- Provide resistance
- Prevent unchecked drift
- Improve epistemic clarity

### Why It’s Not Gambling

- No principal transfer
- No resolution event
- Capped upside
- Time‑weighted rewards

Counter‑staking earns from the same SRP using the same weight logic.

---

## 10. Caps and Safety Rails (Mandatory)

- Max SRP per post (e.g. ≤10% of total principal)
- Max per‑user reward (e.g. ≤2× fees paid)
- Minimum stake duration before rewards accrue
- No leverage
- No liquidation

These prevent degenerate farming behavior.

---

## 11. Withdrawals and Exits

- Principal withdrawable after lock
- Early exit earns little to no reward
- Exits shift the belief curve (information, not punishment)

Optional later:
- Small early‑exit fee

---

## 12. Contract Architecture (Suggested)

### BeliefFactory

- Creates BeliefMarket per post
- Maps postId → market address

### BeliefMarket

State:
- Support: `P_s`, `S_s`
- Oppose: `P_o`, `S_o`
- SRP balance
- Per‑user position records

Functions:
- `commitSupport(amount)`
- `commitOppose(amount)`
- `withdraw(positionId)`
- `claimRewards(positionId)`
- `belief(now)` (view)

Token:
- USDC (ERC‑20)

---

## 13. What This Is *Not*

- Not prediction markets
- Not creator tokens
- Not engagement farming
- Not pay‑to‑post
- Not a casino

This is **infrastructure for serious belief coordination**.

---

## 14. v0 Scope (Strong Recommendation)

- Binary belief only
- One market per post
- No author revenue
- No governance
- No composability promises

Goal of v0:
> Validate that humans will pay for seriousness — not maximize growth.

---

## 15. Core Intuition (for implementers)

If you are unsure how to implement a rule, ask:

> Does this reward patience and conviction, or speed and cleverness?

If it rewards speed or cleverness, it is probably wrong.

---

End of spec.

