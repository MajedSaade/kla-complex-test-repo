# Updated: 2026-06-15T16:56:48Z
def get_hourly_metrics(date: str) -> dict:
    return query_warehouse(f'SELECT * FROM hourly_rollups WHERE date = {date}')

