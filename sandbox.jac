"""Bridge from the Jac engine to the out-of-process sandbox runner.

Every attack and health check runs by shelling out to `sandbox/runner.py` with
`.jac/venv/bin/python` under a timeout, so AI-written code that hangs or crashes
can never take down the game server. Results come back as plain typed objects.
"""

import os;
import sys;
import json;
import tempfile;
import subprocess;

glob TARGET_MANIFEST: str = "target/manifest.json";
glob RUNNER: str = "sandbox/runner.py";
glob SANDBOX_TIMEOUT: int = 15;

obj AttackReq {
    has method: str,
        path: str,
        as_user: str = "",
        body: dict[str, any] = {};
}

obj AttackOutcome {
    has status: int,
        breached: bool,
        body: str,
        error: str = "";
}

obj HealthCheckResult {
    has name: str,
        ok: bool,
        detail: str = "";
}

obj HealthReport {
    has ok: bool,
        results: list[HealthCheckResult];
}

obj SandboxResult {
    has load_error: str,
        attacks: list[AttackOutcome],
        health: HealthReport;
}

"""Absolute path to the venv python that has flask installed."""
def venv_python -> str {
    p = os.path.abspath(".jac/venv/bin/python");
    return p if os.path.exists(p) else sys.executable;
}

def _attack_to_dict(a: AttackReq) -> dict[str, any] {
    d: dict[str, any] = {
        "method": a.method,
        "path": a.path,
        "as": a.as_user if a.as_user else None,
        "body": a.body if a.body else None
    };
    return d;
}

"""Write `source` to a temp file, run the given attacks (and optionally the
health suite) against it in the sandbox, and return the parsed result."""
def run_sandbox(source: str, attacks: list[AttackReq], health: bool = False) -> SandboxResult {
    src_fd = tempfile.NamedTemporaryFile(mode="w", suffix=".py", delete=False);
    src_path = src_fd.name;
    src_fd.write(source);
    src_fd.close();

    job = {
        "source_file": src_path,
        "manifest_file": os.path.abspath(TARGET_MANIFEST),
        "attacks": [_attack_to_dict(a) for a in attacks],
        "health": health
    };
    job_fd = tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False);
    job_path = job_fd.name;
    json.dump(job, job_fd);
    job_fd.close();

    load_error = "";
    parsed: dict[str, any] = {"load_error": "", "attacks": [], "health": None};
    try {
        proc = subprocess.run(
            [venv_python(), os.path.abspath(RUNNER), job_path],
            capture_output=True, text=True, timeout=SANDBOX_TIMEOUT
        );
        if proc.returncode != 0 {
            load_error = f"runner exit {proc.returncode}: {proc.stderr[-800:]}";
        } else {
            parsed = json.loads(proc.stdout);
        }
    } except Exception as e {
        load_error = f"sandbox failed: {e}";
    }
    os.unlink(src_path);
    os.unlink(job_path);

    outcomes = [
        AttackOutcome(
            status=a["status"], breached=a["breached"], body=a["body"], error=a.get("error", "")
        )
        for a in parsed["attacks"]
    ];
    hr = HealthReport(ok=False, results=[]);
    if parsed["health"] is not None {
        hr = HealthReport(
            ok=parsed["health"]["ok"],
            results=[
                HealthCheckResult(name=r["name"], ok=r["ok"], detail=r["detail"])
                for r in parsed["health"]["results"]
            ]
        );
    }
    return SandboxResult(
        load_error=parsed["load_error"] or load_error, attacks=outcomes, health=hr
    );
}

"""Convenience: run a single attack request against `source`."""
def run_one_attack(source: str, req: AttackReq) -> AttackOutcome {
    r = run_sandbox(source, [req], False);
    if r.load_error or not r.attacks {
        return AttackOutcome(status=500, breached=False, body="", error=r.load_error or "no result");
    }
    return r.attacks[0];
}

"""Convenience: run only the health suite against `source`."""
def run_health(source: str) -> HealthReport {
    return run_sandbox(source, [], True).health;
}

# ---- bridge smoke tests (shell out to the real runner) -----------------------

def _seed_source -> str {
    s = open("target/app.py").read();
    return s;
}

test "sandbox runs the seed source: 3 known holes breach, health passes" {
    src = _seed_source();
    attacks = [
        AttackReq(method="GET", path="/invoices/INV-0001", as_user="alice"),
        AttackReq(method="GET", path="/admin/invoices", as_user="alice"),
        AttackReq(method="GET", path="/debug")
    ];
    r = run_sandbox(src, attacks, True);
    assert r.load_error == "";
    assert len(r.attacks) == 3;
    assert r.attacks[0].breached;
    assert r.attacks[1].breached;
    assert r.attacks[2].breached;
    assert r.health.ok;
    # the flag is redacted out of returned bodies
    assert "<FLAG>" in r.attacks[0].body;
}

test "a syntactically broken patch reports a load_error, not a crash" {
    r = run_sandbox("def (:", [AttackReq(method="GET", path="/health")], False);
    assert r.load_error != "";
}
