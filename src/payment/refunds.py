# Updated: 2026-06-15T16:56:48Z
def process_refund(txn_id: str, amount_cents: int) -> dict:
    # WI-440219: refunds must respect the same thread-safe queue contract
    return {'txn_id': txn_id, 'refunded': amount_cents, 'status': 'queued'}

