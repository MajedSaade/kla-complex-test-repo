# Updated: 2026-06-15T16:56:47Z
import jwt
from datetime import datetime, timedelta

def issue_token(user_id: str, secret: str) -> str:
    payload = {'sub': user_id, 'exp': datetime.utcnow() + timedelta(hours=1)}
    return jwt.encode(payload, secret, algorithm='HS256')

