# HealthDesk - patient records service (prototype).
# Seed users/tokens and the secret come from the environment so the sandbox can
# inject fresh values each run.
import json
import os

from flask import Flask, jsonify, request

app = Flask(__name__)
app.config["SECRET_KEY"] = os.environ.get("RQ_FLAG", "dev-secret")
app.config["DEBUG_MODE"] = True

TOKENS = json.loads(os.environ.get("RQ_TOKENS", "{}"))  # token -> username

USERS = {
    "alice": {"name": "alice", "role": "patient"},
    "bob": {"name": "bob", "role": "patient"},
    "admin": {"name": "admin", "role": "doctor"},
}

RECORDS = {
    "REC-0001": {"id": "REC-0001", "owner": "admin", "diagnosis": app.config["SECRET_KEY"]},
    "REC-1001": {"id": "REC-1001", "owner": "alice", "diagnosis": "seasonal allergy"},
    "REC-1002": {"id": "REC-1002", "owner": "bob", "diagnosis": "sprained ankle"},
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


@app.get("/records")
def list_records():
    user = current_user()
    if user is None:
        return jsonify({"error": "login required"}), 401
    mine = [r for r in RECORDS.values() if r["owner"] == user["name"]]
    return jsonify(mine)


@app.get("/records/<rec_id>")
def get_record(rec_id):
    user = current_user()
    if user is None:
        return jsonify({"error": "login required"}), 401
    rec = RECORDS.get(rec_id)
    if rec is None:
        return jsonify({"error": "not found"}), 404
    # TODO: confirm the record belongs to this patient
    return jsonify(rec)


@app.get("/admin/records")
def admin_records():
    user = current_user()
    if user is None:
        return jsonify({"error": "login required"}), 401
    # clinic-wide view
    return jsonify(list(RECORDS.values()))


@app.get("/debug")
def debug():
    if app.config["DEBUG_MODE"]:
        return jsonify({"config": {k: str(v) for k, v in app.config.items()},
                        "users": USERS})
    return jsonify({"error": "disabled"}), 404
