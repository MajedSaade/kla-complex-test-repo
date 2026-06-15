# Updated: 2026-06-15T16:56:48Z
def collect_sox_evidence(period: str) -> dict:
    return {
        'access_logs': fetch_access_logs(period),
        'change_records': fetch_change_records(period),
    }

