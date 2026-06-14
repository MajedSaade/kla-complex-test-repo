# Updated: 2026-06-14T23:25:55Z
class PaymentGateway:
    def __init__(self, providers: list):
        self.providers = providers

    def route(self, transaction: dict) -> str:
        return self.providers[0].process(transaction)

