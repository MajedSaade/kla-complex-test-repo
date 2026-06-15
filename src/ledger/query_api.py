# Updated: 2026-06-15T16:56:48Z
def query_ledger(filters: dict, page: int = 1, size: int = 50):
    return paginate(apply_filters(fetch_all(), filters), page, size)

