![Hummingbot](https://i.ibb.co/X5zNkKw/blacklogo-with-text.png)

<img src="documentation/docs/assets/img/exmarkets_logo.png" alt="Exmarkets" width="90" />
<img src="documentation/docs/assets/img/cm_logo.png" alt="Coinmargin" width="90" />

Latest changelog:
* new API endpoint for bulk cancelling, orders are now cancelled by ids and not for whole account
* cancelling one order. Previously there was a situation then order instantly completed before cancelling, and HM crashes/hangs on cancelling. This is fixed now
* available/total balance bug fixed. Now both balances are showed correctly
* **USE WITH CAUTION** improved external price source API endpoint. Now price can be adjusted by provided percent (also negative), like this: https://exmarkets.com/api/cmc/v2/price/diamond/btc?adjust_percent=-2.2
* **USE WITH CAUTION** Allowed bid_spread, ask_spread, order_level_spread to be negative
* updated web socket ping/pong feature which caused reconnects. Further investigation needed

Running Exmarkets HM fork with Docker:

Image can be found at: 
https://hub.docker.com/r/beskofficial/hummingbot
```
docker run -it --name EXMLiq --mount "type=bind,src=$(pwd)/conf,dst=/conf/" --mount "type=bind,src=$(pwd)/data,dst=/data/" --mount "type=bind,src=$(pwd)/logs,dst=/logs/" beskofficial/hummingbot:latest
```

You need to create three folders with 777 rights.

```
src=$(pwd)/conf,dst=/conf/"
src=$(pwd)/data,dst=/data/"
src=$(pwd)/logs,dst=/logs/"
```

'src' is folder name on host machine.

'dst' is folder name in HummingBot container.

/conf folder will host config file.

For further documentation on configuration and setup, read official HummingBot documentation, as this is fork and codebase is basically the same.


----
[![Jenkins](https://jenkins-02.coinalpha.com/buildStatus/icon?job=hb_test-master_branch&subject=jenkins:master)](https://jenkins-02.coinalpha.com/job/hb_test-master_branch)
[![Jenkins](https://jenkins-02.coinalpha.com/buildStatus/icon?job=hb_test-development_branch&subject=:development)](https://jenkins-02.coinalpha.com/job/hb_test-development_branch)
[![Discord](https://img.shields.io/discord/530578568154054663.svg?color=768AD4&label=discord&logo=https%3A%2F%2Fdiscordapp.com%2Fassets%2F8c9701b98ad4372b58f13fd9f65f966e.svg)](https://discord.hummingbot.io/)
[![License](https://img.shields.io/badge/License-Apache%202.0-informational.svg)](https://github.com/CoinAlpha/hummingbot/blob/master/LICENSE)
[![Twitter Follow](https://img.shields.io/twitter/follow/hummingbot_io.svg?style=social&label=hummingbot)](https://twitter.com/hummingbot_io)

Hummingbot is an open-source project that integrates cryptocurrency trading on both **centralized exchanges** and **decentralized protocols**. It allows users to run a client that executes customized, automated trading strategies for cryptocurrencies.

We created hummingbot to promote **decentralized market-making**: enabling members of the community to contribute to the liquidity and trading efficiency in cryptocurrency markets.

## Supported centralized exchanges

| logo | id | name | ver | doc|
|:---:|:---:|:---:|:---:|:---:|
| <img src="documentation/docs/assets/img/exmarkets_logo.png" alt="Exmarkets" width="90" /> | exmarkets | [Exmarkets](https://www.exmarkets.com/) | 1 | [API](https://documenter.getpostman.com/view/2435581/S11BxgzM?version=latest) |
| <img src="documentation/docs/assets/img/cm_logo.png" alt="Coinmargin" width="90" /> | coinmargin | [Coinmargin](https://www.coinmargin.com/) | 1 | [API](https://documenter.getpostman.com/view/8795451/SVmzvxMP?version=latest) |
| <img src="https://i.ibb.co/m0YDQLd/Screen-Shot-2019-03-14-at-10-53-42-AM.png" alt="Binance" width="90" /> | binance | [Binance](https://www.binance.com/) | 3 | [API](https://github.com/binance-exchange/binance-official-api-docs/blob/master/rest-api.md) | [![Build Status](https://jenkins-02.coinalpha.com/buildStatus/icon?job=hb_test-exchange_binance&subject=test)](https://jenkins-02.coinalpha.com/job/hb_test-exchange_binance/) |
| <img src="https://i.ibb.co/h9JdGDW/cbp.jpg" alt="Coinbase Pro" width="90" /> | coinbase_pro | [Coinbase Pro](https://pro.coinbase.com/) | * | [API](https://docs.pro.coinbase.com/) | [![Build Status](https://jenkins-02.coinalpha.com/buildStatus/icon?job=hb_test-exchange_coinbase&subject=test)](https://jenkins-02.coinalpha.com/job/hb_test-exchange_coinbase/) |
|<img src="documentation/docs/assets/img/huobi_logo.png" alt="Huobi Global" width="90" />| huobi | [Huobi Global](https://www.hbg.com) | 1 | [API](https://huobiapi.github.io/docs/spot/v1/en/) | [![Build Status](https://jenkins-02.coinalpha.com/buildStatus/icon?job=hb_test-exchange_huobi&subject=test)](https://jenkins-02.coinalpha.com/job/hb_test-exchange_huobi/) |
|<img src="documentation/docs/assets/img/bittrex_logo.png" alt="Bittrex Global" width="90" height="30" />| bittrex | [Bittrex Global](https://global.bittrex.com/) | 1 | [API](https://bittrex.github.io/api/v1-1) |
| <img src="documentation/docs/assets/img/liquid_logo.png" alt="Liquid" width="90" /> | liquid | [Liquid](https://www.liquid.com/) | 2 | [API](https://developers.liquid.com/) |
| <img src="documentation/docs/assets/img/kucoin_logo.png" alt="KuCoin" width="90" /> | kucoin | [KuCoin](https://www.kucoin.com/) | 1 | [API](https://docs.kucoin.com/#general) |
| <img src="documentation/docs/assets/img/kraken_logo.png" alt="Kraken" width="90" /> | kraken | [Kraken](https://www.kraken.com/) | 1 | [API](https://www.kraken.com/features/api) |
| <img src="documentation/docs/assets/img/eterbase_logo.png" alt="Eterbase" width="90" /> | eterbase | [Eterbase](https://www.eterbase.com/) | * | [API](https://developers.eterbase.exchange/?version=latest) |

## Supported decentralized exchanges

| logo | id | name | ver | doc|
|:---:|:---:|:---:|:---:|:---:|
| <img src="documentation/docs/assets/img/radar_logo.png" alt="Radar Relay" width="90" height="30" /> | radar_relay | [Radar Relay](https://radarrelay.com/) | 2 | [API](https://developers.radarrelay.com/api/trade-api) | [![Build Status](https://jenkins-02.coinalpha.com/buildStatus/icon?job=hb_test-exchange_radar_relay&subject=test)](https://jenkins-02.coinalpha.com/job/hb_test-exchange_radar_relay/) |

## Community contributed exchange connectors

| logo | id | name | ver | doc| maintainer |
|:---:|:---:|:---:|:---:|:---:|:---:|
| <img src="https://i.ibb.co/1sPt940/Screen-Shot-2019-06-06-at-17-50-04.png" alt="Bamboo Relay" width="90" /> | bamboo_relay | [Bamboo Relay](https://bamboorelay.com/) | 3 | [API](https://sra.bamboorelay.com/) | [dex@bamboorelay.com](mailto:dex@bamboorelay.com)
|<img src="documentation/docs/assets/img/dolomite_logo.png" alt="Dolomite" width="90" />| dolomite | [Dolomite](https://dolomite.io/) | 1 | [API](https://docs.dolomite.io/) | [corey@dolomite.io](mailto:corey@dolomite.io)

## Currently available strategies

| Strategy | Test |
|--|--|
| [Pure market making](https://docs.hummingbot.io/strategies/pure-market-making/) | [![Build Status](https://jenkins-02.coinalpha.com/buildStatus/icon?job=hb_test-strategy_pure_mm&subject=test)](https://jenkins-02.coinalpha.com/job/hb_test-strategy_pure_mm/) |
| [Cross exchange market making](https://docs.hummingbot.io/strategies/cross-exchange-market-making/) | [![Build Status](https://jenkins-02.coinalpha.com/buildStatus/icon?job=hb_test-strategy_xemm&subject=test)](https://jenkins-02.coinalpha.com/job/hb_test-strategy_xemm/) |
| [Arbitrage](https://docs.hummingbot.io/strategies/arbitrage/) | [![Build Status](https://jenkins-02.coinalpha.com/buildStatus/icon?job=hb_test-strategy_arbitrage&subject=test)](https://jenkins-02.coinalpha.com/job/hb_test-strategy_arbitrage/) |

## Getting Started

### Learn more about Hummingbot

- [Website](https://hummingbot.io)
- [Documentation](https://docs.hummingbot.io)
- [FAQs](https://docs.hummingbot.io/faq/)

### Install Hummingbot

- [Quickstart guide](https://docs.hummingbot.io/quickstart/)
- [All installation options](https://docs.hummingbot.io/installation/)
- [Installation scripts](./installation/)

### Get support
- Chat with our support team on [Discord](https://discord.hummingbot.io)
- Email us at support@hummingbot.io

### Chat with other traders
- Join our community on [Discord](https://discord.coinalpha.com) or [Reddit](https://www.reddit.com/r/Hummingbot/)
- Follow Hummingbot on [Twitter](https://twitter.com/hummingbot_io)

## Contributions

We welcome contributions from the community:
- **Code and documentation contributions** via [pull requests](https://github.com/CoinAlpha/hummingbot/pulls)
- **Bug reports and feature requests** through [Github issues](https://github.com/CoinAlpha/hummingbot/issues)
- When contributing, please review the [contributing guidelines](CONTRIBUTING.md)

## About us

Hummingbot was created and is maintained by CoinAlpha, Inc. We are [a global team of engineers and traders](https://hummingbot.io/about/).

- **General**: contact us at [dev@hummingbot.io](mailto:dev@hummingbot.io) or join our [Discord server](https://discord.hummingbot.io).
- **Business inquiries**: contact us at [partnerships@hummingbot.io](mailto:partnerships@hummingbot.io).

## Legal

- **License**: Hummingbot is licensed under [Apache 2.0](./LICENSE).
- **Data collection**: read important information regarding [Hummingbot Data Collection](DATA_COLLECTION.md).
