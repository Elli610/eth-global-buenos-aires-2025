# Anti-Toxicity Hook for Optimal Onchain Market Making

## Mathematical Foundations & Implementation Guide

This document explains the core mathematical concepts behind the Anti-Toxicity Hook for Uniswap V4, a novel approach to automated market making that addresses market toxicity through dynamic fees based on instantaneous transaction size and directional persistence.

---

## 1. The Mathematical Break-Even Condition

### Problem Statement
For a market maker to be profitable on a single transaction **without rebalancing**, we need to understand when fees earned exceed the gamma loss (impermanent loss) incurred.

### Setup
- Initial price: $\text{sqrtPrice}_0$
- Final price: $\text{sqrtPrice}_1 = \text{sqrtPrice}_0 + \Delta\text{sqrtPrice}$
- Fee rate: $f$

### Price Dynamics

**Final price (squared):**
$$P_{\text{final}} = (\text{sqrtPrice}_0 + \Delta\text{sqrtPrice})^2$$

**Average execution price:**
$$P_{\text{avg}} = \text{sqrtPrice}_0 \cdot (\text{sqrtPrice}_0 + \Delta\text{sqrtPrice})$$

**Effective price with fees:**
$$P_{\text{eff}} = \text{sqrtPrice}_0 \cdot (\text{sqrtPrice}_0 + \Delta\text{sqrtPrice}) \cdot (1 + f)$$

### Profitability Condition

The LP gains if the final market price is **lower** than the effective execution price (the trader overpays relative to where the market ends up):

$$(\text{sqrtPrice}_0 + \Delta\text{sqrtPrice})^2 < \text{sqrtPrice}_0 \cdot (\text{sqrtPrice}_0 + \Delta\text{sqrtPrice}) \cdot (1 + f)$$

Simplifying:

$$\frac{\Delta\text{sqrtPrice}}{\text{sqrtPrice}_0} < f$$

### Critical Result

For small price variations: $\frac{\Delta P}{P} = 2 \cdot \frac{\Delta\text{sqrtPrice}}{\text{sqrtPrice}_0}$

Therefore:
$$\left|\frac{\Delta P}{P}\right| < \frac{\text{tickSpacing}}{10^4}$$

**Critical Insight:** The price movement must be **less than one tick spacing** for the market maker to be profitable without rebalancing. If a transaction creates slippage $\geq$ 1 tick spacing, the MM loses money on that transaction (fees earned < gamma loss).

### Example: ETH/USDC Pool with 5bp Fee Tier
- $\text{tickSpacing} = 10$
- $f = \frac{10}{2 \times 10^4} = 0.05\%$
- **Critical threshold:** $\left|\frac{\Delta P}{P}\right| < 0.001 = 0.1\%$

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

**Scenario A ($X\%$ probability):** Price mean-reverts to $2,000
- Loss avoided: $0
- Your strategy: Vindicated (but you got lucky)

**Scenario B ($(100-X)\%$ probability):** Price continues to $2,400, $2,600, $2,800...
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

**Fusion Rule:** If a counter-directional run has total slippage < $\text{tickSpacing}$, it is insufficient to rebalance the LP (from the break-even theorem). Therefore, it **fuses** with adjacent runs in the original direction.

**Intuition:** A tiny counter-move doesn't help the LP rebalance because:
1. Fees captured < $\frac{1}{2}$ tick spacing (half-spread)
2. Gamma loss from original move still exceeds fees
3. LP remains in unbalanced state - the "rebalancing" was illusory

### Toxicity Formula

After applying the fusion rule to construct directional runs:

$$\text{Toxicity} = \frac{1}{N_{\text{runs}}} \sum_{i=1}^{N_{\text{runs}}} \frac{\ln\left(\frac{\text{sqrtPrice} + \Delta\text{sqrtPrice}_i}{\text{sqrtPrice}}\right)}{f}$$

**Critical Implementation Note:** We do NOT use the same data series for $\text{fullRangeAPR}$ and $\text{Toxicity}$!

- $\text{fullRangeAPR}$ uses **absolute values** (total volume, no cancellation)
- $\text{Toxicity}$ uses **signed values** with fusion (directional persistence)

### The Critical Ratio: Toxicity / fullRangeAPR

An LP position is likely to be profitable in the long term if:

$$\frac{\text{Toxicity}}{\text{fullRangeAPR}} < 1$$

