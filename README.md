# Foundry Smart Contract Lottery

A round-based Ethereum lottery implemented in Solidity. Players enter by paying the configured minimum ETH entrance fee. Once a round has players and its configured interval has elapsed, an upkeep caller can request verifiable randomness from Chainlink VRF v2.5. The raffle uses that random word to select a winner.

## How it works

1. A player calls `enterRaffle()` with at least the entrance fee. Each address may enter once per round; any payment above the minimum is added to that round's pool.
2. After the interval elapses, `checkUpkeep()` reports whether the raffle is ready. An upkeep caller invokes `performUpkeep()` to close entries and request randomness from the configured VRF coordinator.
3. The coordinator fulfills the request. The raffle selects a winner, allocates 95% of the round's pool as winnings, accounts for the remaining 5% as fees, clears the entrants, and opens the next round.
4. The winner calls `withdrawWinnings()` to collect their credited prize. The deployment fee recipient calls `withdrawFees()` to collect accumulated fees. Both use pull payments.

## Project components

- `src/Raffle.sol` — raffle entry, upkeep checks, VRF winner selection, prize and fee accounting, and withdrawals.
- `script/HelperConfig.s.sol` — network configuration for Anvil and Sepolia. The default entrance fee is 0.01 ETH and the interval is 30 seconds.
- `script/DeployRaffle.s.sol` — deploys the raffle and registers it as a VRF subscription consumer. When the configured subscription ID is zero, it also creates and funds a subscription.
- `script/Interactions.s.sol` — scripts for creating and funding VRF subscriptions and adding consumers.
- `test/` — unit and integration tests using Foundry and Chainlink VRF mocks.

## Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, and `anvil`)
- Git

## Install dependencies

```sh
make install
```

The install target uses Foundry DevOps, Chainlink `chainlink-evm`, OpenZeppelin Contracts, and Forge Std.

## Build and test

```sh
forge build
forge test
forge test --match-path test/integration/interactions.t.sol
```

Start a local Anvil chain when you want to run deployment scripts against a local network:

```sh
anvil
```

## Deployment

The deployment script reads network settings from `HelperConfig.s.sol`. For Sepolia, provide the RPC URL and deployer private key in your environment (the Makefile loads `.env`), then run:

```sh
make deploy ARGS="--network sepolia"
```

For local deployment, start Anvil in another terminal and run:

```sh
make deploy
```

The local configuration creates a VRF mock coordinator and LINK token. On Sepolia, configure a funded VRF v2.5 subscription, coordinator, gas lane, callback gas limit, LINK token, and deployer account before deployment. Keep private keys and RPC credentials out of source control.

## Useful Foundry commands

```sh
forge fmt       # Format Solidity files
forge snapshot  # Record gas snapshots
cast --help     # Explore Cast commands
```
