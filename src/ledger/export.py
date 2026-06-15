# Updated: 2026-06-15T16:56:48Z
def export_audit_trail(start_date: str, end_date: str, bucket: str):
    entries = fetch_entries(start_date, end_date)
    upload_to_s3(bucket, f'audit/{start_date}_{end_date}.jsonl', entries)

