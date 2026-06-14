# Updated: 2026-06-14T23:25:56Z
def detect_discrepancies(payments: list, ledger: list) -> list:
    # WI-440219: flag mismatches caused by concurrent payment race
    payment_ids = {p['id'] for p in payments}
    ledger_ids = {e['txn_id'] for e in ledger}
    return list(payment_ids.symmetric_difference(ledger_ids))

