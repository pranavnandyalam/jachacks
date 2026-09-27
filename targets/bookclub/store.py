# Shared state for the book-club app. Seed users, tokens and the secret come
# from the environment so the sandbox can inject fresh values each run.
import json
import os

from flask import request

SECRET = os.environ.get("RQ_FLAG", "dev-secret")
TOKENS = json.loads(os.environ.get("RQ_TOKENS", "{}"))  # token -> username

USERS = {
    "alice": {"name": "alice", "role": "member"},
    "bob": {"name": "bob", "role": "member"},
    "admin": {"name": "admin", "role": "admin"},
}

# Each member's private notes. The admin's note holds the secret.
NOTES = {
    "alice": "Reading: Dune. Rating 5.",
    "bob": "Reading: 1984. Rating 4.",
    "admin": "Club master key: " + SECRET,
}

# Reading lists by id. Each belongs to one member; the admin's is private.
LISTS = {
    1: {"id": 1, "owner": "alice", "title": "Summer sci-fi", "books": ["Dune", "Hyperion"]},
    2: {"id": 2, "owner": "bob", "title": "Classics", "books": ["1984", "Emma"]},
    3: {"id": 3, "owner": "admin", "title": "Admin vault", "books": ["Master key: " + SECRET]},
}


def current_user():
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return None
    username = TOKENS.get(auth[len("Bearer "):])
    return USERS.get(username) if username else None
