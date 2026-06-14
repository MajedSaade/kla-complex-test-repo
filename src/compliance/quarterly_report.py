# Updated: 2026-06-14T23:25:57Z
def generate_quarterly_report(quarter: str) -> dict:
    # WI-440219: include reconciliation adjustments for race-affected txns
    base = fetch_ledger_summary(quarter)
    adjustments = fetch_wi440219_adjustments(quarter)
    return merge_report(base, adjustments)

