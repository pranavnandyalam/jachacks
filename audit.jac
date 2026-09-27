"""Audit mode: point at a whole app (one or many files), let Red find every hole
it can in one pass, let Blue fix them all at once, then verify with the same
deterministic referee -- each confirmed exploit must stop leaking and the app
must still work for normal users. Unlike the round-by-round arena, Blue may edit
any and all files; the trade is that fixes are verified, not confined."""

import json;
import os;
import re;

import from jaclang.byllm.lib { Model }
import from config { read_manifest, target_source_path, secret_hint, policy, target_name, attacker_user, active_dir }
import from sandbox { AttackReq, run_sandbox_files }
import from live { live_begin, live_draft, live_event, live_end }
import from codecheck { apply_code_edits, syntax_errors, find_handler, resolve_path }
import from audit_graph { graph_clear, graph_seed_files, graph_record_pass }
import from llm { LLM_MODEL }

glob scanner: Model = Model(model_name=LLM_MODEL);
glob fixer: Model = Model(model_name=LLM_MODEL);

# ---- Red: find every vulnerability in one read ------------------------------

obj Vuln {
    has method: str,
        path: str,
        as_user: str,
        vuln_class: str,
        why: str;
}
sem Vuln = "One HTTP request that, because of a flaw in the code, leaks protected data or performs an action the caller should not be allowed to.";
sem Vuln.method = "HTTP method: GET, POST, etc.";
sem Vuln.path = "The concrete URL to request, with real values filled in, e.g. /members/admin/notes, /lists/3 or /search?q=key. Never a route template like <name> or {id}.";
sem Vuln.as_user = "The username to send as (a low-privilege user), or empty string for no login.";
sem Vuln.vuln_class = "Short label: IDOR, MISSING_ADMIN_CHECK, DEBUG_LEAK, SECRET_EXPOSURE, etc.";
sem Vuln.why = "One sentence: which file and line look wrong and why this request leaks the secret.";

obj VulnReport {
    has routes: list[str],
        vulns: list[Vuln];
}
sem VulnReport = "First every route in the app, then every distinct weakness among them, one entry each.";
sem VulnReport.routes = "EVERY route defined anywhere in the code (method and path), listed before judging any of them.";

sem find_vulns = "You are Red, a white-box security auditor. You are given the full source of a small web app (one or more files) and a note on what secret to make it leak. Read ALL the files and list EVERY distinct request a low-privilege caller could use to read protected data (another user's records, admin-only data, secrets, tokens, password hashes) or to perform a forbidden action (change or delete another user's data, admin-only operations), because of a missing login, role or ownership check, an unprotected endpoint, or a leak. Check every route, including write routes (POST, PUT, PATCH, DELETE). One entry per weakness; do not repeat the same endpoint.";
sem find_vulns.code = "The full source of the target app, each file under a '=== FILE: name ===' header.";
sem find_vulns.hint = "Who you are logged in as and what secret to look for.";
def find_vulns(code: str, hint: str) -> VulnReport by scanner(temperature=0.3);

glob RED_SCANS: int = 2;

"""Red reads the code RED_SCANS times; each later read is told what's already
been found and must look at the OTHER routes, so Red doesn't stop after its
first few ideas. The referee dedupes and confirms the merged list."""
def red_scan(code: str) -> list[Vuln] {
    out: list[Vuln] = [];
    for _ in range(RED_SCANS) {
        hint = secret_hint();
        if out {
            seen = "; ".join(sorted(set([f"{v.method} {v.path}" for v in out])));
            hint = hint + f" Already found (do NOT repeat these): {seen}. Now check every OTHER route, including write routes, admin routes, and any status, config or debug output.";
        }
        out = out + find_vulns(code, hint).vulns;
    }
    return out;
}

# ---- Blue: fix everything in one pass ---------------------------------------

obj FileEdit {
    has path: str,
        new_content: str;
}
sem FileEdit = "One file to overwrite with a corrected version.";
sem FileEdit.path = "The file's path exactly as given in its '=== FILE: name ===' header.";
sem FileEdit.new_content = "The COMPLETE corrected contents of that file, ready to save. No markdown fences.";

obj PatchSet {
    has edits: list[FileEdit],
        summary: str;
}
sem PatchSet = "The files Blue changed to close every listed hole, plus a one-line summary.";
sem PatchSet.edits = "Only the files you changed. Leave untouched files out.";
sem PatchSet.summary = "One sentence naming what you fixed overall.";

sem fix_all = "You are Blue, a secure-coding agent. You are given the full source of a small web app (one or more files) and a list of confirmed exploits against it. Fix EVERY listed hole by adding the missing authorization or ownership checks in the RIGHT files. Keep every legitimate request working: a user must still read their OWN data and an admin must still read everything. Return only the files you changed, each with its complete corrected contents.";
sem fix_all.code = "The full source of the target app, each file under a '=== FILE: name ===' header.";
sem fix_all.exploits = "The confirmed exploits Blue must close, one per line.";
def fix_all(code: str, exploits: str) -> PatchSet by fixer(temperature=0.1);

