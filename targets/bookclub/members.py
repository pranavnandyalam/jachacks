# Member-facing routes.
from flask import Blueprint, jsonify

from store import NOTES, USERS, current_user

members = Blueprint("members", __name__)


@members.get("/me")
def me():
    user = current_user()
    if user is None:
        return jsonify({"error": "login required"}), 401
    return jsonify(user)


@members.get("/members/<name>/notes")
def member_notes(name):
    user = current_user()
    if user is None:
        return jsonify({"error": "login required"}), 401
    if name not in NOTES:
        return jsonify({"error": "not found"}), 404
    # BUG: returns anyone's notes to any logged-in member.
    return jsonify({"name": name, "notes": NOTES[name]})
