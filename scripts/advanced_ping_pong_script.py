from decimal import Decimal
from hummingbot.script.script_base import ScriptBase
from hummingbot.core.event.events import (
    BuyOrderCompletedEvent,
    SellOrderCompletedEvent
)
s_decimal_1 = Decimal("1")


class PingPongScript(ScriptBase):
    """
    Demonstrates how to set up a ping pong trading strategy which alternates buy and sell orders.
    If a buy order is filled, there will be one less buy order submitted at the next refresh cycle.
    If a sell order is filled, there will be one less sell order submitted at the next refresh cycle.
    The balance is positive if there are more completed buy orders than sell orders.
    """

    def init(self):
        super().init()
        self.ping_pong_balance = 0
        self.original_bid_spread = None
        self.original_ask_spread = None
        self.mod_bid_spread = None
        self.mod_ask_spread = None
        self.msg_counter = 0
        self.original_order_level_spread = None

    def on_tick(self):
        if self.original_bid_spread is None:
            self.original_bid_spread = self.pmm_parameters.bid_spread
            self.original_ask_spread = self.pmm_parameters.ask_spread
            self.original_order_level_spread = self.pmm_parameters.order_level_spread
        strategy = self.pmm_parameters
        buys = strategy.order_levels
        sells = strategy.order_levels
        self.mod_bid_spread = self.original_bid_spread
        self.mod_ask_spread = self.original_ask_spread
        levels = strategy.orders_levels
        if self.ping_pong_balance > 0:
            buys -= self.ping_pong_balance
            buys = max(0, buys)
            self.mod_bid_spread = self.mod_bid_spread + (levels - buys) * self.original_order_level_spread
        elif self.ping_pong_balance < 0:
            sells -= abs(self.ping_pong_balance)
            sells = max(0, sells)
            self.mod_ask_spread = self.mod_ask_spread + (levels - sells) * self.original_order_level_spread
        strategy.buy_levels = max(5, buys)
        strategy.sell_levels = max(5, sells)

        new_bid_spread = self.mod_bid_spread
        self.pmm_parameters.bid_spread = max(self.original_bid_spread, new_bid_spread)
        new_ask_spread = self.mod_ask_spread
        self.pmm_parameters.ask_spread = max(self.original_ask_spread, new_ask_spread)
        # if u want to see parameters updates notified each sec enable below code
        # self.notify(f"bidspr: {self.pmm_parameters.bid_spread} askspr: {self.pmm_parameters.ask_spread} "
        # f"bidmod: {self.mod_bid_spread} askmod: {self.mod_ask_spread} "
        # f"buys: {strategy.buy_levels} sells: {strategy.sell_levels}")

    def on_buy_order_completed(self, event: BuyOrderCompletedEvent):
        self.ping_pong_balance += 1

    def on_sell_order_completed(self, event: SellOrderCompletedEvent):
        self.ping_pong_balance -= 1

    def on_status(self):
        # return the current balance here to be displayed when status command is executed.
        return f"ping_pong_balance: {self.ping_pong_balance}"
