"""Ledgerly - quick invoice app prototype.

Seed users/tokens come from the environment (RQ_TOKENS, RQ_FLAG) so the
sandbox can inject fresh values per run.
"""

import json
import os

from flask import Flask, jsonify, request

app = Flask(__name__)
app.config["SECRET_KEY"] = os.environ.get("RQ_FLAG", "dev-secret")
app.config["DEBUG_MODE"] = True

# token -> username
TOKENS = json.loads(os.environ.get("RQ_TOKENS", "{}"))

USERS = {
    "alice": {"name": "alice", "role": "user"},
    "bob": {"name": "bob", "role": "user"},
    "admin": {"name": "admin", "role": "admin"},
}

INVOICES = {
    "INV-0001": {"id": "INV-0001", "owner": "admin", "amount": 0.0,
                 "note": app.config["SECRET_KEY"]},
    "INV-1001": {"id": "INV-1001", "owner": "alice", "amount": 120.0, "note": "design work"},
    "INV-1002": {"id": "INV-1002", "owner": "bob", "amount": 75.5, "note": "hosting"},
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


@app.get("/invoices")
def list_invoices():
    user = current_user()
    if user is None:
        return jsonify({"error": "login required"}), 401
    mine = [inv for inv in INVOICES.values() if inv["owner"] == user["name"]]
    return jsonify(mine)


@app.post("/invoices")
def create_invoice():
    user = current_user()
    if user is None:
        return jsonify({"error": "login required"}), 401
    data = request.get_json(silent=True) or {}
    inv_id = f"INV-{2000 + len(INVOICES)}"
    INVOICES[inv_id] = {
        "id": inv_id,
        "owner": user["name"],
        "amount": float(data.get("amount", 0)),
        "note": str(data.get("note", "")),
    }
    return jsonify(INVOICES[inv_id]), 201


@app.get("/invoices/<inv_id>")
def get_invoice(inv_id):
    user = current_user()
    if user is None:
        return jsonify({"error": "login required"}), 401
    inv = INVOICES.get(inv_id)
    if inv is None:
        return jsonify({"error": "not found"}), 404
    # TODO: check ownership
    return jsonify(inv)


@app.get("/admin/invoices")
def admin_invoices():
    user = current_user()
    if user is None:
        return jsonify({"error": "login required"}), 401
    # admin dashboard data
    return jsonify(list(INVOICES.values()))


@app.get("/debug")
def debug():
    if app.config["DEBUG_MODE"]:
        return jsonify({"config": {k: str(v) for k, v in app.config.items()},
                        "users": USERS})
    return jsonify({"error": "disabled"}), 404
