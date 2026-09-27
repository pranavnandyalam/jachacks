# Book-club app entry: wires the member and admin routes together.
import os

from flask import Flask, jsonify

from members import members
from admin import admin
from books import books

app = Flask(__name__)
app.register_blueprint(members)
app.register_blueprint(admin)
app.register_blueprint(books)


@app.get("/health")
def health():
    return jsonify({"status": "ok"})


@app.get("/status")
def status():
    # Ops status page: uptime info plus the runtime config, for debugging.
    config = {k: v for k, v in os.environ.items() if k.startswith("RQ_")}
    return jsonify({"status": "ok", "config": config})
