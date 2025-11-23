setup:

```
python3 -m venv venv
source venv/bin/activate
pip install h5py matplotlib numpy pandas
```

note:
- provided backtest data are from the [Uniswap V3 WETH/USDC (fee: 500)](https://arbiscan.io/address/0xc6962004f452be9203591991d15f6b388e09e8d0) pool on arbitrum one, block interval: 401412426 to 403076967 (130931 rows)
- for simplicity, the backtest only uses the deltaSqrtPrice between the beginning of the block and the last so if multiple swap happen in the block, we consider them as only 1 swap -> this means the fees generated are lower than what actually happened (but close enough to reality to be ok for the hackathon)
- we emulated the hook over swaps that happened on a pool with fixed fees. If the hooks had been deployed, the volumes would have been differents (because of the variable fees (lower fees means more volume and higher fees means less volume))
- Tx fees have not been taken into account
