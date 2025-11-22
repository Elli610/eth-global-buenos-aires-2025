# Anti-Toxicity Hook for Optimal Onchain Market Making

## Mathematical Foundations & Implementation Guide

This document explains the core mathematical concepts behind the Anti-Toxicity Hook for Uniswap V4, a novel approach to automated market making that addresses market toxicity through dynamic fees based on instantaneous transaction size and directional persistence.

---

## 1. The Mathematical Break-Even Condition

### Problem Statement
For a market maker to be profitable on a single transaction **without rebalancing**, we need to understand when fees earned exceed the gamma loss (impermanent loss) incurred.

### Setup
- Initial price: `sqrtPrice₀`
- Final price: `sqrtPrice₁ = sqrtPrice₀ + ΔsqrtPrice`
- Fee rate: `f`

### Price Dynamics

**Final price (squared):**
```
P_final = (sqrtPrice₀ + ΔsqrtPrice)²
```

**Average execution price:**
```
P_avg = sqrtPrice₀ · (sqrtPrice₀ + ΔsqrtPrice)
```

**Effective price with fees:**
```
P_eff = sqrtPrice₀ · (sqrtPrice₀ + ΔsqrtPrice) · (1 + f)
```

### Profitability Condition

The LP gains if the final market price is **lower** than the effective execution price (the trader overpays relative to where the market ends up):

```
(sqrtPrice₀ + ΔsqrtPrice)² < sqrtPrice₀ · (sqrtPrice₀ + ΔsqrtPrice) · (1 + f)
```

Simplifying:
```
sqrtPrice₀ + ΔsqrtPrice < sqrtPrice₀ · (1 + f)
ΔsqrtPrice < sqrtPrice₀ · f
ΔsqrtPrice / sqrtPrice₀ < f
```

### Critical Result

For small price variations: `ΔP/P = 2 · ΔsqrtPrice/sqrtPrice₀`

Therefore:
```
|ΔP/P| < tickSpacing / 10⁴
```

**Critical Insight:** The price movement must be **less than one tick spacing** for the market maker to be profitable without rebalancing. If a transaction creates slippage ≥ 1 tick spacing, the MM loses money on that transaction (fees earned < gamma loss).

### Example: ETH/USDC Pool with 5bp Fee Tier
- `tickSpacing = 10`
- `f = 10/(2 × 10⁴) = 0.05%`
- **Critical threshold:** `|ΔP/P| < 0.001 = 0.1%`

If a transaction moves the price by more than 0.1%, the LP loses money on that transaction, assuming no rebalancing.

---

## 2. When Price Returns to Initial Point: The Paradox

### The Scenario
1. Price starts at $2,000
2. Toxic upward move to $2,200 (persistent buying over multiple blocks)
3. Price eventually returns to $2,000

### Naive View
"Price returned to start, so no Impermanent Loss if I didn't rebalance. I should hold and wait."

### Professional Risk Management View

At $2,200, after the toxic upward move, you face a decision under uncertainty:

**Scenario A (X% probability):** Price mean-reverts to $2,000
- Loss avoided: $0
- Your strategy: Vindicated (but you got lucky)

**Scenario B ((100-X)% probability):** Price continues to $2,400, $2,600, $2,800...
- Loss incurred: Loss vs holding value is huge


### Key Insight

**Correct decision:** Rebalance at $2,200, accepting a small certain loss to avoid potential ruin.

This is exactly why **measuring toxicity is crucial**: It tells us WHEN we must accept the small controlled loss to avoid important tail risk.

---

## 3. What is Toxicity & How to Compute Pool Toxicity

### Definition

**Market Toxicity** measures persistent directional volatility that causes LPs to lose money. It quantifies the proportion of price movements consisting of unidirectional flows.

**Key distinction:**
- **Volatility** = magnitude of price changes (unsigned)
- **Toxicity** = directional persistence of price changes (signed)

### Construction via Fusion Rule

To isolate truly toxic directional runs from random noise, we apply a **fusion rule**:

**Fusion Rule:** If a counter-directional run has total slippage < `tickSpacing`, it is insufficient to rebalance the LP (from the break-even theorem). Therefore, it **fuses** with adjacent runs in the original direction.

**Intuition:** A tiny counter-move doesn't help the LP rebalance because:
1. Fees captured < ½ tick spacing (half-spread)
2. Gamma loss from original move still exceeds fees
3. LP remains in unbalanced state - the "rebalancing" was illusory

