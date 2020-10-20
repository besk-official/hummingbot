import aiohttp
from aiohttp.test_utils import TestClient
import asyncio
from async_timeout import timeout
import conf
from datetime import datetime
from decimal import Decimal
from libc.stdint cimport int64_t
import logging
import pandas as pd
import re
import time
from typing import (
    Any,
    AsyncIterable,
    Coroutine,
    Dict,
    List,
    Optional,
    Tuple
)
import ujson

import hummingbot
from hummingbot.core.clock cimport Clock
from hummingbot.core.data_type.cancellation_result import CancellationResult
from hummingbot.core.data_type.limit_order import LimitOrder
from hummingbot.core.data_type.order_book cimport OrderBook
from hummingbot.core.data_type.order_book_tracker import OrderBookTrackerDataSourceType
from hummingbot.core.data_type.transaction_tracker import TransactionTracker
from hummingbot.core.event.events import (
    MarketEvent,
    MarketWithdrawAssetEvent,
    BuyOrderCompletedEvent,
    SellOrderCompletedEvent,
    OrderFilledEvent,
    OrderCancelledEvent,
    BuyOrderCreatedEvent,
    SellOrderCreatedEvent,
    MarketTransactionFailureEvent,
    MarketOrderFailureEvent,
    OrderType,
    TradeType,
    TradeFee
)
from hummingbot.core.network_iterator import NetworkStatus
from hummingbot.core.utils.async_call_scheduler import AsyncCallScheduler
from hummingbot.core.utils.async_utils import (
    safe_ensure_future,
    safe_gather,
)
from hummingbot.logger import HummingbotLogger
from hummingbot.market.coinmargin.coinmargin_api_order_book_data_source import CoinmarginAPIOrderBookDataSource
from hummingbot.market.coinmargin.coinmargin_auth import CoinmarginAuth
from hummingbot.market.coinmargin.coinmargin_in_flight_order import CoinmarginInFlightOrder
from hummingbot.market.coinmargin.coinmargin_order_book_tracker import CoinmarginOrderBookTracker
from hummingbot.market.trading_rule cimport TradingRule
from hummingbot.market.market_base import (
    MarketBase,
    NaN,
    s_decimal_NaN)
from hummingbot.core.utils.tracking_nonce import get_tracking_nonce
from hummingbot.client.config.fee_overrides_config_map import fee_overrides_config_map
from hummingbot.core.utils.estimate_fee import estimate_fee

hm_logger = None
s_decimal_0 = Decimal(0)
TRADING_PAIR_SPLITTER = re.compile(r"^(\w+)(usdt|vndc|btc|eth|eur|usdc)$")
COINMARGIN_ROOT_API = "https://coinmargin.com/api/"


class CoinmarginAPIError(IOError):
    def __init__(self, error_payload: Dict[str, Any]):
        super().__init__(str(error_payload))
        self.error_payload = error_payload


cdef class CoinmarginMarketTransactionTracker(TransactionTracker):
    cdef:
        CoinmarginMarket _owner

    def __init__(self, owner: CoinmarginMarket):
        super().__init__()
        self._owner = owner

    cdef c_did_timeout_tx(self, str tx_id):
        TransactionTracker.c_did_timeout_tx(self, tx_id)
        self._owner.c_did_timeout_tx(tx_id)


