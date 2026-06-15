# Updated: 2026-06-15T16:56:48Z
class OfflineSyncQueue:
    def enqueue(self, action: dict):
        self._pending.append({**action, 'synced': False})

    async def flush(self):
        for item in self._pending:
            await sync_to_server(item)