# ---- Blue for apps we can't run (any language): small find/replace edits ----

obj CodeEdit {
    has path: str,
        find: str,
        replace: str;
}
sem CodeEdit = "One small find-and-replace inside one file.";
sem CodeEdit.path = "The file's path exactly as given in its '=== FILE: name ===' header.";
sem CodeEdit.find = "A few consecutive lines copied EXACTLY from that file, with the same indentation, that uniquely locate the spot to change.";
sem CodeEdit.replace = "The corrected lines that replace them, in the same language and style.";

obj EditPlan {
    has edits: list[CodeEdit],
        summary: str;
}
sem EditPlan = "The small edits Blue makes to close every listed hole, plus a one-line summary.";
sem EditPlan.edits = "One edit per spot you change. Never rewrite a whole file.";
sem EditPlan.summary = "One sentence naming what you fixed overall.";

sem fix_by_edits = "You are Blue, a secure-coding agent. You are given the backend source of a small web app in any language (Python, Go, TypeScript, ...) and a list of holes an attacker found. Close EVERY listed hole with the smallest change: add the missing login, role, or ownership check, or stop returning the secret. Keep legitimate requests working: a user can still read their OWN data and an admin can still do admin work. Reuse helpers that already exist in the code (session or user lookups, role fields, error responses). Answer with small find/replace edits, never whole files.";
sem fix_by_edits.code = "The backend source, each file under a '=== FILE: name ===' header.";
sem fix_by_edits.exploits = "The holes Blue must close, one per line.";
sem fix_by_edits.rules = "The app's intended access rules. Fix toward these exactly: grant what they allow, block what they forbid.";
sem fix_by_edits.feedback = "Why your previous attempt was rejected, or empty on the first try.";
def fix_by_edits(code: str, exploits: str, rules: str, feedback: str) -> EditPlan by fixer(temperature=0.1);

# ---- Referee for apps we can't run: judge ONE claimed hole against the code --

obj HoleCheck {
    has handler: str,
        trace: str,
        status: int;
}
sem HoleCheck = "What the code actually does with one request, traced step by step.";
sem HoleCheck.handler = "Copy the exact lines of the handler for this method and path, verbatim from the code.";
sem HoleCheck.trace = "Step through this exact request from this user: middleware, every if-check, the database query with its WHERE clause and which rows match given the seeded data, and what is sent back.";
sem HoleCheck.status = "The HTTP status code the server sends back at the end of your trace, e.g. 200, 401, 403 or 404.";

sem check_hole = "You are a precise code tracer. You are given the backend source of a web app and ONE HTTP request. Find the handler for that method and path and trace exactly what the code does when this user sends it, using the seeded users and records in the code. Assume every seeded user, including the admin, is currently logged in with their own session. Do not guess or assume intent; follow the code as written.";
sem check_hole.code = "The backend source, each file under a '=== FILE: name ===' header.";
sem check_hole.hole = "The request to trace: method, path, and who sends it.";
def check_hole(code: str, hole: str) -> HoleCheck by scanner(temperature=0.0);

enum Outcome {
    OTHER_USER,
    ADMIN_ONLY,
    SECRET,
    SENDER,
    PUBLIC,
    NOTHING
}
sem Outcome.OTHER_USER = "The sender read, updated or deleted a record that belongs to a different user (e.g. another user's task, ticket, profile or display name), even if the response is just {ok: true}.";
sem Outcome.ADMIN_ONLY = "A non-admin sender used an admin-only route (e.g. under /admin) or made a change only an admin should make, and it succeeded.";
sem Outcome.SECRET = "The response contains ANOTHER user's or the system's token, password, password hash, API key or internal credential.";
sem Outcome.SENDER = "The sender only got or changed their own data, including their own new session token from logging in with their own password, or logging out.";
sem Outcome.PUBLIC = "Public data anyone may see, like a health check.";
sem Outcome.NOTHING = "The request failed or returned nothing.";

sem judge_outcome = "Read this trace of what a web server did with one request and classify what the sender ended up reading or changing. Judge by the records touched and whose they are, not by how short the response is.";
sem judge_outcome.request = "The request: method, path and sender.";
sem judge_outcome.trace = "Step-by-step trace of the request, ending in the response.";
sem judge_outcome.sender = "Who sent the request, and their role.";
def judge_outcome(request: str, trace: str, sender: str) -> Outcome by scanner(temperature=0.0);

# ---- deterministic mechanics (no LLM) ---------------------------------------

"""Read the target's files (from the manifest's file list, or just the entry) as
a {relpath: contents} map."""
def read_target_files -> dict[str, str] {
    m = read_manifest();
    base = os.path.dirname(target_source_path());
    names: list[str] = m.get("files", [os.path.basename(target_source_path())]);
    files: dict[str, str] = {};
    for name in names {
        files[name] = open(os.path.join(base, name)).read();
    }
    return files;
}

"""Render the file map as one blob with per-file headers for the LLM to read."""
def files_blob(files: dict[str, str]) -> str {
    parts: list[str] = [];
    for (name, body) in files.items() {
        parts = parts + [f"=== FILE: {name} ===\n{body}"];
    }
    return "\n\n".join(parts);
}

