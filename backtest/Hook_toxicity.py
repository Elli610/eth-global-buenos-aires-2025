import math
import os
import time
from datetime import datetime

import h5py
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

# from Params import initialValue
initialValue: int = 2 * 10**18
FIXED_FEE = 500


def display(msg, lvl="INFO"):
    syms = {"INFO": "ℹ️", "OK": "✅", "LOAD": "⏳", "ERR": "❌"}.get(lvl, "•")
    print(f"[{time.strftime('%H:%M:%S')}] {syms} {msg}")


def loadPoolData(poolAddr, chainId, dateStart, dateEnd):
    display("Fetching pool data...", "LOAD")
    tsData = np.load(f"dataset/{chainId}_timestamps.npy")
    dStart, dEnd = (
        datetime.strptime(dateStart, "%d-%m-%Y"),
        datetime.strptime(dateEnd, "%d-%m-%Y"),
    )
    tsStart, tsEnd = int(dStart.timestamp()), int(dEnd.timestamp())
    filt = tsData[(tsData[:, 1] >= tsStart) & (tsData[:, 1] <= tsEnd)]
    blkNums = filt[:, 0].astype(int)
    blkStart, blkEnd = int(blkNums[0]), int(blkNums[-1])
    display(f"Block range: {blkStart} to {blkEnd}", "INFO")
    poolClean = poolAddr.replace("0x", "").replace("\\x", "").lower()
    h5File = f"dataset/{poolClean}_data.h5"
    with h5py.File(h5File, "r") as f:
        blksH5 = f["blocks"][:]
        idxMask = (blksH5 >= blkStart) & (blksH5 <= blkEnd)
        idx = np.where(idxMask)[0]
        stIdx, edIdx = idx[0], idx[-1] + 1
        sqrts = f["sqrts"][stIdx:edIdx]
        liq = f["liquidity"][stIdx:edIdx]
        lens = f["lengths"][stIdx:edIdx]
        sqrtPrice = np.array(
            [sqrts[i, : lens[i]][-1] for i in range(len(sqrts))], dtype=np.float64
        )
        activeLiq = np.array(
            [liq[i, : lens[i]][-1] for i in range(len(liq))], dtype=np.float64
        )
    display(f"Loaded {len(sqrtPrice)} records", "OK")
    return sqrtPrice, activeLiq


