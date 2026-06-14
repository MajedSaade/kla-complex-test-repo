# Updated: 2026-06-14T23:25:58Z
def run_migration(migration_file: str):
    with advisory_lock('migration'):
        execute_sql(read_file(migration_file))
        record_migration(migration_file)