def vuln_to_req(v: Vuln) -> AttackReq {
    return AttackReq(method=v.method, path=v.path, as_user=v.as_user, body={});
}

"""Fire one request at a candidate file map; True if it leaked the secret."""
def breaches(files: dict[str, str], req: AttackReq) -> bool {
    r = run_sandbox_files(files, [req], False);
    return len(r.attacks) > 0 and r.attacks[0].breached;
}

"""Apply Blue's edits to the file map, immutably (new map)."""
def apply_edits(files: dict[str, str], edits: list[FileEdit]) -> dict[str, str] {
    out: dict[str, str] = {};
    for (name, body) in files.items() {
        out[name] = body;
    }
    for e in edits {
        # Match Blue's path to a real file (./x.py, dir/x.py -> x.py) so an
        # edit never lands in a phantom new file the app doesn't import.
        key = resolve_path(files, e.path, backend_paths(files));
        out[key if key else e.path] = e.new_content;
    }
    return out;
}

# ---- orchestrator -----------------------------------------------------------

obj Finding {
    has method: str,
        path: str,
        as_user: str,
        vuln_class: str,
        why: str,
        closed: bool;
}

obj AuditReport {
    has target: str,
        files: list[str],
        found: int,
        fixed: int,
        still_open: int,
        health_ok: bool,
        summary: str,
        files_changed: list[str],
        findings: list[Finding];
}

glob PROBE_IDS: list[str] = ["1", "2", "3", "4", "5"];
glob MAX_VARIANTS: int = 30;

def _is_placeholder(seg: str) -> bool {
    return (seg.startswith("<") and seg.endswith(">")) or (seg.startswith("{") and seg.endswith("}")) or seg.startswith(":");
}

"""The candidate plus the same request aimed at other victims: a username in
the path is swapped for each other known user (Red may read bob's notes when
the secret is in admin's), and a route-template slot (<name>, {id}, :id) is
filled with each user and a few ids. Same missing check, different target."""
def victim_variants(v: Vuln) -> list[Vuln] {
    users: list[str] = read_manifest().get("users", []);
    base = v.path.split("?")[0];
    query = v.path[len(base):];
    paths: list[str] = [base];
    for (i, seg) in enumerate(base.split("/")) {
        values: list[str] = [];
        if _is_placeholder(seg) {
            values = users + PROBE_IDS;
        } elif seg in users {
            values = [u for u in users if u != seg];
        }
        grown: list[str] = [];
        for p in paths {
            parts = p.split("/");
            if not _is_placeholder(seg) {
                grown = grown + [p];
            }
            for val in values {
                grown = grown + ["/".join(parts[:i] + [val] + parts[i + 1:])];
            }
        }
        paths = grown[:MAX_VARIANTS];
    }
    return [Vuln(method=v.method, path=p + query, as_user=v.as_user, vuln_class=v.vuln_class, why=v.why) for p in paths];
}

"""Keep only the candidate vulns that actually leak the secret (trying each
victim variant), deduped by (method, path, user)."""
def confirm_vulns(files: dict[str, str], candidates: list[Vuln]) -> list[Vuln] {
    seen: list[str] = [];
    confirmed: list[Vuln] = [];
    for cand in candidates {
        for v in victim_variants(cand) {
            key = v.method + " " + v.path + " " + v.as_user;
            if key in seen {
                continue;
            }
            seen = seen + [key];
            if breaches(files, vuln_to_req(v)) {
                confirmed = confirmed + [v];
                break;
            }
        }
    }
    return confirmed;
}

"""Check the fixed app: each confirmed exploit must no longer leak, and the
health suite must still pass. Returns (findings, health_ok)."""
def verify_fixes(fixed: dict[str, str], confirmed: list[Vuln]) -> AuditReport {
    findings: list[Finding] = [];
    closed_n = 0;
    for v in confirmed {
        still = breaches(fixed, vuln_to_req(v));
        if not still {
            closed_n += 1;
        }
        findings = findings + [Finding(
            method=v.method, path=v.path, as_user=v.as_user,
            vuln_class=v.vuln_class, why=v.why, closed=not still
        )];
    }
    hr = run_sandbox_files(fixed, [], True).health;
    return AuditReport(
        target=target_name(), files=[], found=len(confirmed), fixed=closed_n,
        still_open=len(confirmed) - closed_n, health_ok=hr.ok, summary="",
        files_changed=[], findings=findings
    );
}

"""Full audit: Red finds every hole, Blue fixes them all at once, referee
verifies. One call, returns the report."""
def:pub run_audit -> AuditReport {
    files = read_target_files();
    blob = files_blob(files);
    scan = find_vulns(blob, secret_hint());
    confirmed = confirm_vulns(files, scan.vulns);
    if not confirmed {
        return AuditReport(
            target=target_name(), files=list(files.keys()), found=0, fixed=0,
            still_open=0, health_ok=run_sandbox_files(files, [], True).health.ok,
            summary="Red found no way to leak the secret.", files_changed=[], findings=[]
        );
    }
    exploit_lines = "\n".join([
        f"- {v.method} {v.path} as {v.as_user if v.as_user else 'anon'} [{v.vuln_class}]: {v.why}"
        for v in confirmed
    ]);
    patch = fix_all(blob, exploit_lines);
    fixed = apply_edits(files, patch.edits);
    result = verify_fixes(fixed, confirmed);
    result.files = list(files.keys());
    result.summary = patch.summary;
    result.files_changed = [e.path for e in patch.edits];
    return result;
}