cdef class CoinmarginMarket(MarketBase):
    MARKET_RECEIVED_ASSET_EVENT_TAG = MarketEvent.ReceivedAsset.value
    MARKET_BUY_ORDER_COMPLETED_EVENT_TAG = MarketEvent.BuyOrderCompleted.value
    MARKET_SELL_ORDER_COMPLETED_EVENT_TAG = MarketEvent.SellOrderCompleted.value
    MARKET_WITHDRAW_ASSET_EVENT_TAG = MarketEvent.WithdrawAsset.value
    MARKET_ORDER_CANCELLED_EVENT_TAG = MarketEvent.OrderCancelled.value
    MARKET_TRANSACTION_FAILURE_EVENT_TAG = MarketEvent.TransactionFailure.value
    MARKET_ORDER_FAILURE_EVENT_TAG = MarketEvent.OrderFailure.value
    MARKET_ORDER_FILLED_EVENT_TAG = MarketEvent.OrderFilled.value
    MARKET_BUY_ORDER_CREATED_EVENT_TAG = MarketEvent.BuyOrderCreated.value
    MARKET_SELL_ORDER_CREATED_EVENT_TAG = MarketEvent.SellOrderCreated.value
    API_CALL_TIMEOUT = 10.0
    UPDATE_ORDERS_INTERVAL = 10.0

    @classmethod
    def logger(cls) -> HummingbotLogger:
        global hm_logger
        if hm_logger is None:
            hm_logger = logging.getLogger(__name__)
        return hm_logger

    def __init__(self,
                 coinmargin_api_key: str,
                 coinmargin_secret_key: str,
                 poll_interval: float = 5.0,
                 order_book_tracker_data_source_type: OrderBookTrackerDataSourceType =
                 OrderBookTrackerDataSourceType.EXCHANGE_API,
                 trading_pairs: Optional[List[str]] = None,
                 trading_required: bool = True):

        super().__init__()
        self._async_scheduler = AsyncCallScheduler(call_interval=0.5)
        self._data_source_type = order_book_tracker_data_source_type
        self._ev_loop = asyncio.get_event_loop()
        self._coinmargin_auth = CoinmarginAuth(api_key=coinmargin_api_key, secret_key=coinmargin_secret_key)
        self._in_flight_orders = {}
        self._last_poll_timestamp = 0
        self._last_timestamp = 0
        self._order_book_tracker = CoinmarginOrderBookTracker(
            data_source_type=order_book_tracker_data_source_type,
            trading_pairs=trading_pairs
        )
        self._poll_notifier = asyncio.Event()
        self._poll_interval = poll_interval
        self._shared_client = None
        self._status_polling_task = None
        self._trading_required = trading_required
        self._trading_rules = {}
        self._trading_rules_polling_task = None
        self._tx_tracker = CoinmarginMarketTransactionTracker(self)

    @staticmethod
    def split_trading_pair(trading_pair: str) -> Optional[Tuple[str, str]]:
        try:
            m = trading_pair.split('-')
            return m[0], m[1]
        # Exceptions are now logged as warnings in trading pair fetcher
        except Exception as e:
            return None

    @staticmethod
    def convert_from_exchange_trading_pair(exchange_trading_pair: str) -> Optional[str]:
        if CoinmarginMarket.split_trading_pair(exchange_trading_pair.replace("-", "")) is None:
            return None
        # Coinmargin uses lowercase (btc-usdt)
        base_asset, quote_asset = CoinmarginMarket.split_trading_pair(exchange_trading_pair.replace("-", ""))
        return f"{base_asset.upper()}-{quote_asset.upper()}"

    @staticmethod
    def convert_to_exchange_trading_pair(hb_trading_pair: str) -> str:
        # Coinmargin uses lowercase (btc-usdt)
        return hb_trading_pair.lower()

    @property
    def name(self) -> str:
        return "coinmargin"

    @property
    def order_book_tracker(self) -> CoinmarginOrderBookTracker:
        return self._order_book_tracker

    @property
    def order_books(self) -> Dict[str, OrderBook]:
        return self._order_book_tracker.order_books

    @property
    def trading_rules(self) -> Dict[str, TradingRule]:
        return self._trading_rules

    @property
    def in_flight_orders(self) -> Dict[str, CoinmarginInFlightOrder]:
        return self._in_flight_orders

    @property
    def limit_orders(self) -> List[LimitOrder]:
        return [
            in_flight_order.to_limit_order()
            for in_flight_order in self._in_flight_orders.values()
        ]

    @property
    def tracking_states(self) -> Dict[str, Any]:
        return {
            key: value.to_json()
            for key, value in self._in_flight_orders.items()
        }

    def restore_tracking_states(self, saved_states: Dict[str, Any]):
        self._in_flight_orders.update({
            key: CoinmarginInFlightOrder.from_json(value)
            for key, value in saved_states.items()
        })

    @property
    def shared_client(self) -> str:
        return self._shared_client

    @shared_client.setter
    def shared_client(self, client: aiohttp.ClientSession):
        self._shared_client = client

    async def get_active_exchange_markets(self) -> pd.DataFrame:
        return await CoinmarginAPIOrderBookDataSource.get_active_exchange_markets()

    cdef c_start(self, Clock clock, double timestamp):
        self._tx_tracker.c_start(clock, timestamp)
        MarketBase.c_start(self, clock, timestamp)

    cdef c_stop(self, Clock clock):
        MarketBase.c_stop(self, clock)
        self._async_scheduler.stop()

    async def start_network(self):
        self._stop_network()
        self._order_book_tracker.start()
        self._trading_rules_polling_task = safe_ensure_future(self._trading_rules_polling_loop())
        if self._trading_required:
            self._status_polling_task = safe_ensure_future(self._status_polling_loop())

    def _stop_network(self):
        self._order_book_tracker.stop()
        if self._status_polling_task is not None:
            self._status_polling_task.cancel()
            self._status_polling_task = None
        if self._trading_rules_polling_task is not None:
            self._trading_rules_polling_task.cancel()
            self._trading_rules_polling_task = None

    async def stop_network(self):
        self._stop_network()

    async def check_network(self) -> NetworkStatus:
        try:
            await self._api_request(method="get", path_url="trade/v1/version")
        except asyncio.CancelledError:
            raise
        except Exception as e:
            return NetworkStatus.NOT_CONNECTED
        return NetworkStatus.CONNECTED

    cdef c_tick(self, double timestamp):
        cdef:
            int64_t last_tick = <int64_t>(self._last_timestamp / self._poll_interval)
            int64_t current_tick = <int64_t>(timestamp / self._poll_interval)
        MarketBase.c_tick(self, timestamp)
        self._tx_tracker.c_tick(timestamp)
        if current_tick > last_tick:
            if not self._poll_notifier.is_set():
                self._poll_notifier.set()
        self._last_timestamp = timestamp

    async def _http_client(self) -> aiohttp.ClientSession:
        if self._shared_client is None:
            self._shared_client = aiohttp.ClientSession()
        return self._shared_client

    async def _api_request(self,
                           method,
                           path_url,
                           params: Optional[Dict[str, Any]] = None,
                           data: Optional[Dict[str, Any]] = None,
                           is_auth_required: bool = False) -> Dict[str, Any]:
        args = {
            "timestamp": self._coinmargin_auth.make_timestamp(),
            "nonce": self._coinmargin_auth.make_nonce(),
        }
        self.logger().network(f"Making request {str(args['nonce'])} to {path_url}")
        if params is not None:
            params.update(args)
        else:
            params = args

        tempParams = params
        if data is not None:
            tempParams.update(data)
        headers = {}
        if method == "post":
            headers = {"Content-Type": "application/json"}
        if is_auth_required:
            headers.update(self._coinmargin_auth.generate_headers(method, path_url, tempParams))

        url = COINMARGIN_ROOT_API + path_url
        client = await self._http_client()

        # aiohttp TestClient requires path instead of url
        if isinstance(client, TestClient):
            response_coro = client.request(
                method=method.upper(),
                path=f"/{path_url}",
                headers=headers,
                params=params,
                data=ujson.dumps(data),
                timeout=100
            )
        else:
            response_coro = client.request(
                method=method.upper(),
                url=url,
                headers=headers,
                params=params,
                data=data is None if None else ujson.dumps(data),
                timeout=100
            )

        async with response_coro as response:
            if response.status != 200:
                message = await response.json()
                self.logger().error(f"Error body: {str(message)}, Query: {str(params)}, Body: {str(data)}, URL: {url}")
                raise IOError(f"Error fetching data from {url}. HTTP status is {response.status}.")
            try:
                parsed_response = await response.json()
            except Exception:
                raise IOError(f"Error parsing data from {url}.")

            data = parsed_response
            if data is None:
                self.logger().error(f"Error received from {url}. Response is {data}.")
                raise CoinmarginAPIError({"error": parsed_response})
            return data

    async def _update_balances(self):
        cdef:
            str path_url = "trade/v1/account/balance"
            dict data
            list balances
            dict new_available_balances = {}
            dict new_balances = {}
            str asset_name
            object balance

        data = await self._api_request("get", path_url=path_url, is_auth_required=True)
        balances = data.get("wallets", [])
        if len(balances) > 0:
            for balance_entry in balances:
                asset_name = balance_entry["currency"].lower()
                balance = Decimal(balance_entry["total"])
                balanceAvailable = Decimal(balance_entry["available"])
                if balance == s_decimal_0:
                    continue
                if asset_name not in new_available_balances:
                    new_available_balances[asset_name] = s_decimal_0
                if asset_name not in new_balances:
                    new_balances[asset_name] = s_decimal_0

                new_balances[asset_name] = balanceAvailable
                new_available_balances[asset_name] = balance

            self._account_available_balances.clear()
            self._account_available_balances = new_balances
            self._account_balances.clear()
            self._account_balances = new_available_balances

    cdef object c_get_fee(self,
                          str base_currency,
                          str quote_currency,
                          object order_type,
                          object order_side,
                          object amount,
                          object price):

        is_maker = order_type is OrderType.LIMIT
        return estimate_fee("coinmargin", is_maker)

    async def _update_trading_rules(self):
        cdef:
            # The poll interval for trade rules is 60 seconds.
            int64_t last_tick = <int64_t>(self._last_timestamp / 60.0)
            int64_t current_tick = <int64_t>(self._current_timestamp / 60.0)
        if current_tick > last_tick or len(self._trading_rules) < 1:
            exchange_info = await self._api_request("get", path_url="v1/general/info")
            trading_rules_list = self._format_trading_rules(exchange_info.get("markets", []))
            self._trading_rules.clear()
            for trading_rule in trading_rules_list:
                self._trading_rules[trading_rule.trading_pair] = trading_rule

    def _format_trading_rules(self, raw_trading_pair_info: List[Dict[str, Any]]) -> List[TradingRule]:
        cdef:
            list trading_rules = []

        for info in raw_trading_pair_info:
            try:
                trading_rules.append(
                    TradingRule(trading_pair=info["slug"],
                                min_order_size=Decimal(info["min_amount"]),
                                max_order_size=Decimal(999999999),
                                min_price_increment=Decimal(f"1e-{info['price_precision']}"),
                                min_base_amount_increment=Decimal(f"1e-{info['base_precision']}"),
                                min_quote_amount_increment=Decimal(f"1e-{info['base_precision']}"),
                                min_notional_size=Decimal(info["min_amount"]) * Decimal(info["last_price"] if info["last_price"] else 0))
                )
            except Exception as e:
                self.logger().error(f"Error parsing the trading pair rule {info}. Exception: {str(e)}. Skipping.", exc_info=True)
        return trading_rules

    async def get_order_status(self, exchange_order_id: str) -> Dict[str, Any]:
        """
        {
            "id":64,
            "type":"limit",
            "side":"buy",
            "market":"ltc-btc",
            "amount":"0.01000000",
            "current_amount":"0.01000000",
            "price":"0.02000000",
            "status":"completed",
            "timestamp":1518448210,
            "fee_taken":"0.00000005",
            "fee_fixed":"0.00000000",
            "fee_percent":"0.03000000",
            "transactions": [{
                "id":81,
                "status":"completed",
                "amount":"0.01000000",
                "price":"0.01822000",
                "fee":"0.00000005",
                "timestamp":1518448210}
            ]}
        """
        path_url = f"trade/v1/orders/{exchange_order_id}"
        return await self._api_request("get", path_url=path_url, is_auth_required=True)

    async def _update_order_status(self):
        cdef:
            # The poll interval for order status is 10 seconds.
            int64_t last_tick = <int64_t>(self._last_poll_timestamp / self.UPDATE_ORDERS_INTERVAL)
            int64_t current_tick = <int64_t>(self._current_timestamp / self.UPDATE_ORDERS_INTERVAL)

        if current_tick > last_tick and len(self._in_flight_orders) > 0:
            tracked_orders = list(self._in_flight_orders.values())
            for tracked_order in tracked_orders:
                exchange_order_id = tracked_order.exchange_order_id
                try:
                    order_update = await self.get_order_status(exchange_order_id)
                except CoinmarginAPIError as e:
                    err_code = e.error_payload.get("error").get("err-code")
                    self.c_stop_tracking_order(tracked_order.client_order_id)
                    self.logger().info(f"The limit order {tracked_order.client_order_id} "
                                       f"has failed according to order status API. - {err_code}")
                    self.c_trigger_event(
                        self.MARKET_ORDER_FAILURE_EVENT_TAG,
                        MarketOrderFailureEvent(
                            self._current_timestamp,
                            tracked_order.client_order_id,
                            tracked_order.order_type
                        )
                    )
                    continue

                if order_update is None:
                    self.logger().network(
                        f"Error fetching status update for the order {tracked_order.client_order_id}: "
                        f"{order_update}."
                    )
                    continue

                order_state = order_update["status"]
                # possible order statuses are "open", "completed", "cancelled", "pending_cancel"

                if order_state not in ["open", "completed", "cancelled", "pending_cancel"]:
                    self.logger().debug(f"Unrecognized order update response - {order_update}")

                # Calculate the newly executed amount for this update.
                tracked_order.last_state = order_state
                new_confirmed_amount = Decimal(order_update["current_amount"])
                execute_amount_diff = new_confirmed_amount - tracked_order.executed_amount_base

                if execute_amount_diff > s_decimal_0:
                    tracked_order.executed_amount_base = new_confirmed_amount
                    tracked_order.executed_amount_quote = new_confirmed_amount * Decimal(order_update["price"])
                    tracked_order.fee_paid = Decimal(order_update["fee_taken"])
                    execute_price = Decimal(order_update["price"])
                    order_filled_event = OrderFilledEvent(
                        self._current_timestamp,
                        tracked_order.client_order_id,
                        tracked_order.trading_pair,
                        tracked_order.trade_type,
                        tracked_order.order_type,
                        execute_price,
                        execute_amount_diff,
                        self.c_get_fee(
                            tracked_order.base_asset,
                            tracked_order.quote_asset,
                            tracked_order.order_type,
                            tracked_order.trade_type,
                            execute_price,
                            execute_amount_diff,
                        ),
                        exchange_trade_id=exchange_order_id
                    )
                    self.logger().info(f"Filled {execute_amount_diff} out of {tracked_order.amount} of the "
                                       f"order {tracked_order.client_order_id}.")
                    self.c_trigger_event(self.MARKET_ORDER_FILLED_EVENT_TAG, order_filled_event)

                if tracked_order.is_open:
                    continue

                if tracked_order.is_done:
                    if not tracked_order.is_cancelled:  # Handles "completed" order
                        self.c_stop_tracking_order(tracked_order.client_order_id)
                        if tracked_order.trade_type is TradeType.BUY:
                            self.logger().info(f"The market buy order {tracked_order.client_order_id} has completed "
                                               f"according to order status API.")
                            self.c_trigger_event(self.MARKET_BUY_ORDER_COMPLETED_EVENT_TAG,
                                                 BuyOrderCompletedEvent(self._current_timestamp,
                                                                        tracked_order.client_order_id,
                                                                        tracked_order.base_asset,
                                                                        tracked_order.quote_asset,
                                                                        tracked_order.fee_asset or tracked_order.base_asset,
                                                                        tracked_order.executed_amount_base,
                                                                        tracked_order.executed_amount_quote,
                                                                        tracked_order.fee_paid,
                                                                        tracked_order.order_type))
                        else:
                            self.logger().info(f"The market sell order {tracked_order.client_order_id} has completed "
                                               f"according to order status API.")
                            self.c_trigger_event(self.MARKET_SELL_ORDER_COMPLETED_EVENT_TAG,
                                                 SellOrderCompletedEvent(self._current_timestamp,
                                                                         tracked_order.client_order_id,
                                                                         tracked_order.base_asset,
                                                                         tracked_order.quote_asset,
                                                                         tracked_order.fee_asset or tracked_order.quote_asset,
                                                                         tracked_order.executed_amount_base,
                                                                         tracked_order.executed_amount_quote,
                                                                         tracked_order.fee_paid,
                                                                         tracked_order.order_type))
                    else:  # Handles "canceled" or "partial-canceled" order
                        self.c_stop_tracking_order(tracked_order.client_order_id)
                        self.logger().info(f"The market order {tracked_order.client_order_id} "
                                           f"has been cancelled according to order status API.")
                        self.c_trigger_event(self.MARKET_ORDER_CANCELLED_EVENT_TAG,
                                             OrderCancelledEvent(self._current_timestamp,
                                                                 tracked_order.client_order_id))

    async def _status_polling_loop(self):
        while True:
            try:
                self._poll_notifier = asyncio.Event()
                await self._poll_notifier.wait()

                await safe_gather(
                    self._update_balances(),
                    self._update_order_status(),
                )
                self._last_poll_timestamp = self._current_timestamp
            except asyncio.CancelledError:
                raise
            except Exception as e:
                self.logger().network("Unexpected error while fetching account updates.",
                                      exc_info=True)
                await asyncio.sleep(0.5)

    async def _trading_rules_polling_loop(self):
        while True:
            try:
                await self._update_trading_rules()
                await asyncio.sleep(60 * 5)
            except asyncio.CancelledError:
                raise
            except Exception:
                self.logger().network("Unexpected error while fetching trading rules.",
                                      exc_info=True)
                await asyncio.sleep(0.5)

    @property
    def status_dict(self) -> Dict[str, bool]:
        return {
            "account_id_initialized": True,
            "order_books_initialized": self._order_book_tracker.ready,
            "account_balance": len(self._account_balances) > 0 if self._trading_required else True,
            "trading_rule_initialized": len(self._trading_rules) > 0
        }

    @property
    def ready(self) -> bool:
        return all(self.status_dict.values())

    async def place_order(self,
                          order_id: str,
                          trading_pair: str,
                          amount: Decimal,
                          is_buy: bool,
                          order_type: OrderType,
                          price: Decimal) -> str:
        path_url = "trade/v1/orders/buy" if is_buy else "trade/v1/orders/sell"
        order_type_str = "limit" if order_type is OrderType.LIMIT else "market"
        params = {
            "amount": f"{amount.normalize():f}",
            "market": trading_pair,
            "type": order_type_str,
        }
        if order_type is OrderType.LIMIT:
            params["price"] = f"{price.normalize():f}"
        exchange_order = await self._api_request(
            "post",
            path_url=path_url,
            params=None,
            data=params,
            is_auth_required=True
        )
        return str(exchange_order.get("id"))

    async def execute_buy(self,
                          order_id: str,
                          trading_pair: str,
                          amount: Decimal,
                          order_type: OrderType,
                          price: Optional[Decimal] = s_decimal_0):
        cdef:
            TradingRule trading_rule = self._trading_rules[trading_pair]
            object quote_amount
            object decimal_amount
            object decimal_price
            str exchange_order_id
            object tracked_order

        if order_type is OrderType.MARKET:
            quote_amount = self.c_get_quote_volume_for_base_amount(trading_pair, True, amount).result_volume
            # Quantize according to price rules, not base token amount rules.
            decimal_amount = self.c_quantize_order_price(trading_pair, Decimal(quote_amount))
            decimal_price = s_decimal_0
        else:
            decimal_amount = self.c_quantize_order_amount(trading_pair, amount)
            decimal_price = self.c_quantize_order_price(trading_pair, price)
            if decimal_amount < trading_rule.min_order_size:
                raise ValueError(f"Buy order amount {decimal_amount} is lower than the minimum order size "
                                 f"{trading_rule.min_order_size}.")
        try:
            exchange_order_id = await self.place_order(order_id, trading_pair, decimal_amount, True, order_type, decimal_price)
            self.c_start_tracking_order(
                client_order_id=order_id,
                exchange_order_id=exchange_order_id,
                trading_pair=trading_pair,
                order_type=order_type,
                trade_type=TradeType.BUY,
                price=decimal_price,
                amount=decimal_amount
            )
            tracked_order = self._in_flight_orders.get(order_id)
            if tracked_order is not None:
                self.logger().info(f"Created {order_type} buy order {order_id} for {decimal_amount} {trading_pair}.")
            self.c_trigger_event(self.MARKET_BUY_ORDER_CREATED_EVENT_TAG,
                                 BuyOrderCreatedEvent(
                                     self._current_timestamp,
                                     order_type,
                                     trading_pair,
                                     decimal_amount,
                                     decimal_price,
                                     order_id
                                 ))
        except asyncio.CancelledError:
            raise
        except Exception as e:
            self.c_stop_tracking_order(order_id)
            order_type_str = "MARKET" if order_type == OrderType.MARKET else "LIMIT"
            self.logger().network(
                f"Error submitting buy {order_type_str} order to Coinmargin for "
                f"{decimal_amount} {trading_pair} "
                f"{decimal_price if order_type is OrderType.LIMIT else ''}.",
                exc_info=True
            )
            self.c_trigger_event(self.MARKET_ORDER_FAILURE_EVENT_TAG,
                                 MarketOrderFailureEvent(self._current_timestamp, order_id, order_type))

    cdef str c_buy(self,
                   str trading_pair,
                   object amount,
                   object order_type=OrderType.MARKET,
                   object price=s_decimal_0,
                   dict kwargs={}):
        cdef:
            int64_t tracking_nonce = <int64_t> get_tracking_nonce()
            str order_id = f"buy-{trading_pair}-{tracking_nonce}"

        safe_ensure_future(self.execute_buy(order_id, trading_pair, amount, order_type, price))
        return order_id

    async def execute_sell(self,
                           order_id: str,
                           trading_pair: str,
                           amount: Decimal,
                           order_type: OrderType,
                           price: Optional[Decimal] = s_decimal_0):
        cdef:
            TradingRule trading_rule = self._trading_rules[trading_pair]
            object decimal_amount
            object decimal_price
            str exchange_order_id
            object tracked_order

        decimal_amount = self.quantize_order_amount(trading_pair, amount)
        decimal_price = (self.c_quantize_order_price(trading_pair, price)
                         if order_type is OrderType.LIMIT
                         else s_decimal_0)
        if decimal_amount < trading_rule.min_order_size:
            raise ValueError(f"Sell order amount {decimal_amount} is lower than the minimum order size "
                             f"{trading_rule.min_order_size}.")

        try:
            exchange_order_id = await self.place_order(order_id, trading_pair, decimal_amount, False, order_type, decimal_price)
            self.c_start_tracking_order(
                client_order_id=order_id,
                exchange_order_id=exchange_order_id,
                trading_pair=trading_pair,
                order_type=order_type,
                trade_type=TradeType.SELL,
                price=decimal_price,
                amount=decimal_amount
            )
            tracked_order = self._in_flight_orders.get(order_id)
            if tracked_order is not None:
                self.logger().info(f"Created {order_type} sell order {order_id} for {decimal_amount} {trading_pair}.")
            self.c_trigger_event(self.MARKET_SELL_ORDER_CREATED_EVENT_TAG,
                                 SellOrderCreatedEvent(
                                     self._current_timestamp,
                                     order_type,
                                     trading_pair,
                                     decimal_amount,
                                     decimal_price,
                                     order_id
                                 ))
        except asyncio.CancelledError:
            raise
        except Exception:
            self.c_stop_tracking_order(order_id)
            order_type_str = "MARKET" if order_type is OrderType.MARKET else "LIMIT"
            self.logger().network(
                f"Error submitting sell {order_type_str} order to Coinmargin for "
                f"{decimal_amount} {trading_pair} "
                f"{decimal_price if order_type is OrderType.LIMIT else ''}.",
                exc_info=True
            )
            self.c_trigger_event(self.MARKET_ORDER_FAILURE_EVENT_TAG,
                                 MarketOrderFailureEvent(self._current_timestamp, order_id, order_type))

    cdef str c_sell(self,
                    str trading_pair,
                    object amount,
                    object order_type=OrderType.MARKET, object price=s_decimal_0,
                    dict kwargs={}):
        cdef:
            int64_t tracking_nonce = <int64_t> get_tracking_nonce()
            str order_id = f"sell-{trading_pair}-{tracking_nonce}"
        safe_ensure_future(self.execute_sell(order_id, trading_pair, amount, order_type, price))
        return order_id

    async def execute_cancel(self, trading_pair: str, order_id: str):
        try:
            tracked_order = self._in_flight_orders.get(order_id)
            if tracked_order is None:
                raise ValueError(f"Failed to cancel order - {order_id}. Order not found.")
            path_url = f"trade/v1/orders/{tracked_order.exchange_order_id}"
            response = await self._api_request("delete", path_url=path_url, is_auth_required=True)

            if response.get("status") == "cancel_pending":
                self.c_stop_tracking_order(tracked_order.client_order_id)
                self.logger().info(f"The order {tracked_order.client_order_id} was cancelled"
                                   f" by API. order_state - cancel_pending")
                self.c_trigger_event(self.MARKET_ORDER_CANCELLED_EVENT_TAG,
                                     OrderCancelledEvent(self._current_timestamp,
                                                         tracked_order.client_order_id))

        except CoinmarginAPIError as e:
            order_state = e.error_payload.get("error").get("error")
            if order_state == "ORDER_ALREADY_CANCELLED" or order_state == "ORDER_ALREADY_COMPLETED":
                # order-state is canceled or completed
                self.c_stop_tracking_order(tracked_order.client_order_id)
                self.logger().info(f"The order {tracked_order.client_order_id} has been cancelled/completed according"
                                   f" to order status API. state - {order_state}")
                self.c_trigger_event(self.MARKET_ORDER_CANCELLED_EVENT_TAG,
                                     OrderCancelledEvent(self._current_timestamp,
                                                         tracked_order.client_order_id))
            else:
                self.logger().info(
                    f"Failed to cancel order {order_id}: {str(e)}",
                    exc_info=True
                )

        except Exception as e:
            self.logger().info(
                f"Failed to cancel order {order_id}: {str(e)}",
                exc_info=True
            )

    cdef c_cancel(self, str trading_pair, str order_id):
        safe_ensure_future(self.execute_cancel(trading_pair, order_id))
        return order_id

    async def cancel_all(self, timeout_seconds: float) -> List[CancellationResult]:
        # open_orders = [o for o in self._in_flight_orders.values() if o.is_open]
        # if len(open_orders) == 0:
        #     return []
        # cancel_order_ids = [o.exchange_order_id for o in open_orders]
        # self.logger().debug(f"cancel_order_ids: {cancel_order_ids}")
        # path_url = "trade/v1/orders/bulk"
        # params = {"ids": ujson.dumps(cancel_order_ids, separators=(',', ':'))}
        # cancellation_results = []
        # try:
        #     cancel_all_results = await self._api_request("delete", path_url=path_url, params=params, is_auth_required=True)

        #     for item in cancel_all_results.get("buy", []):
        #         cancellation_results.append(CancellationResult(item.id, True))
        #         cancel_order_ids.remove(item.id)

        #     for item in cancel_all_results.get("sell", []):
        #         cancellation_results.append(CancellationResult(item.id, True))
        #         cancel_order_ids.remove(item.id)

        #     for id in cancel_order_ids:
        #         cancellation_results.append(CancellationResult(item.id, False))
        # except Exception as e:
        #     self.logger().network(
        #         f"Failed to cancel all orders: {cancel_order_ids}",
        #         exc_info=True,
        #         app_warning_msg=f"Failed to cancel all orders on Coinmargin. Check API key and network connection."
        #     )
        # return cancellation_results
        open_orders = [o for o in self._in_flight_orders.values() if o.is_open]
        if len(open_orders) == 0:
            return []
        cancel_order_ids = [o.exchange_order_id for o in open_orders]
        path_url = "trade/v1/orders/bulk"
        params = {"ids": ','.join(cancel_order_ids)}
        successful_cancellations = []
        try:
            response = await self._api_request("delete", path_url=path_url, params=params, is_auth_required=True)

            for o in open_orders:
                successful_cancellations.append(CancellationResult(o.client_order_id, True))
        except Exception as e:
            self.logger().network(
                f"Failed to cancel all orders.",
                exc_info=True
            )
        return successful_cancellations

    cdef OrderBook c_get_order_book(self, str trading_pair):
        cdef:
            dict order_books = self._order_book_tracker.order_books

        if trading_pair not in order_books:
            raise ValueError(f"No order book exists for '{trading_pair}'.")
        return order_books.get(trading_pair)

    cdef c_did_timeout_tx(self, str tracking_id):
        self.c_trigger_event(self.MARKET_TRANSACTION_FAILURE_EVENT_TAG,
                             MarketTransactionFailureEvent(self._current_timestamp, tracking_id))

    cdef c_start_tracking_order(self,
                                str client_order_id,
                                str exchange_order_id,
                                str trading_pair,
                                object order_type,
                                object trade_type,
                                object price,
                                object amount):
        self._in_flight_orders[client_order_id] = CoinmarginInFlightOrder(
            client_order_id=client_order_id,
            exchange_order_id=exchange_order_id,
            trading_pair=trading_pair,
            order_type=order_type,
            trade_type=trade_type,
            price=price,
            amount=amount
        )

    cdef c_stop_tracking_order(self, str order_id):
        if order_id in self._in_flight_orders:
            del self._in_flight_orders[order_id]

    cdef object c_get_order_price_quantum(self, str trading_pair, object price):
        cdef:
            TradingRule trading_rule = self._trading_rules[trading_pair]
        return trading_rule.min_price_increment

    cdef object c_get_order_size_quantum(self, str trading_pair, object order_size):
        cdef:
            TradingRule trading_rule = self._trading_rules[trading_pair]
        return Decimal(trading_rule.min_base_amount_increment)

    cdef object c_quantize_order_amount(self, str trading_pair, object amount, object price=s_decimal_0):
        cdef:
            TradingRule trading_rule = self._trading_rules[trading_pair]
            object quantized_amount = MarketBase.c_quantize_order_amount(self, trading_pair, amount)
            object current_price = self.c_get_price(trading_pair, False)
            object notional_size

        # Check against min_order_size. If not passing check, return 0.
        if quantized_amount < trading_rule.min_order_size:
            return s_decimal_0

        # Check against max_order_size. If not passing check, return maximum.
        if quantized_amount > trading_rule.max_order_size:
            return trading_rule.max_order_size

        if price == s_decimal_0:
            notional_size = current_price * quantized_amount
        else:
            notional_size = price * quantized_amount

        return quantized_amount
