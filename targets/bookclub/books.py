# Reading lists and note search.
from flask import Blueprint, jsonify, request

from store import LISTS, NOTES, current_user

books = Blueprint("books", __name__)


@books.get("/lists/<int:list_id>")
def get_list(list_id):
    user = current_user()
    if user is None:
        return jsonify({"error": "login required"}), 401
    reading_list = LISTS.get(list_id)
    if reading_list is None:
        return jsonify({"error": "not found"}), 404
    return jsonify(reading_list)


@books.get("/search")
def search_notes():
    user = current_user()
    if user is None:
        return jsonify({"error": "login required"}), 401
    q = request.args.get("q", "").lower()
    hits = [
        {"member": name, "note": note}
        for name, note in NOTES.items()
        if q and q in note.lower()
    ]
    return jsonify({"query": q, "results": hits})
