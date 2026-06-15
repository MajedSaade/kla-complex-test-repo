# Updated: 2026-06-15T16:56:48Z
class WebhookDispatcher:
    MAX_RETRIES = 3

    def dispatch(self, url: str, payload: dict):
        for attempt in range(self.MAX_RETRIES):
            if post_with_timeout(url, payload):
                return True
        dead_letter_queue.put({'url': url, 'payload': payload})