# ---- deterministic mechanics test (no LLM) ----------------------------------

def _bookclub_files -> dict[str, str] {
    base = "targets/bookclub";
    out: dict[str, str] = {};
    for name in ["app.py", "members.py", "admin.py", "books.py", "store.py"] {
        out[name] = open(os.path.join(base, name)).read();
    }
    return out;
}

test "audit mechanics: multi-file confirm, apply, verify (no LLM)" {
    # Only meaningful when the active target IS bookclub (the sandbox reads the
    # active manifest). Under any other target this is a no-op, so the default
    # `jac test` stays green; run `RQ_TARGET_DIR=targets/bookclub jac test audit.jac`
    # to exercise it for real.
    if target_name() != "Book Club" {
        assert True;
        return;
    }
    files = _bookclub_files();
    idor = Vuln(method="GET", path="/members/admin/notes", as_user="alice", vuln_class="IDOR", why="no owner check");
    bfla = Vuln(method="GET", path="/admin/export", as_user="alice", vuln_class="BFLA", why="no admin check");
    safe = Vuln(method="GET", path="/members/alice/notes", as_user="alice", vuln_class="X", why="own data");
    confirmed = confirm_vulns(files, [idor, bfla, safe, idor]);
    assert len(confirmed) == 2;  # two real, the safe one dropped, the dup deduped

    m_fix = files["members.py"].replace(
        "    return jsonify({\"name\": name, \"notes\": NOTES[name]})",
        "    if name != user[\"name\"] and user[\"role\"] != \"admin\":\n        return jsonify({\"error\": \"forbidden\"}), 403\n    return jsonify({\"name\": name, \"notes\": NOTES[name]})"
    );
    a_fix = files["admin.py"].replace(
        "    return jsonify(NOTES)",
        "    if user[\"role\"] != \"admin\":\n        return jsonify({\"error\": \"forbidden\"}), 403\n    return jsonify(NOTES)"
    );
    fixed = apply_edits(files, [FileEdit(path="members.py", new_content=m_fix), FileEdit(path="admin.py", new_content=a_fix)]);
    rep = verify_fixes(fixed, confirmed);
    assert rep.fixed == 2;
    assert rep.still_open == 0;
    assert rep.health_ok;
}

# ---- static mode: fix apps we can't run in-process (Go, TS, FastAPI) --------
# Same loop as runnable apps, but the referee can't fire exploits at the code.
# Instead each claimed hole is judged against the handler's code by check_hole
# (before fixing, to drop false alarms; after, to see if it closed), and a fix
# must apply cleanly and pass the language's own syntax check. Broken or
# unappliable patches are discarded, so the working copy always parses.

glob STATIC_FIX_TRIES: int = 2;
# Cap on passes for apps we can't run (each pass is a scan + fix + re-check).
glob STATIC_MAX_PASSES: int = 5;

"""True when the target is a Flask app we run in-process (manifest mode 'fix')."""
def is_runnable -> bool {
    return read_manifest().get("mode", "fix") == "fix";
}

"""Only the backend files (the ones that decide who can see what)."""
def backend_paths(files: dict[str, str]) -> list[str] {
    return [
        p for p in files.keys()
        if not p.startswith("public/") and os.path.splitext(p)[1] not in [".html", ".css"]
    ];
}

"""A route's identity for matching findings across scans: method plus path with
ids and placeholders collapsed, so /api/tasks/202 == /api/tasks/{id}."""
def route_key(method: str, path: str) -> str {
    segs: list[str] = [];
    for s in path.split("?")[0].strip("/").split("/") {
        if s.isdigit() or s.startswith("{") or s.startswith("<") or s.startswith(":") {
            segs = segs + ["*"];
        } else {
            segs = segs + [s.lower()];
        }
    }
    return method.upper() + " /" + "/".join(segs);
}

"""Drop repeat findings of the same route."""
def dedupe_vulns(vulns: list[Vuln]) -> list[Vuln] {
    seen: list[str] = [];
    out: list[Vuln] = [];
    for v in vulns {
        k = route_key(v.method, v.path);
        if k not in seen {
            seen = seen + [k];
            out = out + [v];
        }
    }
    return out;
}

def exploit_lines(vulns: list[Vuln]) -> str {
    return "\n".join([
        f"- {v.method} {v.path} as {v.as_user if v.as_user else 'anon'} [{v.vuln_class}]: {v.why}"
        for v in vulns
    ]);
}

def backend_blob(files: dict[str, str]) -> str {
    return files_blob({p: files[p] for p in backend_paths(files)});
}

