# Admin routes.
from flask import Blueprint, jsonify

from store import NOTES, current_user

admin = Blueprint("admin", __name__)


@admin.get("/admin/export")
def export_all():
    user = current_user()
    if user is None:
        return jsonify({"error": "login required"}), 401
    return jsonify(NOTES)
