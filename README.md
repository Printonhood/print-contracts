# Print

**The launchpad where every coin has a floor.**

Launch a coin against a real market: a stock, a metal, a currency. Every trade on that coin buys the real asset and locks it in a vault nobody can sell. The only way anything leaves the vault is a holder burning coins to claim their share, so the backing behind each coin can only rise.

> The token is the upside. The stock is the floor.

Built on Robinhood Chain (chain id 4663).

---

## How it works

1. **Launch.** `PrintFactory.launch(name, symbol, backingAsset)` deploys a coin and its vault in one transaction. The factory has no owner, holds no funds and cannot touch a coin once it exists.
2. **Trade.** Every coin carries its own constant-product market, priced in native ETH, so it trades from the first block without needing a DEX pool of its own.
3. **Fill the vault.** Every buy and every sell buys the backing asset on Uniswap V4 and sends it straight to that coin's vault.
4. **Redeem.** Burn coins and receive `amount × vault ÷ supply` of the backing asset. This is the only exit the vault has.

## The invariant

**Backing per coin never decreases.** Not as a policy, as arithmetic:

- **Supply is fixed at construction.** Buys and sells move coins between the holder and the contract. Nothing is ever minted.
- **Trades only ever add to the vault.** There is no path that takes backing out except `redeem`.
- **Redeeming is ratio-neutral.** `redeem` pays exactly `amount × vault ÷ supply` and burns exactly `amount`, which leaves `vault ÷ supply` unchanged for everyone who stays.

Asserted directly in the test suite, including a fuzz test across mixed buys, sells and redemptions.

## The vault

`PrintVault` is deliberately small. Read it, it is 41 lines.

| | |
|---|---|
| Owner | None |
| Admin | None |
| Pause switch | None |
| Rescue / sweep | None |
| Upgrade path | None |
| Exit | `payout`, callable only by its own coin, and only from `redeem` |

Nobody can sell what is in a Print vault. Not even us.

## Contracts

| File | What it does |
|---|---|
| [`src/PrintFactory.sol`](src/PrintFactory.sol) | Launches coin + vault pairs. `boardRow(i)` returns everything a front end needs in one call. |
| [`src/PrintCoin.sol`](src/PrintCoin.sol) | ERC-20 with a built-in constant-product market, backing purchases and `redeem`. |
| [`src/PrintVault.sol`](src/PrintVault.sol) | Holds the backing asset. One exit. |
| [`src/V4BackingRouter.sol`](src/V4BackingRouter.sol) | Buys the backing asset through the Uniswap V4 PoolManager on Robinhood Chain. |

## Deployed on Robinhood Chain

| Contract | Address |
|---|---|
| PrintFactory | `0x2513271927998159670495ed24f58be49630365d` |
| V4BackingRouter | `0xdc2ddcf89ca36d4c33ef1d7cc7f866bd01375e99` |
| Uniswap V4 PoolManager (external) | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |

## Build and test

Requires [Foundry](https://book.getfoundry.sh/).

```shell
git clone --recursive https://github.com/Printonhood/print-contracts
cd print-contracts
forge build
forge test
```

The suite has 22 tests. 17 run locally against mocks. 5 run forked against the live chain, with no mocks: the real PoolManager, a real pool, a real asset.

```shell
forge test --match-contract ForkV4 --fork-url robinhood -vv
```

Those fork tests exist because they caught three bugs every mock passed. The notes are in the source comments.

## Links

- X: [@Printonhood](https://x.com/Printonhood)

## License

[MIT](LICENSE)