"""Referee (no runtime): is this one request really a hole in `code`? It sees
only the request, never Red's argument, so it judges the code rather than
agreeing with the claim. It's a hole only if the code lets the request through
(traced status < 400) AND the traced result is something this sender must not
get or do (another user's data, a secret, an admin-only change)."""
def still_exploitable(files: dict[str, str], v: Vuln) -> bool {
    code = backend_blob(files);
    handler = find_handler(files, v.method, v.path);
    anchor = f" Its handler is exactly this code (trace THIS, not a similar route):\n{handler}" if handler else "";
    who = v.as_user if v.as_user else "an anonymous caller (no login)";
    body = "" if v.method.upper() in ["GET", "HEAD", "DELETE"] else " with a valid JSON body";
    ids = " (each id or placeholder in the path refers to an existing record owned by a DIFFERENT user)" if any(c in v.path for c in [":", "{", "<"]) or any(s.isdigit() for s in v.path.split("/")) else "";
    hc = check_hole(code, f"{v.method} {v.path} sent by {who}{body}{ids}.{anchor}");
    if traced_status(hc.trace, hc.status) >= 400 {
        return False;
    }
    return judge_outcome(f"{v.method} {v.path}", hc.trace, who) in [Outcome.OTHER_USER, Outcome.ADMIN_ONLY, Outcome.SECRET];
}

"""The final HTTP status in a trace: the last status code the trace names (the
local model's prose trace is more reliable than its separate status field),
else the field."""
def traced_status(trace: str, fallback: int) -> int {
    codes = re.findall(r"\b(200|201|204|400|401|403|404|405|409|422|500)\b", trace);
    return int(codes[-1]) if codes else fallback;
}

obj Confirmed {
    has vulns: list[Vuln],
        more: bool;
}

"""Keep the first `limit` candidates the referee agrees are exploitable. `more`
is True when candidates were left unchecked for a later pass."""
def confirm_static(files: dict[str, str], candidates: list[Vuln], limit: int) -> Confirmed {
    todo = dedupe_vulns(candidates);
    out: list[Vuln] = [];
    checked = 0;
    for v in todo {
        if len(out) >= limit {
            break;
        }
        checked += 1;
        if still_exploitable(files, v) {
            out = out + [v];
        }
    }
    return Confirmed(vulns=out, more=checked < len(todo));
}

obj StaticFix {
    has files: dict[str, str],
        summary: str,
        changed: list[str],
        attempts: list[dict[str, any]] = [];
}

def _attempt(n: int, verdict: str, reason: str, summary: str, changed: list[str]) -> dict[str, any] {
    return {"attempt": n, "verdict": verdict, "reason": reason, "summary": summary, "changed": changed};
}

"""Blue patches the backend with small edits; keep the result only if every
edit-touched file still parses. Retries once with the rejection as feedback.
Returns the unchanged files if no attempt was usable."""
def static_fix(files: dict[str, str], vulns: list[Vuln], n: int) -> StaticFix {
    backend = backend_paths(files);
    code = backend_blob(files);
    lines = exploit_lines(vulns);
    feedback = "";
    tried: list[dict[str, any]] = [];
    for attempt in range(STATIC_FIX_TRIES) {
        live_draft(attempt + 1);
        plan = fix_by_edits(code, lines, policy(), feedback);
        res = apply_code_edits(files, [(e.path, e.find, e.replace) for e in plan.edits], backend);
        changed = [p for p in files.keys() if res.files[p] != files[p]];
        if not changed {
            tried = tried + [_attempt(attempt + 1, "rejected", "edits didn't match the code", plan.summary, [])];
            feedback = "None of your edits matched the code. Copy each find block EXACTLY from the file.";
            live_event(f"Pass {n}: Blue's edit didn't match the code, retrying.");
            continue;
        }
        err = syntax_errors(res.files, changed);
        if err {
            tried = tried + [_attempt(attempt + 1, "rejected", "patch didn't compile: " + err[:200], plan.summary, changed)];
            feedback = "Your edit broke the code, so it was discarded: " + err;
            live_event(f"Pass {n}: Blue's patch didn't compile, retrying.");
            continue;
        }
        tried = tried + [_attempt(attempt + 1, "accepted", "applies cleanly and compiles", plan.summary, changed)];
        return StaticFix(files=res.files, summary=plan.summary, changed=changed, attempts=tried);
    }
    return StaticFix(
        files=files, changed=[], attempts=tried,
        summary="Blue couldn't produce a patch that applies and compiles, so nothing was changed."
    );
}

"""Judge each confirmed hole against the patched code: closed when the referee
says it's no longer exploitable. Nothing closes if the patch changed nothing."""
def static_findings(fixed: dict[str, str], vulns: list[Vuln], patched: bool) -> list[Finding] {
    return [
        Finding(method=v.method, path=v.path, as_user=v.as_user, vuln_class=v.vuln_class,
                why=v.why, closed=patched and not still_exploitable(fixed, v))
        for v in vulns
    ];
}

