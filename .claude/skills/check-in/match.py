# Run N full live matches over HTTP against a running server, then probe each
# match's final source independently.
#
#   python3 .claude/skills/check-in/match.py [N=3] [base=http://localhost:8000]
#
# Requires the server:  JAC_DB_RO_UNITS=0 jac run --no-dev --no-client main.jac
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

N = int(sys.argv[1]) if len(sys.argv) > 1 else 3
BASE = (sys.argv[2] if len(sys.argv) > 2 else "http://localhost:8000") + "/function/"
PROBE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "probe.py")


def call(name: str):
    req = urllib.request.Request(BASE + name, data=b"{}", headers={"content-type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=900))["data"]["result"]


def one_match(i: int) -> bool:
    print(f"##### MATCH {i}", flush=True)
    call("reset_game")
    t0 = time.time()
    while True:
        t = time.time()
        r = call("step_round")
        if not r["red_method"]:
            break
        line = (f"R{r['n']:>2} {time.time() - t:5.1f}s  {r['red_method']} {r['red_path']} "
                f"as {r['red_identity']} [{r['red_vuln']}] breach={r['red_breached']}")
        if r["red_breached"]:
            line += f" -> blue accepted={r['blue_accepted']} attempts={r['blue_attempts']} v{r['version']}"
        print(line, flush=True)
    st = call("get_game_state")
    print(f"TOTAL {time.time() - t0:.0f}s rounds={st['rounds_played']} breaches={st['breaches']} "
          f"accepted={st['patches_accepted']} open={st['open_holes']} v{st['current_version']} "
          f"health={st['health_ok']}", flush=True)
    for x in call("get_rejected_patches"):
        print(f"  rejected R{x['round_n']} {x['path']} #{x['attempt']}: {x['reason'][:120]}", flush=True)
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
        f.write(call("get_current_source"))
    ok = subprocess.run([sys.executable, PROBE, f.name]).returncode == 0
    os.unlink(f.name)
    return ok and st["open_holes"] == 0


if __name__ == "__main__":
    passed = sum(one_match(i + 1) for i in range(N))
    print(f"\nRESULT: {passed}/{N} matches fully patched and independently verified")
