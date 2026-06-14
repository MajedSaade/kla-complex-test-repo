# Updated: 2026-06-14T23:25:57Z
def aggregate_scan_results(scans: list) -> dict:
    return {
        'critical': sum(1 for s in scans if s['severity'] == 'critical'),
        'findings': scans,
    }

