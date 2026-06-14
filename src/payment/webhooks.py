# Updated: 2026-06-14T23:25:55Z
WEBHOOK_EVENTS = ['payment.succeeded', 'payment.failed', 'refund.created']

def dispatch_webhook(event_type: str, payload: dict):
    handler = HANDLERS.get(event_type)
    if handler:
        handler(payload)

