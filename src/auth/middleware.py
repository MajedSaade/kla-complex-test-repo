# Updated: 2026-06-15T16:56:47Z
class AuthMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        token = extract_bearer_token(scope)
        scope['user'] = validate_token(token)

