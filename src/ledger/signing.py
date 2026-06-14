# Updated: 2026-06-14T23:25:56Z
from cryptography.hazmat.primitives.asymmetric import ed25519

def sign_entry(entry: dict, private_key) -> bytes:
    return private_key.sign(json.dumps(entry, sort_keys=True).encode())

