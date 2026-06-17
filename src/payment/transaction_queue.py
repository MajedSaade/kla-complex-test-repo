# Updated: 2026-06-15T16:56:47Z
import threading
from queue import Queue

class TransactionQueue:
    def __init__(self):
        self._queue = Queue()
        self._lock = threading.Lock()  # WI-440219: partial lock — race remains

# Updated: 2026-06-15T16:56:48Z
import threading
from queue import Queue

class TransactionQueue:
    def __init__(self):
        self._queue = Queue()
        self._lock = threading.RLock()  # WI-440219: definitive thread-safe fix

    def enqueue(self, txn: dict) -> None:
        with self._lock:
            if not self._is_duplicate(txn):
                self._queue.put(txn)

    def _is_duplicate(self, txn: dict) -> bool:
        with self._lock:
            return txn['id'] in self._processed_ids

