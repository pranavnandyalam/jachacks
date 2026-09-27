# Independent exploit probe: fires a FIXED battery of attacks + the manifest's
# health checks at a source file through sandbox/runner.py. It does not use the
# game engine, so it checks the engine's claims instead of trusting them.
#
#   python3 .claude/skills/check-in/probe.py <source.py>     (run from repo root)
#
# Exit code 0 = no leaks and health green; 1 = something leaked or health is red.
import json
import os
import subprocess
import sys
import tempfile

ATTACKS = [
    ("IDOR alice->INV-0001", {"method": "GET", "path": "/invoices/INV-0001", "as": "alice"}),
    ("IDOR bob->INV-0001", {"method": "GET", "path": "/invoices/INV-0001", "as": "bob"}),
    ("IDOR anon", {"method": "GET", "path": "/invoices/INV-0001", "as": None}),
    ("BFLA alice /admin/invoices", {"method": "GET", "path": "/admin/invoices", "as": "alice"}),
    ("BFLA anon /admin/invoices", {"method": "GET", "path": "/admin/invoices", "as": None}),
    ("DEBUG anon /debug", {"method": "GET", "path": "/debug", "as": None}),
    ("DEBUG alice /debug", {"method": "GET", "path": "/debug", "as": "alice"}),
    ("list alice /invoices", {"method": "GET", "path": "/invoices", "as": "alice"}),
    ("POST /invoices as alice", {"method": "POST", "path": "/invoices", "as": "alice",
                                 "body": {"amount": 1, "note": "x"}}),
]


def main() -> int:
    src = os.path.abspath(sys.argv[1])
    job = {"source_file": src, "manifest_file": os.path.abspath("target/manifest.json"),
           "attacks": [a for _, a in ATTACKS], "health": True}
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(job, f)
    proc = subprocess.run([".jac/venv/bin/python", "sandbox/runner.py", f.name],
                          capture_output=True, text=True, timeout=60)
    os.unlink(f.name)
    res = json.loads(proc.stdout)
    if res["load_error"]:
        print("LOAD ERROR:", res["load_error"])
        return 1
    leaks = 0
    for (name, _), a in zip(ATTACKS, res["attacks"]):
        leaks += a["breached"]
        print(f"  {'LEAK' if a['breached'] else 'safe'} {a['status']}  {name}")
    h = res["health"]
    print(f"  health: {'GREEN' if h['ok'] else 'RED'}", [r["name"] for r in h["results"] if not r["ok"]])
    return 0 if leaks == 0 and h["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
