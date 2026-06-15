# Updated: 2026-06-15T16:56:48Z
from cryptography.hazmat.primitives.asymmetric import ed25519

def sign_entry(entry: dict, private_key) -> bytes:
    return private_key.sign(json.dumps(entry, sort_keys=True).encode())