**Intuition:**
- $\text{fullRangeAPR} \propto$ fees earned (revenue potential)
- $\text{Toxicity} \propto$ gamma losses (adverse selection cost)
- When costs exceed revenue, the position is structurally unprofitable
- This ratio directly quantifies net LVR as a proportion of available fees

### Example: Two Pools with Identical APR

**Pool A (ETH/USDC - Blue Chip):**
- $\text{fullRangeAPR} = 20\%$ annualized
- $\text{Toxicity} = 5\%$ (low directional bias, balanced flow)
- $\text{Ratio} = 0.25$
- **Result:** Excellent! LPs earn $20\% - 5\% = 15\%$ net after adverse selection

**Pool B (SHIB/DOGE - Meme Coins):**
- $\text{fullRangeAPR} = 20\%$ annualized (same apparent yield!)
- $\text{Toxicity} = 24\%$ (high directional runs, persistent toxic flow)
- $\text{Ratio} = 1.2$
- **Result:** Losing money: $20\% - 24\% = -4\%$ net (negative LVR dominates)

Both pools have identical apparent yield (APR), but only Pool A is profitable. **Toxicity makes all the difference.**

---

## 4. Our Approach: Instantaneous Toxicity Filtering

### Why Volatility-Based Approaches Fail

Traditional "adaptive fees" adjust based on recent **volatility**. This is fundamentally limited because:

**Volatility is not just a measure of price movement - it's a rate that inherently depends on time:**

$$\text{Instantaneous volatility} \propto \frac{|\Delta\text{sqrtPrice}|}{\Delta t}$$

Since the time factor $\Delta t$ is involved in the measurement, volatility-based fees calculate pool parameters based on **historical data**.

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

1. **Current swap size** arriving right now: $\text{swapVolume1}$
2. **Pool's active liquidity** at this instant: $\text{activeLiquidity}$
3. **Recent directional history** (without time factor): $\text{sqrtPriceHistorique}(\beta)$

**Key Innovation:** No temporal element intervenes anywhere in the calculation.

The fee depends on:
- **What you're doing now** (swap size relative to pool depth)
- **Where the market is now** (directional imbalance accumulation)
- **Not on when** past swaps occurred (no $\Delta t$ anywhere)

This makes the system:
- **Instantaneous** (zero lag, immediate response to market state)
- **Non-predictable** (adapts to current state, not past patterns traders can game)
- **Incentive-aligned** (automatically encourages rebalancing through asymmetric pricing)
- **Manipulation-resistant** (cannot game historical data accumulation)

---

## 5. Understanding the Parameters: α and β

### Alpha (α): Toxicity Filter Strength

The parameter $\alpha$ controls how aggressively the hook filters toxic flow:

- $\alpha = 1$: Minimal filtering (baseline protection, conservative)
- $\alpha = 2$: **Moderate filtering (recommended for production)**
- $\alpha = 3$: Aggressive filtering (volatile pairs)
- $\alpha = 5$: Very aggressive (high toxicity environments, meme coins)

From the fee formula, $\alpha$ appears as a linear scaling factor on the entire fee calculation.

**Interpretation:** Higher $\alpha$ means:
- Toxic swaps (same direction as sqrtPriceHistorique) pay proportionally more
- Break-even point shifts (more swaps become unprofitable for attackers)
- Pool becomes more selective about which flow to accept
- Effective spread increases: $\text{effective spread} \approx \alpha \times f$

### Beta (β): Rebalancing Filter

The parameter $\beta$ determines what constitutes a "true" directional reversal:

- Must satisfy: $\beta > \text{tickSpacing}$
- **Optimal: $\beta \approx 1.5 \times \text{tickSpacing}$**

**Why $\beta > \text{tickSpacing}$?**

From the break-even theorem, a move of exactly 1 tick spacing is break-even for the LP. Small counter-directional moves (noise) shouldn't reset the toxicity accumulator. Only meaningful reversals should count.

Setting $\beta = 1.5 \times \text{tickSpacing}$ provides a safety margin: only reversals that generate $> 1.5\times$ the break-even threshold are considered true trend changes.

### Example: Effect of Beta

With $\text{tickSpacing} = 10$ (0.1% price movement) and $\beta = 15$ (0.15%):

- Swaps creating < 0.15% counter-directional move: **Fused** (toxicity continues accumulating)
- Swaps creating ≥ 0.15% counter-directional move: **True reversal** (toxicity resets)

