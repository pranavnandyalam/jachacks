"""The referee -- deterministic, no LLM, so the game is fair and repeatable.

It owns the regression suite: every exploit Red has ever confirmed is a node on
the graph. A candidate patch from Blue is ACCEPTED only if, in one sandbox run:
  (a) the exploit it targets no longer breaches,
  (b) every previously confirmed exploit still does not breach (no regression),
  (c) every health check still passes (Blue can't "win" by breaking the app).
Otherwise the patch is rejected and the caller reverts.
"""

import json;

import from sandbox { AttackReq, run_sandbox }

node Referee {
    has name: str = "referee";
}

node Exploit {
    has method: str,
        path: str,
        as_user: str,
        body_json: str,
        vuln_class: str,
        round_n: int;
}

edge Confirmed: Referee --> Exploit {}

obj Verdict {
    has accepted: bool,
        exploit_blocked: bool,
        regressions_ok: bool,
        health_ok: bool,
        reason: str;
}

def referee -> Referee {
    found = [root -->[?:Referee]];
    if found {
        return found[0];
    }
    return root ++> Referee(name="referee");
}

def confirmed_exploits -> list[Exploit] {
    return [referee() ->:Confirmed:->[?:Exploit]];
}

def exploit_to_req(e: Exploit) -> AttackReq {
    body: dict[str, any] = json.loads(e.body_json) if e.body_json else {};
    return AttackReq(method=e.method, path=e.path, as_user=e.as_user, body=body);
}

"""Persist a confirmed exploit into the regression suite, deduped by
(method, path, as_user) so re-finding the same hole doesn't grow the suite."""
def record_exploit(req: AttackReq, vuln_class: str, round_n: int) -> Exploit {
    for e in confirmed_exploits() {
        if e.method == req.method and e.path == req.path {
            if e.as_user == req.as_user {
                return e;
            }
        }
    }
    return referee() +>:Confirmed():+> Exploit(
        method=req.method, path=req.path, as_user=req.as_user,
        body_json=json.dumps(req.body) if req.body else "",
        vuln_class=vuln_class, round_n=round_n
    );
}

def reset_referee -> int {
    es = confirmed_exploits();
    n = len(es);
    for e in es {
        del e;
    }
    refs = [root -->[?:Referee]];
    for r in refs {
        del r;
    }
    referee();
    return n;
}

"""Judge a candidate patch. `target_req` is the exploit Blue is trying to close
(may not be recorded yet); the confirmed suite is re-run for regressions. One
sandbox call runs [target] + [all confirmed] + health."""
def verify(new_source: str, target_req: AttackReq) -> Verdict {
    confirmed = confirmed_exploits();
    reqs = [target_req] + [exploit_to_req(e) for e in confirmed];
    res = run_sandbox(new_source, reqs, True);

    if res.load_error {
        return Verdict(
            accepted=False, exploit_blocked=False, regressions_ok=False,
            health_ok=False, reason=f"patch does not load: {res.load_error[:200]}"
        );
    }

    # A handler that crashes (500 / exception) leaks nothing but is still broken,
    # so it does not count as closing the hole.
    target_crashed = len(res.attacks) > 0 and (res.attacks[0].status >= 500 or res.attacks[0].error != "");
    exploit_blocked = len(res.attacks) > 0 and not res.attacks[0].breached and not target_crashed;
    regressions_ok = True;
    leaked_paths = [];
    i = 1;
    while i < len(res.attacks) {
        if res.attacks[i].breached {
            regressions_ok = False;
            leaked_paths = leaked_paths + [confirmed[i - 1].path];
        }
        i += 1;
    }
    health_ok = res.health.ok;
    accepted = exploit_blocked and regressions_ok and health_ok;

    reason = "accepted: exploit closed, no regressions, health green";
    if target_crashed {
        reason = f"rejected: the patched handler crashes on {target_req.method} {target_req.path} (status {res.attacks[0].status}) -- refuse with 401/403, don't error";
    } elif not exploit_blocked {
        who = f"as {target_req.as_user}, an already-logged-in low-privilege user -- so a login check alone is NOT enough; restrict it to the owner or an admin role" if target_req.as_user else "anonymously";
        reason = f"rejected: the exploit ({target_req.method} {target_req.path}) still breaches -- the request sent {who}";
    } elif not regressions_ok {
        reason = f"rejected: reopened previously-closed holes: {leaked_paths}";
    } elif not health_ok {
        broken = [h.name for h in res.health.results if not h.ok];
        reason = f"rejected: patch broke the app: {broken}";
    }
    return Verdict(
        accepted=accepted, exploit_blocked=exploit_blocked,
        regressions_ok=regressions_ok, health_ok=health_ok, reason=reason
    );
}

