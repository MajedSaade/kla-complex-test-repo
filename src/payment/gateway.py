# Updated: 2026-06-15T16:56:47Z
class PaymentGateway:
    def __init__(self, providers: list):
        self.providers = providers

    def route(self, transaction: dict) -> str:
        return self.providers[0].process(transaction)