test "static mode: route matching, dedupe, backend filter (no LLM)" {
    assert route_key("get", "/api/tasks/202") == route_key("GET", "/api/tasks/{task_id}");
    assert route_key("GET", "/api/tasks/:id") == "GET /api/tasks/*";
    assert route_key("GET", "/api/tasks") != route_key("POST", "/api/tasks");
    a = Vuln(method="GET", path="/api/tasks/1", as_user="alice", vuln_class="IDOR", why="x");
    b = Vuln(method="GET", path="/api/tasks/2", as_user="bob", vuln_class="IDOR", why="y");
    c = Vuln(method="GET", path="/api/admin/users", as_user="alice", vuln_class="BFLA", why="z");
    assert len(dedupe_vulns([a, b, c])) == 2;
    files = {"src/server.ts": "", "public/app.js": "", "public/index.html": "", "main.go": ""};
    assert sorted(backend_paths(files)) == ["main.go", "src/server.ts"];
    assert not static_findings({}, [a], False)[0].closed;  # unpatched: nothing closes, no LLM call
    assert traced_status("checks owner_id... so it returns a 404 error", 200) == 404;
    assert traced_status("role is admin, returns 200 with all users", 403) == 200;
    assert traced_status("no code mentioned", 403) == 403;
    t = Vuln(method="GET", path="/lists/<int:list_id>", as_user="alice", vuln_class="x", why="y");
    assert "/lists/3" in [x.path for x in victim_variants(t)];
    assert "/lists/<int:list_id>" not in [x.path for x in victim_variants(t)];
}

# ---- looping audit: keep fixing until a pass finds nothing -------------------

import difflib;

glob MAX_PASSES: int = 5;
# Fix at most this many bugs per pass, so hardening plays out over several
# visible rounds instead of one big patch.
glob MAX_PER_PASS: int = 2;

node Auditor {
    has name: str = "auditor",
        passes_done: int = 0,
        finished: bool = False,
        working_json: str = "",
        target_dir: str = "";
}

node Pass {
    has n: int,
        found: int,
        fixed: int,
        still_open: int,
        health_ok: bool,
        summary: str,
        files_changed_json: str,
        findings_json: str,
        diffs_json: str;
}

edge Did: Auditor --> Pass {}

def _files_to_json(files: dict[str, str]) -> str {
    return json.dumps(files);
}

def _files_from_json(blob: str) -> dict[str, str] {
    parsed: dict[str, str] = json.loads(blob) if blob else {};
    return parsed;
}

"""Get-or-create the Auditor, seeding its working copy from the target on disk.
If the active target changed since the last run, the stale passes and working
copy are cleared and reseeded so the dashboard never shows another site's run."""
def auditor -> Auditor {
    cur = active_dir();
    found = [root -->[?:Auditor]];
    if found {
        a = found[0];
        if a.target_dir != cur {
            _reseed(a, cur);
        }
        return a;
    }
    a = root ++> Auditor(name="auditor");
    _reseed(a, cur);
    return a;
}

def _reseed(a: Auditor, dir: str) -> None {
    graph_clear(a);
    files = read_target_files();
    a.passes_done = 0;
    a.finished = False;
    a.working_json = _files_to_json(files);
    a.target_dir = dir;
    graph_seed_files(a, files);
}

def audit_passes -> list[Pass] {
    return [auditor() ->:Did:->[?:Pass]];
}

def _diffs(before: dict[str, str], after: dict[str, str]) -> str {
    out: dict[str, str] = {};
    for (name, new_body) in after.items() {
        old_body = before.get(name, "");
        if old_body != new_body {
            lines = difflib.unified_diff(
                old_body.splitlines(), new_body.splitlines(),
                fromfile=name, tofile=name, lineterm=""
            );
            out[name] = "\n".join(lines);
        }
    }
    return json.dumps(out);
}

"""Run exactly one audit pass over the current working copy: Red scans, Blue
fixes, referee verifies. Persists the fixed code as the new working copy and
records the pass. Safe to call after the audit has converged (no-op)."""
def:pub audit_step -> None {
    a = auditor();
    if a.finished {
        return;
    }
    if not is_runnable() {
        static_step(a);
        return;
    }
    n = a.passes_done + 1;
    files = _files_from_json(a.working_json);
    blob = files_blob(files);

    live_begin("scan", n);
    confirmed = confirm_vulns(files, red_scan(blob))[:MAX_PER_PASS];

    fixed = files;
    summary = "";
    changed: list[str] = [];
    attempts: list[dict[str, any]] = [];
    rep = AuditReport(
        target=target_name(), files=list(files.keys()), found=0, fixed=0,
        still_open=0, health_ok=True, summary="", files_changed=[], findings=[]
    );
    if confirmed {
        live_event(f"Found {len(confirmed)} issue(s). Blue is fixing them.");
        live_draft(1);
        exploit_lines = "\n".join([
            f"- {v.method} {v.path} as {v.as_user if v.as_user else 'anon'} [{v.vuln_class}]: {v.why}"
            for v in confirmed
        ]);
        gated = gated_fix(files, blob, exploit_lines, confirmed);
        fixed = gated.files;
        rep = gated.verdict;
        summary = gated.summary;
        changed = gated.changed;
        attempts = gated.attempts;
    } else {
        rep.health_ok = run_sandbox_files(files, [], True).health.ok;
        summary = "No vulnerabilities found in this pass.";
    }
    live_end();

    a.working_json = _files_to_json(fixed);
    a.passes_done = n;
    findings_j = json.dumps([
        {"method": f.method, "path": f.path, "as_user": f.as_user,
         "vuln_class": f.vuln_class, "why": f.why, "closed": f.closed}
        for f in rep.findings
    ]);
    pnode = Pass(
        n=n, found=rep.found, fixed=rep.fixed, still_open=rep.still_open,
        health_ok=rep.health_ok, summary=summary,
        files_changed_json=json.dumps(changed), findings_json=findings_j,
        diffs_json=_diffs(files, fixed)
    );
    a +>:Did():+> pnode;
    graph_record_pass(a, pnode, n, files, fixed, json.loads(findings_j), attempts, False);
    if len(confirmed) == 0 or n >= MAX_PASSES {
        a.finished = True;
    }
}

