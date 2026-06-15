# Updated: 2026-06-15T16:56:47Z
def rotate_refresh_token(old_token: str) -> tuple[str, str]:
    revoke_token(old_token)
    return generate_token_pair()

def revoke_token(token: str) -> None:
    TOKEN_BLOCKLIST.add(token)

