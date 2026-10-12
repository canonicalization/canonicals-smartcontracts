# canonicals-smartcontracts
This repository contains the public Smart contracts of Canonicals dApp.

## Canonicals

**Canonicals** is a decentralized prediction market where users predict **precise numerical values** instead of binary yes/no outcomes.
Predictions are scored with the **TSP (Time Series Prediction)** model, which rewards both accuracy and early submission.

The platform is live in beta on **Monad**, with cross-chain oracle resolution powered by **LayerZero V2** and **Chainlink Functions**.

## Canonicals structure

| Folder             | Description                                                      |
| ------------------ | ---------------------------------------------------------------- |
| `smart-contracts/` | Solidity contracts, market factory and oracle callers...         |
| `backend/`         | FastAPI + MongoDB API with on-chain event sync                   |
| `frontend/`        | Next.js + TypeScript web app (ethers.js v6)                      |
| `docs/`            | Documentation: architecture, TSP scoring model, and guides       |

## Tech stack

- **Contracts:** Solidity, Foundry, EIP-1167 proxies, LayerZero V2, Chainlink Functions
- **Backend:** Python, FastAPI, MongoDB
- **Frontend:** Next.js, TypeScript
- **Networks:** Monad (mainnet), Sepolia (testnet), Base Sepolia (Testnet)
