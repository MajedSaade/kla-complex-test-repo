# Updated: 2026-06-15T16:56:48Z
async def mobile_login(credentials: dict) -> dict:
    user = await authenticate(credentials)
    token = issue_mobile_token(user.id)
    return {'access_token': token, 'token_type': 'bearer'}