def computeDataFrame(
    sqrtPrice, activeLiq, alpha, beta, theta, volume, Ts, degree, useFixedFee=True
):
    actualPrice, askPrice, bidPrice, askFeeList, bidFeeList = [], [], [], [], []
    trendSqrt, reversSqrt, askFee, bidFee = sqrtPrice[0], sqrtPrice[0], 0, 0
    initValue, initDelta, initSqrt, lastSqrt = (
        2 * 10**18,
        0.5,
        sqrtPrice[0],
        sqrtPrice[0],
    )
    sqrtMultiplier = 1
    T0, T1, T0fee, T1fee = (
        initValue * initDelta,
        initValue * initDelta * (lastSqrt**2),
        0,
        0,
    )
    R1size, R2size, freqArb, borneDelta = 1000, 10, 10, [0.49, 0.59]
    (
        tickRange1,
        tickRange2,
        sqrtRange1,
        sqrtRange2,
        liqRange1,
        liqRange2,
        tokenRange1,
        tokenRange2,
    ) = [-1, 1], [-1, 1], [-1, 1], [-1, 1], 0, 0, [0, 0], [0, 0]
    PetL = [0, 0]

    for idx in range(2, len(sqrtPrice)):
        actualTickSpacing = math.floor(
            math.log(sqrtPrice[idx]) / math.log(math.pow(1.0001, Ts / 2))
        )
        actualSqrt = sqrtPrice[idx]
        actualLiq = activeLiq[idx]
        actualPrice.append(actualSqrt**2)
        actualDelta = T0 / (T0 + T1 / (actualSqrt**2))
        if abs(actualSqrt - reversSqrt) / actualSqrt > beta:
            trendSqrt = reversSqrt
            reversSqrt = actualSqrt
        elif not (
            (trendSqrt > actualSqrt > reversSqrt)
            or (trendSqrt < actualSqrt < reversSqrt)
        ):
            reversSqrt = actualSqrt

        if actualSqrt > trendSqrt:
            askDeltaHistSqrt = abs(actualSqrt - trendSqrt)
            bidDeltaHistSqrt = abs(reversSqrt - actualSqrt)
        elif actualSqrt < trendSqrt:
            askDeltaHistSqrt = abs(actualSqrt - reversSqrt)
            bidDeltaHistSqrt = abs(trendSqrt - actualSqrt)
        else:
            askDeltaHistSqrt = 0
            bidDeltaHistSqrt = 0

        if useFixedFee:
            askFee = FIXED_FEE / 1_000_000
            bidFee = FIXED_FEE / 1_000_000
        else:
            askFee = (
                theta
                + alpha * (volume / (2 * actualLiq) + askDeltaHistSqrt) / actualSqrt
            )
            bidFee = (
                theta
                + alpha * (volume / (2 * actualLiq) + bidDeltaHistSqrt) / actualSqrt
            )

        # Get fees
        fixPoolFee = Ts / (2 * 10**4)
        if actualSqrt > lastSqrt:
            fixPoolFee = askFee
        else:
            fixPoolFee = bidFee
        if (
            sqrtRange1[0] < lastSqrt < sqrtRange1[1]
            or sqrtRange1[0] < actualSqrt < sqrtRange1[1]
        ):
            Pmin = max(sqrtRange1[0], min(lastSqrt, actualSqrt))
            Pmax = min(sqrtRange1[1], max(lastSqrt, actualSqrt))
            fee = (
                fixPoolFee
                * liqRange1
                * sqrtMultiplier
                * abs(1 / Pmin - 1 / Pmax if actualSqrt < lastSqrt else Pmax - Pmin)
            )
            if actualSqrt < lastSqrt:
                T0fee += fee
            elif actualSqrt > lastSqrt:
                T1fee += fee
        if (
            sqrtRange2[0] < lastSqrt < sqrtRange2[1]
            or sqrtRange2[0] < actualSqrt < sqrtRange2[1]
        ):
            Pmin = max(sqrtRange2[0], min(lastSqrt, actualSqrt))
            Pmax = min(sqrtRange2[1], max(lastSqrt, actualSqrt))
            fee = (
                fixPoolFee
                * liqRange2
                * sqrtMultiplier
                * abs(1 / Pmin - 1 / Pmax if actualSqrt < lastSqrt else Pmax - Pmin)
            )
            if actualSqrt < lastSqrt:
                T0fee += fee
            elif actualSqrt > lastSqrt:
                T1fee += fee

        # Get P&L
        if actualSqrt <= sqrtRange1[0]:
            tokenRange1 = [liqRange1 * (1 / sqrtRange1[0] - 1 / sqrtRange1[1]), 0]
        elif actualSqrt >= sqrtRange1[1]:
            tokenRange1 = [0, liqRange1 * (sqrtRange1[1] - sqrtRange1[0])]
        else:
            tokenRange1 = [
                liqRange1 * (1 / actualSqrt - 1 / sqrtRange1[1]),
                liqRange1 * (actualSqrt - sqrtRange1[0]),
            ]
        if actualSqrt <= sqrtRange2[0]:
            tokenRange2 = [liqRange2 * (1 / sqrtRange2[0] - 1 / sqrtRange2[1]), 0]
        elif actualSqrt >= sqrtRange2[1]:
            tokenRange2 = [0, liqRange2 * (sqrtRange2[1] - sqrtRange2[0])]
        else:
            tokenRange2 = [
                liqRange2 * (1 / actualSqrt - 1 / sqrtRange2[1]),
                liqRange2 * (actualSqrt - sqrtRange2[0]),
            ]

        portfolioValue = (
            T0
            + tokenRange1[0]
            + tokenRange2[0]
            + (T1 + tokenRange1[1] + tokenRange2[1]) / (actualSqrt**2)
        )
        baseValue = initialValue * initDelta * (
            initSqrt / actualSqrt
        ) ** 2 + initValue * (1 - initDelta)
        PetL.append(portfolioValue / baseValue - 1)

        # Arbitrage
        if (idx % freqArb) == 0:
            # Burn LP
            T0 += tokenRange1[0] + tokenRange2[0] + T0fee
            T1 += tokenRange1[1] + tokenRange2[1] + T1fee
            T0fee, T1fee = 0, 0
            # Range 1
            tickRange1 = [actualTickSpacing - R1size, actualTickSpacing + R1size]
            sqrtRange1 = [
                pow(1.0001, tickRange1[0] * Ts / 2),
                pow(1.0001, tickRange1[1] * Ts / 2),
            ]
            sqrtHigh1 = 1 / max(actualSqrt, sqrtRange1[0]) - 1 / sqrtRange1[1]
            sqrtLow1 = min(actualSqrt, sqrtRange1[1]) - sqrtRange1[0]
            liqRange1 = min(T0 / sqrtHigh1, T1 / sqrtLow1)
            tokenRange1 = [liqRange1 * sqrtHigh1, liqRange1 * sqrtLow1]

            # Range 2
            if actualDelta < borneDelta[0]:
                tickRange2 = [actualTickSpacing - 1, actualTickSpacing - R1size - 1]
            elif actualDelta > borneDelta[1]:
                tickRange2 = [actualTickSpacing + 1, actualTickSpacing + R2size + 1]
            if (actualDelta < borneDelta[0] or actualDelta > borneDelta[1]) and (
                not (sqrtRange2[0] < actualSqrt < sqrtRange2[1])
            ):
                sqrtRange2 = [
                    pow(1.0001, tickRange2[0] * Ts / 2),
                    pow(1.0001, tickRange2[1] * Ts / 2),
                ]
                sqrtHigh2 = 1 / max(actualSqrt, sqrtRange2[0]) - 1 / sqrtRange2[1]
                sqrtLow2 = min(actualSqrt, sqrtRange2[1]) - sqrtRange2[0]
                liqRange2 = (
                    T0 / sqrtHigh2 if actualSqrt < sqrtRange2[0] else T1 / sqrtLow2
                )
                tokenRange2 = (
                    [liqRange2 * sqrtHigh2, 0]
                    if actualSqrt < sqrtRange2[0]
                    else [0, liqRange2 * sqrtLow2]
                )
            else:
                tickRange2 = [-1, 1]
                sqrtRange2 = [-1, 1]
                liqRange2 = 0
                tokenRange2 = [0, 0]
            T0 -= tokenRange1[0] + tokenRange2[0]
            T1 -= tokenRange1[1] + tokenRange2[1]

        askFeeList.append(askFee * 100)
        bidFeeList.append(bidFee * 100)
        askPrice.append(actualSqrt**2 * (1 + askFee))
        bidPrice.append(actualSqrt**2 / (1 + bidFee))
        lastSqrt = actualSqrt
    return actualPrice, askPrice, bidPrice, askFeeList, bidFeeList, PetL