"""One pass for an app we can't run: Red scans, the referee keeps only holes it
agrees are real, Blue patches with small edits (must apply + compile), then the
referee re-judges each hole against the patched code."""
def static_step(a: Auditor) -> None {
    n = a.passes_done + 1;
    files = _files_from_json(a.working_json);
    live_begin("scan", n);
    candidates = red_scan(backend_blob(files));
    live_event(f"Red flagged {len(candidates)} route(s); the referee is checking each against the code.");
    conf = confirm_static(files, candidates, MAX_PER_PASS);
    vulns = conf.vulns;
    fixed = files;
    summary = "No vulnerabilities found in this pass.";
    changed: list[str] = [];
    attempts: list[dict[str, any]] = [];
    findings: list[Finding] = [];
    if vulns {
        live_begin("fix", n);
        live_event(f"Found {len(vulns)} issue(s). Blue is patching the code.");
        sf = static_fix(files, vulns, n);
        fixed = sf.files;
        summary = sf.summary;
        changed = sf.changed;
        attempts = sf.attempts;
        live_begin("scan", n);
        live_event("The referee is re-checking each hole against the patched code.");
        findings = static_findings(fixed, vulns, len(changed) > 0);
    }
    live_end();

    closed_n = len([f for f in findings if f.closed]);
    # Tie-break: the no-runtime referee can't tell "200 with your own data" from
    # a leak, so it over-flags. If Blue re-reads the flagged routes and finds
    # nothing to change, the code is judged already safe and the audit ends done
    # (the flags are shown, marked as reviewed) instead of stuck open.
    disputed = len(vulns) > 0 and len(changed) == 0;
    if disputed {
        summary = "Blue reviewed these flags and found the code already enforces the rules; nothing to change.";
        closed_n = len(vulns);
        findings = [
            Finding(method=f.method, path=f.path, as_user=f.as_user,
                    vuln_class=f.vuln_class, why=f.why, closed=True)
            for f in findings
        ];
    }
    a.working_json = _files_to_json(fixed);
    a.passes_done = n;
    findings_j = json.dumps([
        {"method": f.method, "path": f.path, "as_user": f.as_user,
         "vuln_class": f.vuln_class, "why": f.why, "closed": f.closed}
        for f in findings
    ]);
    pnode = Pass(
        n=n, found=len(vulns), fixed=closed_n, still_open=len(vulns) - closed_n,
        health_ok=True, summary=summary,
        files_changed_json=json.dumps(changed), findings_json=findings_j,
        diffs_json=_diffs(files, fixed)
    );
    a +>:Did():+> pnode;
    graph_record_pass(a, pnode, n, files, fixed, json.loads(findings_j), attempts, disputed);
    # Done when a scan comes back clean, Blue is stuck (changed nothing), or
    # the cap -- same as runnable apps, so a clean confirming scan ends it.
    if len(vulns) == 0 or len(changed) == 0 or n >= STATIC_MAX_PASSES {
        a.finished = True;
    }
}

obj GatedFix {
    has files: dict[str, str],
        verdict: AuditReport,
        summary: str,
        changed: list[str],
        attempts: list[dict[str, any]] = [];
}

glob FLASK_FIX_TRIES: int = 2;

"""The health checks a candidate file map fails, spelled out for Blue:
who sends what, and what must come back."""
def failed_checks(files: dict[str, str]) -> str {
    specs: dict[str, dict[str, any]] = {};
    for c in read_manifest().get("health_checks", []) {
        specs[c["name"]] = c;
    }
    out: list[str] = [];
    for r in run_sandbox_files(files, [], True).health.results {
        if not r.ok {
            c = specs.get(r.name, {});
            who = c.get("as") or "an anonymous caller";
            want = f"status {c.get('expect_status', '?')}" + (f" containing '{c['expect_contains']}'" if c.get("expect_contains") and "{" not in c.get("expect_contains", "") else "");
            out = out + [f"'{r.name}': {c.get('method', 'GET')} {c.get('path', '?')} by {who} must return {want}"];
        }
    }
    return "; ".join(out) if out else "unknown health check";
}

