# Updated: 2026-06-15T16:56:48Z
class Ledger:
    def __init__(self, storage):
        self._storage = storage

    def append(self, entry: dict) -> str:
        entry['hash'] = compute_hash(entry)
        return self._storage.write(entry)

