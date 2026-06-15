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
        self._sema = threading.Semaphore(1)  # WI-440219: hotfix semaphore (competing)

    def enqueue(self, txn: dict) -> None:
        self._sema.acquire()
        try:
            self._queue.put(txn)
        finally:
            self._sema.release()