### Toxicity Formula

After applying the fusion rule to construct directional runs:

```
Toxicity = (1/N_runs) × Σ ln((sqrtPrice + ΔsqrtPrice_i) / sqrtPrice) / f
```

where `ΔsqrtPrice_i` represents the **signed** cumulative slippage of fused run `i`.

### Simplified Form

For small tick spacings (typical case):

```
ln(1.0001^tickSpacing) ≈ tickSpacing / 10⁴ = 2f

Toxicity = (1/N_runs) × Σ ln((sqrtPrice + ΔsqrtPrice_i) / sqrtPrice) / f
```

**Critical Implementation Note:** We do NOT use the same data series for `fullRangeAPR` and `Toxicity`!

- `fullRangeAPR` uses **absolute values** (total volume, no cancellation)
- `Toxicity` uses **signed values** with fusion (directional persistence)

### The Critical Ratio: Toxicity / fullRangeAPR

An LP position is likely to be profitable in the long term if:

```
Toxicity / fullRangeAPR < 1
```

**Intuition:**
- `fullRangeAPR ∝ fees earned` (revenue potential)
- `Toxicity ∝ gamma losses` (adverse selection cost)
- When costs exceed revenue, the position is structurally unprofitable
- This ratio directly quantifies net LVR as a proportion of available fees

### Example: Two Pools with Identical APR

**Pool A (ETH/USDC - Blue Chip):**
- `fullRangeAPR = 20%` annualized
- `Toxicity = 5%` (low directional bias, balanced flow)
- `Ratio = 0.25`
- **Result:** Excellent! LPs earn `20% - 5% = 15%` net after adverse selection

**Pool B (SHIB/DOGE - Meme Coins):**
- `fullRangeAPR = 20%` annualized (same apparent yield!)
- `Toxicity = 24%` (high directional runs, persistent toxic flow)
- `Ratio = 1.2`
- **Result:** Losing money: `20% - 24% = -4%` net (negative LVR dominates)

Both pools have identical apparent yield (APR), but only Pool A is profitable. **Toxicity makes all the difference.**

---

## 4. Our Approach: Instantaneous Toxicity Filtering

### Why Volatility-Based Approaches Fail

Traditional "adaptive fees" adjust based on recent **volatility**. This is fundamentally limited because:

**Volatility is not just a measure of price movement - it's a rate that inherently depends on time:**

```
Instantaneous volatility ∝ |ΔsqrtPrice| / Δt
```

Since the time factor `Δt` is involved in the measurement, volatility-based fees calculate pool parameters based on **historical data**.

**The Fatal Lag:**

1. **Phase 1:** Market volatility begins
   - Fees remain at baseline while toxic transactions arrive
   - **Result:** LPs get exploited during detection lag

2. **Phase 2:** Fees finally adjust (too late)
   - Market is now stabilizing (volatility mean-reverts)
   - High fees discourage ALL trading, not just toxic flow
   - **Result:** Very low volume, minimal fees captured, idle capital

### Our Solution: Zero Time Dependency

Our Hook calculates variable fees **instantaneously** based on:

1. **Current swap size** arriving right now: `swapVolume`
2. **Pool's active liquidity** at this instant: `activeLiquidity`
3. **Recent directional history** (without time factor): `sqrtPriceHistorique(β)`

**Key Innovation:** No temporal element intervenes anywhere in the calculation.

The fee depends on:
- **What you're doing now** (swap size relative to pool depth)
- **Where the market is now** (directional imbalance accumulation)
- **Not on when** past swaps occurred (no `Δt` anywhere)

This makes the system:
- **Instantaneous** (zero lag, immediate response to market state)
- **Non-predictable** (adapts to current state, not past patterns traders can game)
- **Incentive-aligned** (automatically encourages rebalancing through asymmetric pricing)
- **Manipulation-resistant** (cannot game historical data accumulation)

---

## 5. Understanding the Parameters: α and β

### Alpha (α): Toxicity Filter Strength

The parameter `α` controls how aggressively the hook filters toxic flow:

- `α = 1`: Minimal filtering (baseline protection, conservative)
- `α = 2`: **Moderate filtering (recommended for production)**
- `α = 3`: Aggressive filtering (volatile pairs)
- `α = 5`: Very aggressive (high toxicity environments, meme coins)

