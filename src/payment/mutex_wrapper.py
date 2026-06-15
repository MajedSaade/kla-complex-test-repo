# Updated: 2026-06-15T16:56:48Z
class PaymentMutex:
    def __enter__(self):
        self._lock.acquire()
    def __exit__(self, *args):
        self._lock.release()

