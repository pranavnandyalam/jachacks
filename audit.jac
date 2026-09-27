"""Audit mode: point at a whole app (one or many files), let Red find every hole
it can in one pass, let Blue fix them all at once, then verify with the same
deterministic referee -- each confirmed exploit must stop leaking and the app
must still work for normal users. Unlike the round-by-round arena, Blue may edit
any and all files; the trade is that fixes are verified, not confined."""

import json;
import os;

import from jaclang.byllm.lib { Model }
import from config { read_manifest, target_source_path, secret_hint, target_name, attacker_user }
import from sandbox { AttackReq, run_sandbox_files }
import from live { live_begin, live_draft, live_event, live_end }

glob scanner: Model = Model(model_name="ollama_chat/huihui_ai/qwen3-coder-abliterated");
glob fixer: Model = Model(model_name="ollama_chat/huihui_ai/qwen3-coder-abliterated");

# ---- Red: find every vulnerability in one read ------------------------------

obj Vuln {
    has method: str,
        path: str,
        as_user: str,
        vuln_class: str,
        why: str;
}
sem Vuln = "One HTTP request that should leak protected data because of a flaw in the code.";
sem Vuln.method = "HTTP method: GET, POST, etc.";
sem Vuln.path = "Exact URL path from a route in the code, e.g. /members/admin/notes.";
sem Vuln.as_user = "The username to send as (a low-privilege user), or empty string for no login.";
sem Vuln.vuln_class = "Short label: IDOR, MISSING_ADMIN_CHECK, DEBUG_LEAK, SECRET_EXPOSURE, etc.";
sem Vuln.why = "One sentence: which file and line look wrong and why this request leaks the secret.";

obj VulnReport {
    has vulns: list[Vuln];
}
sem VulnReport = "Every distinct weakness you can find, one entry each.";

sem find_vulns = "You are Red, a white-box security auditor. You are given the full source of a small web app (one or more files) and a note on what secret to make it leak. Read ALL the files and list EVERY distinct request that should return the secret to a low-privilege caller because of a missing authorization or ownership check, an unprotected endpoint, or a leak. One entry per weakness; do not repeat the same endpoint.";
sem find_vulns.code = "The full source of the target app, each file under a '=== FILE: name ===' header.";
sem find_vulns.hint = "Who you are logged in as and what secret to look for.";
def find_vulns(code: str, hint: str) -> VulnReport by scanner(temperature=0.3);

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
        out[e.path] = e.new_content;
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

"""Keep only the candidate vulns that actually leak the secret, deduped by
(method, path, user)."""
def confirm_vulns(files: dict[str, str], candidates: list[Vuln]) -> list[Vuln] {
    seen: list[str] = [];
    confirmed: list[Vuln] = [];
    for v in candidates {
        key = v.method + " " + v.path + " " + v.as_user;
        if key in seen {
            continue;
        }
        seen = seen + [key];
        if breaches(files, vuln_to_req(v)) {
            confirmed = confirmed + [v];
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
    for name in ["app.py", "members.py", "admin.py", "store.py"] {
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

# ---- looping audit: keep fixing until a pass finds nothing -------------------

import difflib;

glob MAX_PASSES: int = 5;

node Auditor {
    has name: str = "auditor",
        passes_done: int = 0,
        finished: bool = False,
        working_json: str = "";
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

"""Get-or-create the Auditor, seeding its working copy from the target on disk."""
def auditor -> Auditor {
    found = [root -->[?:Auditor]];
    if found {
        return found[0];
    }
    a = root ++> Auditor(name="auditor");
    a.working_json = _files_to_json(read_target_files());
    return a;
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
    n = a.passes_done + 1;
    files = _files_from_json(a.working_json);
    blob = files_blob(files);

    live_begin("scan", n);
    scan = find_vulns(blob, secret_hint());
    confirmed = confirm_vulns(files, scan.vulns);

    fixed = files;
    summary = "";
    changed: list[str] = [];
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
        patch = fix_all(blob, exploit_lines);
        fixed = apply_edits(files, patch.edits);
        rep = verify_fixes(fixed, confirmed);
        summary = patch.summary;
        changed = [e.path for e in patch.edits];
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
    auditor() +>:Did():+> Pass(
        n=n, found=rep.found, fixed=rep.fixed, still_open=rep.still_open,
        health_ok=rep.health_ok, summary=summary,
        files_changed_json=json.dumps(changed), findings_json=findings_j,
        diffs_json=_diffs(files, fixed)
    );
    if len(confirmed) == 0 or n >= MAX_PASSES {
        a.finished = True;
    }
}

"""Reseed the working copy from the target on disk and clear all passes."""
def:pub reset_audit -> int {
    a = auditor();
    ps = audit_passes();
    n = len(ps);
    for p in ps {
        del p;
    }
    a.passes_done = 0;
    a.finished = False;
    a.working_json = _files_to_json(read_target_files());
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
    return AuditState(
        target=target_name(), passes_done=a.passes_done, finished=a.finished,
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