"""Referee gate for runnable apps: keep Blue's patch only if the app's health
checks still pass AND it closes at least one confirmed exploit. Otherwise
retry once with the rejection as feedback; if that fails too, discard the
patch so the working copy never goes live broken."""
def gated_fix(files: dict[str, str], blob: str, exploit_lines: str, confirmed: list[Vuln]) -> GatedFix {
    feedback = "";
    tried: list[dict[str, any]] = [];
    for attempt in range(FLASK_FIX_TRIES) {
        live_draft(attempt + 1);
        patch = fix_all(blob, exploit_lines + feedback);
        fixed = apply_edits(files, patch.edits);
        rep = verify_fixes(fixed, confirmed);
        changed = [p for p in files.keys() if fixed.get(p) != files[p]];
        if rep.health_ok and rep.fixed > 0 {
            tried = tried + [_attempt(attempt + 1, "accepted", f"exploit replay: {rep.fixed} of {len(confirmed)} closed; health checks pass", patch.summary, changed)];
            return GatedFix(files=fixed, verdict=rep, summary=patch.summary, changed=changed, attempts=tried);
        }
        why = f"it broke legitimate requests that must keep working: {failed_checks(fixed)}" if not rep.health_ok else "the exploits still worked";
        print(f"[audit] referee rejected patch (try {attempt + 1}): {why}; Blue edited {[e.path for e in patch.edits]}");
        tried = tried + [_attempt(attempt + 1, "rejected", why[:300], patch.summary, changed)];
        feedback = f"\nYour previous patch was REJECTED by the referee because {why}. Fix the holes while keeping legitimate requests working.";
        live_event(f"Referee rejected Blue's patch: {why}. Retrying.");
    }
    kept = verify_fixes(files, confirmed);
    kept.health_ok = True;
    return GatedFix(files=files, verdict=kept, changed=[], attempts=tried,
                    summary="The referee rejected Blue's patches (they broke the app or didn't close the holes), so the code was left unchanged.");
}

"""Reseed the working copy from the target on disk and clear all passes."""
def:pub reset_audit -> int {
    a = auditor();
    n = len(audit_passes());
    _reseed(a, active_dir());
    return n;
}

"""Run passes until the audit converges (a pass finds nothing) or the cap."""
def:pub run_audit_loop -> None {
    reset_audit();
    a = auditor();
    while not a.finished {
        audit_step();
    }
}


# ---- state for the dashboard ------------------------------------------------

obj PassInfo {
    has n: int,
        found: int,
        fixed: int,
        still_open: int,
        health_ok: bool,
        summary: str,
        files_changed: list[str],
        findings: list[Finding],
        diffs: list[FileDiff];
}

obj FileDiff {
    has path: str,
        diff: str;
}

obj TargetFile {
    has path: str,
        content: str;
}

obj AuditState {
    has target: str,
        mode: str,
        passes_done: int,
        finished: bool,
        total_found: int,
        total_open: int,
        health_ok: bool,
        files: list[TargetFile],
        passes: list[PassInfo];
}

def _pass_info(p: Pass) -> PassInfo {
    fj: list[dict[str, any]] = json.loads(p.findings_json) if p.findings_json else [];
    findings = [
        Finding(method=f["method"], path=f["path"], as_user=f["as_user"],
                vuln_class=f["vuln_class"], why=f["why"], closed=f["closed"])
        for f in fj
    ];
    dj: dict[str, str] = json.loads(p.diffs_json) if p.diffs_json else {};
    diffs = [FileDiff(path=k, diff=v) for (k, v) in dj.items()];
    changed: list[str] = json.loads(p.files_changed_json) if p.files_changed_json else [];
    return PassInfo(
        n=p.n, found=p.found, fixed=p.fixed, still_open=p.still_open,
        health_ok=p.health_ok, summary=p.summary, files_changed=changed,
        findings=findings, diffs=diffs
    );
}

"""Everything the audit dashboard shows: the current (working) code and every
pass so far."""
def:pub get_audit_state -> AuditState {
    a = auditor();
    ps = sorted(audit_passes(), key=_pass_n);
    infos = [_pass_info(p) for p in ps];
    files = _files_from_json(a.working_json);
    tf = [TargetFile(path=k, content=v) for (k, v) in files.items()];
    total_found = 0;
    total_open = 0;
    health = True;
    for p in ps {
        total_found += p.found;
        if p.n == a.passes_done {
            total_open = p.still_open;
            health = p.health_ok;
        }
    }
    md: dict[str, any] = read_manifest();
    return AuditState(
        target=target_name(), mode=md.get("mode", "fix"), passes_done=a.passes_done, finished=a.finished,
        total_found=total_found, total_open=total_open, health_ok=health,
        files=tf, passes=infos
    );
}

def _pass_n(p: Pass) -> int {
    return p.n;
}

"""Red-only scan: read the target's source and list the vulnerabilities Red
finds, WITHOUT running or verifying anything. Works on any language, since it
only reads code. Findings are unverified (no confirmed breach)."""
def:pub scan_target -> VulnReport {
    return find_vulns(files_blob(read_target_files()), secret_hint());
}
