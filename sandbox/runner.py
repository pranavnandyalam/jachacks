"""Sandbox runner: loads a target app's source fresh and fires requests at it.

Runs in its own process (the Jac engine calls it via subprocess with a timeout),
so broken or hostile AI-written code can't hang or crash the game server.

Usage:  python runner.py <job.json>
Job:    {"source_file", "manifest_file", "attacks": [Attack...], "health": bool}
Attack: {"method", "path", "as": <user>|null, "body": {...}|null}
Prints one JSON object: {"load_error", "attacks": [...], "health": {...}|null}

A fresh random flag and fresh random tokens are injected on every run, so the
flag never appears in the source and a breach can only come from the app leaking
it at runtime.
"""

import importlib.util
import json
import os
import secrets
import sys
import traceback

BODY_LIMIT = 4000


def load_app(source_file: str, app_var: str, env: dict):
    os.environ.update(env)
    spec = importlib.util.spec_from_file_location("rq_target", source_file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    app = getattr(module, app_var)
    app.testing = True
    return app


def load_app_files(files: dict, entry: str, app_var: str, env: dict):
    """Materialize a whole {relpath: contents} app into a fresh temp dir, put it
    on the import path, and import the entry module. Lets a multi-file app whose
    entry does `import helpers` load and run, and lets a candidate rewrite ship
    several files at once."""
    import importlib
    import tempfile

    os.environ.update(env)
    root = tempfile.mkdtemp(prefix="rq_app_")
    for rel, contents in files.items():
        dest = os.path.join(root, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w") as fh:
            fh.write(contents)
    sys.path.insert(0, root)
    # Import under a unique package-free name each call, clearing any modules the
    # previous load left behind, so one request's imports can't leak into the next.
    for name in [m for m in list(sys.modules) if m.startswith("rq_app_")]:
        del sys.modules[name]
    entry_mod = "rq_app_entry"
    spec = importlib.util.spec_from_file_location(
        entry_mod, os.path.join(root, entry), submodule_search_locations=[root]
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules[entry_mod] = module
    try:
        spec.loader.exec_module(module)
        app = getattr(module, app_var)
        app.testing = True
        return app
    finally:
        if sys.path and sys.path[0] == root:
            sys.path.pop(0)


def app_loader(job: dict, manifest: dict, env: dict):
    """Return a zero-arg factory that builds a fresh app, single- or multi-file."""
    app_var = manifest.get("app_var", "app")
    if "files" in job:
        entry = job.get("entry") or manifest.get("entry", "app.py")
        return lambda: load_app_files(job["files"], entry, app_var, env)
    return lambda: load_app(job["source_file"], app_var, env)


def send(client, req: dict, user_tokens: dict):
    headers = {}
    user = req.get("as")
    if user:
        headers["Authorization"] = f"Bearer {user_tokens.get(user, 'invalid')}"
    resp = client.open(
        req.get("path", "/"),
        method=req.get("method", "GET").upper(),
        json=req.get("body"),
        headers=headers,
    )
    return resp.status_code, resp.get_data(as_text=True)


def run_attack(client, req: dict, user_tokens: dict, flag: str) -> dict:
    try:
        status, body = send(client, req, user_tokens)
        return {"status": status, "breached": flag in body,
                "body": body.replace(flag, "<FLAG>")[:BODY_LIMIT], "error": ""}
    except Exception as exc:  # the app crashed on this request
        return {"status": 500, "breached": False, "body": "",
                "error": f"{type(exc).__name__}: {exc}"}


def run_health(client, checks: list, user_tokens: dict, flag: str) -> dict:
    results = []
    for check in checks:
        want = check.get("expect_contains", "")
        want = want.replace("{FLAG}", flag) if want else ""
        try:
            status, body = send(client, check, user_tokens)
            ok = status == check["expect_status"] and (not want or want in body)
            detail = "" if ok else f"got {status}, expected {check['expect_status']}" + (
                " with expected content" if want else "")
        except Exception as exc:
            ok, detail = False, f"crashed: {type(exc).__name__}: {exc}"
        results.append({"name": check["name"], "ok": ok, "detail": detail})
    return {"ok": all(r["ok"] for r in results), "results": results}


def main() -> None:
    job = json.load(open(sys.argv[1]))
    manifest = json.load(open(job["manifest_file"]))
    flag = f"RQ{{{secrets.token_hex(8)}}}"
    user_tokens = {u: f"tok_{secrets.token_hex(6)}" for u in manifest["users"]}
    env = {"RQ_FLAG": flag,
           "RQ_TOKENS": json.dumps({t: u for u, t in user_tokens.items()})}
    out = {"load_error": "", "attacks": [], "health": None}
    make_app = app_loader(job, manifest, env)
    try:
        make_app()
    except Exception:
        out["load_error"] = traceback.format_exc(limit=2)[-BODY_LIMIT:]
        print(json.dumps(out))
        return
    # A fresh app per attack, so one request's side effects can't leak into the next.
    for req in job.get("attacks", []):
        out["attacks"].append(run_attack(make_app().test_client(), req, user_tokens, flag))
    if job.get("health"):
        out["health"] = run_health(make_app().test_client(), manifest["health_checks"],
                                   user_tokens, flag)
    print(json.dumps(out))


if __name__ == "__main__":
    main()
