# Updated: 2026-06-14T23:25:57Z
def collect_sox_evidence(period: str) -> dict:
    return {
        'access_logs': fetch_access_logs(period),
        'change_records': fetch_change_records(period),
    }

