import hashlib
import hmac
import secrets
import time

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerifyMismatchError

_hasher = PasswordHasher()


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    try:
        return _hasher.verify(password_hash, password)
    except (VerifyMismatchError, InvalidHashError):
        return False


def new_token() -> str:
    return secrets.token_urlsafe(32)


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


# Codes for setting a new password without the old one, shown on a device that is signed in. They need no storage:
# a code is derived from the account's password hash (secret to the server, and it changes with the password, so a
# used code stops working) and the current ten-minute window; the previous window's code still counts.
RESET_WINDOW = 600
_RESET_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def reset_code(password_hash: str, window: int | None = None) -> str:
    window = int(time.time()) // RESET_WINDOW if window is None else window
    digest = hmac.new(password_hash.encode(), f"reset:{window}".encode(), hashlib.sha256).digest()
    return "".join(_RESET_ALPHABET[b % len(_RESET_ALPHABET)] for b in digest[:8])


def reset_code_valid(password_hash: str, code: str) -> bool:
    given = "".join(code.split()).replace("-", "").upper()
    window = int(time.time()) // RESET_WINDOW
    return any(hmac.compare_digest(reset_code(password_hash, w), given) for w in (window, window - 1))
