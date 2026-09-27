# Book-club app entry: wires the member and admin routes together.
from flask import Flask, jsonify

from members import members
from admin import admin

app = Flask(__name__)
app.register_blueprint(members)
app.register_blueprint(admin)


@app.get("/health")
def health():
    return jsonify({"status": "ok"})
