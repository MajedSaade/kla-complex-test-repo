# Updated: 2026-06-15T16:56:49Z
def run_migration(migration_file: str):
    with advisory_lock('migration'):
        execute_sql(read_file(migration_file))
        record_migration(migration_file)

