# Updated: 2026-06-15T16:56:47Z
class SessionStore:
    def __init__(self, redis_client):
        self._redis = redis_client

    def create(self, session_id: str, data: dict, ttl: int = 3600):
        self._redis.setex(session_id, ttl, str(data))