From the fee formula, `α` appears as a linear scaling factor on the entire fee calculation.

**Interpretation:** Higher `α` means:
- Toxic swaps (same direction as sqrtPriceHistorique) pay proportionally more
- Break-even point shifts (more swaps become unprofitable for attackers)
- Pool becomes more selective about which flow to accept
- Effective spread increases: `effective spread ≈ α × f`

### Beta (β): Rebalancing Filter

The parameter `β` determines what constitutes a "true" directional reversal:

- Must satisfy: `β > tickSpacing`
- **Optimal: `β ≈ 1.5 × tickSpacing`**

**Why β > tickSpacing?**

From the break-even theorem, a move of exactly 1 tick spacing is break-even for the LP. Small counter-directional moves (noise) shouldn't reset the toxicity accumulator. Only meaningful reversals should count.

Setting `β = 1.5 × tickSpacing` provides a safety margin: only reversals that generate > 1.5× the break-even threshold are considered true trend changes.

### Example: Effect of Beta

With `tickSpacing = 10` (0.1% price movement) and `β = 15` (0.15%):

- Swaps creating < 0.15% counter-directional move: **Fused** (toxicity continues accumulating)
- Swaps creating ≥ 0.15% counter-directional move: **True reversal** (toxicity resets)

This ensures only meaningful market reversals reset the directional tracking, preventing noise from masking persistent toxic flow.

---

## 6. Complete Fee Formula with All Substitutions

### Final Formula

```
fee% = α × [swapVolume / (2 × activeLiquidity) + sqrtPriceHistorique(β)] / currentSqrtPrice
```

**where:**
- `swapVolume = activeLiquidity × |ΔsqrtPrice|`
- `sqrtPriceHistorique(β)` = computed via detailed algorithm
- `α` = toxicity filter strength (typically 2)
- `β` = reversal threshold ≈ 1.5 × tickSpacing

### Decomposition and Interpretation

**Term 1:** `swapVolume / (2 × activeLiquidity)`
- Represents immediate market impact of the current swap
- Proportional to swap size relative to pool depth
- Derived from the quadratic term in the integral
- Prevents single large swaps from bypassing fees
- Increases linearly with swap size: larger swaps pay proportionally more per unit

**Term 2:** `sqrtPriceHistorique(β)`
- Represents accumulated directional imbalance from recent history
- Zero when market is balanced (no persistent directional flow)
- Large and positive when market has persistent one-way toxic flow
- **Asymmetric:** higher for swaps continuing the toxic direction, lower for rebalancing swaps
- Creates automatic rebalancing incentive through differential pricing

**Multiplier:** `α`
- Scales overall fee magnitude uniformly
- Higher `α` = more aggressive toxicity filtering
- Typical range: 1.5 to 3 for most pools
- Can be adjusted per pool based on asset volatility characteristics


### Key Properties

1. **Anti-fragmentation:** Splitting a swap into multiple pieces yields the same total fees
2. **Linear in swap size:** The `fee%` increases linearly with swap size through the first term
3. **Directional penalty:** The second term penalizes swaps that continue toxic trends
4. **Automatic rebalancing:** Counter-directional swaps see lower `sqrtPriceHistorique(β)`, thus pay less (+ possibility to have an algorithm with automatic rebalancing mechanism in the hook)

### Example: Complete Fee Calculation

**Setup:**
- `activeLiquidity = 50,000` units
- `sqrtPriceHistorique(β) = 0.002` (small bullish bias)
- `α = 2`

**Scenario 1: $5,000 buy (same direction as bias)**
```
fee% = 2 × [5000/(2×50000) + 0.002]
     = 2 × [0.05 + 0.002]
     = 2 × 0.052 = 0.104 = 10.4%

totalFees = 0.104 × 5000 = $520
```

**Scenario 2: $5,000 sell (opposite direction, rebalancing)**

Assume `sqrtPriceHistorique(β)` for opposite direction is `0.0005` (only sub-trend):

```
fee% = 2 × [5000/(2×50000) + 0.0005]
     = 2 × [0.05 + 0.0005]
     = 2 × 0.0505 = 0.101 = 10.1%

totalFees = 0.101 × 5000 = $505
```

**Rebalancing incentive:** The sell swap pays 0.3% less (10.1% vs 10.4%), a $15 savings on this $5,000 trade.

Over many trades, this differential compounds, creating strong economic incentive for bidirectional flow and natural market balance.
