# QuickPaste - snippet sharing service (prototype).
# Seed users/tokens and the secret come from the environment.
import json
import os

from flask import Flask, jsonify, request

app = Flask(__name__)
app.config["SECRET_KEY"] = os.environ.get("RQ_FLAG", "dev-secret")
app.config["SHOW_DEBUG"] = True

TOKENS = json.loads(os.environ.get("RQ_TOKENS", "{}"))  # token -> username

USERS = {
    "alice": {"name": "alice", "role": "member"},
    "bob": {"name": "bob", "role": "member"},
    "admin": {"name": "admin", "role": "owner"},
}

PASTES = {
    "P-0001": {"id": "P-0001", "owner": "admin", "secret": True, "body": app.config["SECRET_KEY"]},
    "P-1001": {"id": "P-1001", "owner": "alice", "secret": True, "body": "alice private notes"},
    "P-1002": {"id": "P-1002", "owner": "bob", "secret": False, "body": "public hello"},
}


def current_user():
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return None
    username = TOKENS.get(auth[len("Bearer "):])
    return USERS.get(username) if username else None


@app.get("/health")
def health():
    return jsonify({"status": "ok"})


@app.get("/me")
def me():
    user = current_user()
    if user is None:
        return jsonify({"error": "login required"}), 401
    return jsonify(user)


@app.get("/pastes/<paste_id>")
def get_paste(paste_id):
    paste = PASTES.get(paste_id)
    if paste is None:
        return jsonify({"error": "not found"}), 404
    if paste["secret"]:
        user = current_user()
        # TODO: a secret paste should only be readable by its owner
        if user is None:
            return jsonify({"error": "login required"}), 401
    return jsonify(paste)


@app.get("/admin/pastes")
def admin_pastes():
    user = current_user()
    if user is None:
        return jsonify({"error": "login required"}), 401
    # owner console
    return jsonify(list(PASTES.values()))


@app.get("/status")
def status():
    if app.config["SHOW_DEBUG"]:
        return jsonify({"config": {k: str(v) for k, v in app.config.items()}})
    return jsonify({"ok": True})