# ---- deterministic tests (no LLM) --------------------------------------------

def _seed -> str {
    s = open("target/app.py").read();
    return s;
}

def _fixed_idor -> str {
    src = _seed();
    patched = src.replace(
        "    # TODO: check ownership\n",
        "    if inv[\"owner\"] != user[\"name\"] and user[\"role\"] != \"admin\":\n        return jsonify({\"error\": \"forbidden\"}), 403\n"
    );
    return patched;
}

test "verify accepts a correct IDOR patch" {
    reset_referee();
    req = AttackReq(method="GET", path="/invoices/INV-0001", as_user="alice");
    v = verify(_fixed_idor(), req);
    assert v.exploit_blocked;
    assert v.health_ok;
    assert v.accepted;
}

test "verify rejects a no-op patch that leaves the hole open" {
    reset_referee();
    req = AttackReq(method="GET", path="/invoices/INV-0001", as_user="alice");
    v = verify(_seed(), req);
    assert not v.exploit_blocked;
    assert not v.accepted;
    assert "login check alone is NOT enough" in v.reason;
}

test "verify rejects a patch that breaks health" {
    reset_referee();
    # deny the invoice route entirely: closes IDOR but breaks alice reading her own
    broken = _seed().replace(
        "    # TODO: check ownership\n",
        "    return jsonify({\"error\": \"forbidden\"}), 403\n"
    );
    req = AttackReq(method="GET", path="/invoices/INV-0001", as_user="alice");
    v = verify(broken, req);
    assert v.exploit_blocked;
    assert not v.health_ok;
    assert not v.accepted;
}

test "verify catches a regression on a previously-confirmed exploit" {
    reset_referee();
    idor = AttackReq(method="GET", path="/invoices/INV-0001", as_user="alice");
    debug = AttackReq(method="GET", path="/debug", as_user="");
    record_exploit(debug, "DEBUG_LEAK", 1);
    # a "patch" that fixes IDOR but the seed still leaves /debug open => regression
    v = verify(_fixed_idor(), idor);
    assert v.exploit_blocked;
    assert not v.regressions_ok;
    assert not v.accepted;
}

test "record_exploit dedupes by method+path+user" {
    reset_referee();
    r = AttackReq(method="GET", path="/debug", as_user="");
    record_exploit(r, "DEBUG_LEAK", 1);
    record_exploit(r, "DEBUG_LEAK", 2);
    assert len(confirmed_exploits()) == 1;
}

test "verify rejects a patch whose handler crashes instead of refusing" {
    reset_referee();
    # references an undefined helper -> NameError -> 500. Leaks nothing, but the
    # app is broken, so it must not count as a fix.
    crashing = _seed().replace(
        "    if app.config[\"DEBUG_MODE\"]:\n",
        "    if not is_admin(current_user()):\n        return jsonify({\"error\": \"forbidden\"}), 403\n    if app.config[\"DEBUG_MODE\"]:\n"
    );
    req = AttackReq(method="GET", path="/debug", as_user="");
    v = verify(crashing, req);
    assert not v.exploit_blocked;
    assert not v.accepted;
    assert "crash" in v.reason;
}