This ensures only meaningful market reversals reset the directional tracking, preventing noise from masking persistent toxic flow.

---

## 6. Complete Fee Formula with All Substitutions

### Final Formula

$$\mathrm{fee\%} = \frac{\alpha}{\mathrm{currentSqrtPrice}} \times \left[\frac{\mathrm{swapVolume1}}{2 \times \mathrm{activeLiquidity}} + \mathrm{sqrtPriceHistorique}(\beta)\right]$$

**where:**
- $\mathrm{swapVolume1} = \mathrm{activeLiquidity} \times |\Delta\mathrm{sqrtPrice}|$
- $\mathrm{sqrtPriceHistorique}(\beta)$ = computed via detailed algorithm
- $\alpha$ = toxicity filter strength (typically 2)
- $\beta$ = reversal threshold $\approx 1.5 \times \mathrm{tickSpacing}$
- $\mathrm{currentSqrtPrice}$ = current square root price of the pool

> Note: This formula is only valid if you are analyzing the volumes of token 1 exchanged in the pool. For token 0, the equation differs

### Decomposition and Interpretation

**Term 1:** $\frac{\mathrm{swapVolume1}}{2 \times \mathrm{activeLiquidity}}$
- Represents immediate market impact of the current swap
- Proportional to swap size relative to pool depth
- Derived from the quadratic term in the integral
- Prevents single large swaps from bypassing fees
- Increases linearly with swap size: larger swaps pay proportionally more per unit

**Term 2:** $\mathrm{sqrtPriceHistorique}(\beta)$
- Represents accumulated directional imbalance from recent history
- Zero when market is balanced (no persistent directional flow)
- Large and positive when market has persistent one-way toxic flow
- **Asymmetric:** higher for swaps continuing the toxic direction, lower for rebalancing swaps
- Creates automatic rebalancing incentive through differential pricing

**Multiplier:** $\frac{\alpha}{\mathrm{currentSqrtPrice}}$
- Scales overall fee magnitude uniformly
- Division by $\mathrm{currentSqrtPrice}$ normalizes the fee to price units
- Higher $\alpha$ = more aggressive toxicity filtering
- Typical range: 1.5 to 3 for most pools
- Can be adjusted per pool based on asset volatility characteristics

### Key Properties

1. **Anti-fragmentation:** Splitting a swap into multiple pieces yields the same total fees
2. **Linear in swap size:** The fee percentage increases linearly with swap size through the first term
3. **Directional penalty:** The second term penalizes swaps that continue toxic trends
4. **Automatic rebalancing:** Counter-directional swaps see lower $\mathrm{sqrtPriceHistorique}(\beta)$, thus pay less (+ possibility to have an algorithm with automatic rebalancing mechanism in the hook)

### Example: Complete Fee Calculation

**Setup:**
- $\mathrm{activeLiquidity} = 50{,}000$ units
- $\mathrm{currentSqrtPrice} = 1000$ (example value)
- $\mathrm{sqrtPriceHistorique}(\beta) = 0.002$ (small bullish bias)
- $\alpha = 2$

**Scenario 1: \$5,000 buy (same direction as bias)**

$$\mathrm{fee\%} = \frac{2}{1000} \times \left[\frac{5000}{2 \times 50000} + 0.002\right]$$

$$= 0.002 \times [0.05 + 0.002]$$

$$= 0.002 \times 0.052 = 0.000104 = 0.0104\%$$

$$\mathrm{totalFees} = 0.000104 \times 5000 = \$0.52$$

**Scenario 2: \$5,000 sell (opposite direction, rebalancing)**

Assume $\mathrm{sqrtPriceHistorique}(\beta)$ for opposite direction is $0.0005$ (only sub-trend):

$$\mathrm{fee\%} = \frac{2}{1000} \times \left[\frac{5000}{2 \times 50000} + 0.0005\right]$$

$$= 0.002 \times [0.05 + 0.0005]$$

$$= 0.002 \times 0.0505 = 0.000101 = 0.0101\%$$

$$\mathrm{totalFees} = 0.000101 \times 5000 = \$0.505$$

**Rebalancing incentive:** The sell swap pays approximately 3% less in fees (0.0101% vs 0.0104%), encouraging rebalancing flow.

Over many trades, this differential compounds, creating strong economic incentive for bidirectional flow and natural market balance.
