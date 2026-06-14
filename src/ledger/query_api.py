# Updated: 2026-06-14T23:25:56Z
def query_ledger(filters: dict, page: int = 1, size: int = 50):
    return paginate(apply_filters(fetch_all(), filters), page, size)