def plotAndDisplay(
    actualPrice,
    askPrice,
    bidPrice,
    askFeeList,
    bidFeeList,
    PetL,
    alpha,
    beta,
    theta,
    volume,
    sqrtPrice,
    activeLiq,
    Ts,
    degree,
):
    # Create output directory if it doesn't exist
    os.makedirs("output", exist_ok=True)

    dataFrame = pd.DataFrame(
        {
            "price": actualPrice,
            "ask": askPrice,
            "bid": bidPrice,
            "spread": np.array(askPrice) - np.array(bidPrice),
        }
    )
    print(
        f"\n{'=' * 70}\nANTI-TOXICITY BACKTEST\n{'=' * 70}\nα={alpha} | β={beta} | T={theta} | vol={volume} | pts={len(dataFrame):,}\nPrice: {dataFrame['price'].min():.2e}→{dataFrame['price'].max():.2e} (μ={dataFrame['price'].mean():.2e})\nSpread: {dataFrame['spread'].min():.6f}→{dataFrame['spread'].max():.6f} (μ={dataFrame['spread'].mean():.6f})\n{'=' * 70}\n"
    )

    PetL_aligned = PetL[2:] if len(PetL) > len(actualPrice) else PetL

    # Graph 1: Last 1000 blocks comparison - Fixed vs Variable fees
    display("Computing variable fees for comparison...", "LOAD")
    _, askPriceVar, bidPriceVar, _, _, _ = computeDataFrame(
        sqrtPrice, activeLiq, alpha, beta, theta, volume, Ts, degree, useFixedFee=False
    )

    # Take last 1000 blocks
    num_blocks = min(1000, len(actualPrice))
    start_idx = len(actualPrice) - num_blocks
    xAxis_subset = range(num_blocks)

    fig1, ax1 = plt.subplots(figsize=(16, 8))

    # Actual price
    ax1.plot(
        xAxis_subset,
        actualPrice[start_idx:],
        label="Actual Price",
        linewidth=3,
        color="#0066CC",
        alpha=0.9,
        zorder=5,
    )

    # Fixed fee bid/ask
    ax1.plot(
        xAxis_subset,
        bidPrice[start_idx:],
        label="Bid (Fixed)",
        linewidth=2,
        color="#CC0000",
        linestyle="-",
        alpha=0.75,
    )
    ax1.plot(
        xAxis_subset,
        askPrice[start_idx:],
        label="Ask (Fixed)",
        linewidth=2,
        color="#00CC00",
        linestyle="-",
        alpha=0.75,
    )

    # Variable fee bid/ask
    ax1.plot(
        xAxis_subset,
        bidPriceVar[start_idx:],
        label="Bid (Variable)",
        linewidth=2,
        color="#CC0000",
        linestyle="--",
        alpha=0.5,
    )
    ax1.plot(
        xAxis_subset,
        askPriceVar[start_idx:],
        label="Ask (Variable)",
        linewidth=2,
        color="#00CC00",
        linestyle="--",
        alpha=0.5,
    )

    # Fill between fixed spreads
    ax1.fill_between(
        xAxis_subset,
        bidPrice[start_idx:],
        askPrice[start_idx:],
        alpha=0.15,
        color="blue",
        label="Fixed Spread",
    )

    ax1.set_xlabel("Block (Last 1000)", fontsize=13, fontweight="bold")
    ax1.set_ylabel("Price", fontsize=13, fontweight="bold")
    ax1.set_title(
        "Fixed vs Variable Fees: Price with Bid/Ask Spreads (Last 1000 Blocks)",
        fontsize=16,
        fontweight="bold",
    )
    ax1.legend(loc="best", fontsize=10, ncol=2)
    ax1.grid(True, alpha=0.3, linestyle="--")
    plt.savefig("output/1_anti_toxicity.png", dpi=300, bbox_inches="tight")
    plt.close()
    display("Saved: output/1_anti_toxicity.png", "OK")

    # Graph 2: Fixed vs Variable Fees (last 1000 blocks)
    xAxis = range(len(dataFrame))
    _, _, _, askFeeListVar, bidFeeListVar, _ = computeDataFrame(
        sqrtPrice, activeLiq, alpha, beta, theta, volume, Ts, degree, useFixedFee=False
    )

    # Take last 1000 blocks
    num_blocks_fees = min(1000, len(askFeeList))
    start_idx_fees = len(askFeeList) - num_blocks_fees
    xAxis_subset_fees = range(num_blocks_fees)

    fig2, ax2 = plt.subplots(figsize=(16, 8))
    # Fixed fee - single line (they're the same for ask and bid)
    ax2.plot(
        xAxis_subset_fees,
        askFeeList[start_idx_fees:],
        label="Fixed Fee",
        linewidth=3,
        color="#1E88E5",
        alpha=0.9,
        linestyle="-",
    )
    # Variable fees - ask and bid
    ax2.plot(
        xAxis_subset_fees,
        askFeeListVar[start_idx_fees:],
        label="Ask Fee (Variable)",
        linewidth=2.5,
        color="#43A047",
        alpha=0.8,
        linestyle="--",
    )
    ax2.plot(
        xAxis_subset_fees,
        bidFeeListVar[start_idx_fees:],
        label="Bid Fee (Variable)",
        linewidth=2.5,
        color="#FB8C00",
        alpha=0.8,
        linestyle="--",
    )
    ax2.set_xlabel("Blocks", fontsize=13, fontweight="bold")
    ax2.set_ylabel("Fee (%)", fontsize=13, fontweight="bold")
    ax2.set_title(
        "Fixed vs Variable Fees Over Time (Last 1000 Blocks)",
        fontsize=16,
        fontweight="bold",
    )
    ax2.legend(loc="best", fontsize=11)
    ax2.grid(True, alpha=0.3, linestyle="--")
    plt.savefig("output/2_fees_comparison.png", dpi=300, bbox_inches="tight")
    plt.close()
    display("Saved: output/2_fees_comparison.png", "OK")

    # Graph 3: Profitability Comparison
    # Compute P&L for variable fees
    _, _, _, _, _, PetL_var = computeDataFrame(
        sqrtPrice, activeLiq, alpha, beta, theta, volume, Ts, degree, useFixedFee=False
    )
    PetL_var_aligned = PetL_var[2:] if len(PetL_var) > len(actualPrice) else PetL_var

    PetL_fixed_percent = np.array(PetL_aligned) * 100
    PetL_var_percent = np.array(PetL_var_aligned) * 100
    holding_value = np.zeros(len(xAxis))  # Holding = 0% change by definition

    fig3, ax3 = plt.subplots(figsize=(16, 8))
    ax3.plot(
        xAxis,
        PetL_fixed_percent,
        label="Fixed Fee P&L",
        linewidth=2.5,
        color="#0066CC",
        alpha=0.85,
    )
    ax3.plot(
        xAxis,
        PetL_var_percent,
        label="Variable Fee P&L",
        linewidth=2.5,
        color="#FF6600",
        alpha=0.85,
    )
    ax3.plot(
        xAxis,
        holding_value,
        label="Holding Value (Baseline)",
        linewidth=2,
        color="#000000",
        linestyle="--",
        alpha=0.7,
    )
    # Add linear line with slope 1/2
    linear_reference = np.array(xAxis) * 0.00001
    ax3.plot(
        xAxis,
        linear_reference,
        label="Variable Fee expected P&L (adjusted volume)",
        linewidth=2,
        color="#9C27B0",
        linestyle="-.",
        alpha=0.7,
    )
    ax3.axhline(y=0, color="black", linestyle="-", linewidth=1, alpha=0.5)
    ax3.set_xlabel("Block", fontsize=13, fontweight="bold")
    ax3.set_ylabel("P&L (%)", fontsize=13, fontweight="bold")
    ax3.set_title(
        "Profitability: Fixed vs Variable Fees vs Holding",
        fontsize=16,
        fontweight="bold",
    )
    ax3.legend(loc="best", fontsize=11)
    ax3.grid(True, alpha=0.3, linestyle="--")
    plt.savefig("output/3_profitability_comparison.png", dpi=300, bbox_inches="tight")
    plt.close()
    display("Saved: output/3_profitability_comparison.png", "OK")

    # Print statistics
    if len(PetL_aligned) > 0:
        print(f"\n{'=' * 70}")
        print(f"FIXED FEE P&L Statistics:")
        print(f"Final P&L: {PetL_aligned[-1] * 100:.4f}%")
        print(f"Max P&L: {max(PetL_aligned) * 100:.4f}%")
        print(f"Min P&L: {min(PetL_aligned) * 100:.4f}%")
        print(f"Mean P&L: {np.mean(PetL_aligned) * 100:.4f}%")

    if len(PetL_var_aligned) > 0:
        print(f"\nVARIABLE FEE P&L Statistics:")
        print(f"Final P&L: {PetL_var_aligned[-1] * 100:.4f}%")
        print(f"Max P&L: {max(PetL_var_aligned) * 100:.4f}%")
        print(f"Min P&L: {min(PetL_var_aligned) * 100:.4f}%")
        print(f"Mean P&L: {np.mean(PetL_var_aligned) * 100:.4f}%")
        print(f"{'=' * 70}\n")


if __name__ == "__main__":
    poolAddr = "0xc6962004f452be9203591991d15f6b388e09e8d0"
    Ts = 10
    degree = 1
    chainId = 42161
    alpha = 1
    beta = 0.0045
    theta = 0.0003
    volume = 100000 * 10**6
    dateStart = "18-11-2025"
    dateEnd = "31-12-2025"
    sqrtPrice, activeLiq = loadPoolData(poolAddr, chainId, dateStart, dateEnd)
    actualPrice, askPrice, bidPrice, askFeeList, bidFeeList, PetL = computeDataFrame(
        sqrtPrice, activeLiq, alpha, beta, theta, volume, Ts, degree, useFixedFee=True
    )
    plotAndDisplay(
        actualPrice,
        askPrice,
        bidPrice,
        askFeeList,
        bidFeeList,
        PetL,
        alpha,
        beta,
        theta,
        volume,
        sqrtPrice,
        activeLiq,
        Ts,
        degree,
    )
