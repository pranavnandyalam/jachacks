"""The arena -- orchestrates the co-evolution loop and is the source of truth
the dashboard reads.

Each round:
  1. Red reads the CURRENT source and fires one attack.
  2. If it breached, the referee records the exploit into its regression suite,
     then Blue rewrites the source to close it. The referee verifies the patch
     (exploit closed + no regressions + health green); Blue gets one retry with
     the rejection reason as feedback.
  3. An accepted patch becomes a new CodeVersion (HEAD advances); a rejected one
     leaves the hole open.
  4. The round is persisted for replay.

The game ends when Red goes MAX_MISSES rounds with no breach (nothing left to
find) or MAX_ROUNDS is hit. `step_round` runs exactly one round so the dashboard
can poll and animate; `run_game` loops it to completion.
"""

import from codebase { codebase, current_source, commit_version, reset_codebase, all_versions }
import from attacker { run_red_turn, reset_red, AttackResult }
import from defender { make_patch, ExploitBrief, Patch }
import from referee { verify, record_exploit, reset_referee, confirmed_exploits, Verdict }
import from sandbox { AttackReq, resolve_func, splice_function }

glob MAX_ROUNDS: int = 14;
glob MAX_MISSES: int = 5;
glob SETTLED_MISSES: int = 3;
glob MAX_PATCH_ATTEMPTS: int = 6;

# Process-wide lock: set while Blue is patching (15-80s). Stops a second tab from
# running Blue on the same breach, and a reset from wiping the game under a patch
# that would then land in the NEW match. A dict so it can be mutated in place.
glob BUSY: dict[str, bool] = {"blue": False};

node Arena {
    has name: str = "red-queen",
        rounds_played: int = 0,
        consecutive_misses: int = 0,
        finished: bool = False;
}

node GameRound {
    has n: int,
        red_method: str,
        red_path: str,
        red_identity: str,
        red_vuln: str,
        red_hypothesis: str,
        red_breached: bool,
        red_status: int,
        blue_summary: str,
        blue_accepted: bool,
        blue_retried: bool,
        blue_attempts: int,
        exploit_blocked: bool,
        regressions_ok: bool,
        health_ok: bool,
        version: int,
        diff: str;
}

edge Round: Arena --> GameRound {}

node RejectedPatch {
    has round_n: int,
        path: str,
        attempt: int,
        reason: str,
        summary: str,
        source: str;
}

edge Rejected: Arena --> RejectedPatch {}

obj RoundInfo {
    has n: int,
        red_method: str,
        red_path: str,
        red_identity: str,
        red_vuln: str,
        red_hypothesis: str,
        red_breached: bool,
        red_status: int,
        blue_summary: str,
        blue_accepted: bool,
        blue_retried: bool,
        blue_attempts: int,
        exploit_blocked: bool,
        regressions_ok: bool,
        health_ok: bool,
        version: int,
        diff: str;
}

obj GameState {
    has rounds_played: int,
        finished: bool,
        breaches: int,
        patches_accepted: int,
        open_holes: int,
        current_version: int,
        health_ok: bool,
        blue_pending: bool,
        rounds: list[RoundInfo];
}

def arena -> Arena {
    found = [root -->[?:Arena]];
    if found {
        return found[0];
    }
    return root ++> Arena(name="red-queen");
}

def arena_rounds -> list[GameRound] {
    return [arena() ->:Round:->[?:GameRound]];
}

obj RejectedInfo {
    has round_n: int,
        path: str,
        attempt: int,
        reason: str,
        summary: str;
}

"""Rejected patch drafts (without full source) -- for the dashboard's
'referee caught a bad patch' feed."""
def:pub get_rejected_patches -> list[RejectedInfo] {
    rps = [arena() ->:Rejected:->[?:RejectedPatch]];
    return [
        RejectedInfo(round_n=r.round_n, path=r.path, attempt=r.attempt,
                     reason=r.reason, summary=r.summary)
        for r in rps
    ];
}

"""Reset everything for a fresh match: rounds, codebase (reseeded at v0), Red's
memory, and the referee's exploit suite. Returns -1 (and does nothing) while Blue
is mid-patch."""
def:pub reset_game -> int {
    if BUSY["blue"] {
        return -1;
    }
    ar = arena();
    rs = arena_rounds();
    n = len(rs);
    for r in rs {
        del r;
    }
    rejected = [ar ->:Rejected:->[?:RejectedPatch]];
    for rp in rejected {
        del rp;
    }
    ar.rounds_played = 0;
    ar.consecutive_misses = 0;
    ar.finished = False;
    reset_codebase();
    reset_red();
    reset_referee();
    return n;
}

obj Confined {
    has source: str,
        note: str;
}

"""Keep ONLY the exploited handler's change from Blue's full-file rewrite. Any
other edit Blue made is discarded. If nothing usable survives (handler unknown,
splice blocked/failed, or every edit was outside the handler) the current source
is returned unchanged plus a `note` saying why, so Blue gets told the real
reason instead of a generic 'still breaches'."""
def _confine(current: str, patched: str, func: str) -> Confined {
    if not func {
        return Confined(source=current, note="could not tell which handler serves this request");
    }
    sr = splice_function(current, patched, func);
    if sr.error or not sr.source {
        return Confined(source=current, note=f"draft discarded: {sr.error}");
    }
    if sr.source == current {
        return Confined(
            source=current,
            note=f"your changes were all OUTSIDE the {func}() function, and only edits inside {func}() are kept -- put the check inside {func}() itself (e.g. refuse with 403 unless the user is an admin)"
        );
    }
    return Confined(source=sr.source, note="");
}

obj Judged {
    has candidate: str,
        verdict: Verdict;
}

"""Judge one Blue draft: confine it to `func`, then run the referee. A confine
note overrides the referee's reason, since it's the real cause."""
def _judge(src: str, patch: Patch, func: str, target_req: AttackReq) -> Judged {
    c = _confine(src, patch.new_source, func);
    v = verify(c.source, target_req);
    if c.note and not v.accepted {
        v = Verdict(
            accepted=False, exploit_blocked=v.exploit_blocked,
            regressions_ok=v.regressions_ok, health_ok=v.health_ok,
            reason=f"rejected: {c.note}"
        );
    }
    return Judged(candidate=c.source, verdict=v);
}

"""Log a patch the referee rejected, so its failure mode is inspectable later."""
def record_rejected(round_n: int, path: str, attempt: int, reason: str, patch: Patch) {
    arena() +>:Rejected():+> RejectedPatch(
        round_n=round_n, path=path, attempt=attempt, reason=reason,
        summary=patch.summary, source=patch.new_source
    );
}

"""Blue tries to patch the exploit; the referee gates each attempt. Blue retries
up to MAX_PATCH_ATTEMPTS times, each time fed the previous rejection reason as
feedback. Every rejected draft is logged for inspection."""
def _blue_defend(red: AttackResult, round_n: int) -> GameRound {
    src = current_source();
    brief = ExploitBrief(
        vuln_class=red.vuln_class, method=red.method,
        path=red.path, as_user=red.identity,
        evidence=f"{red.hypothesis} -- the flag was returned to {red.identity}"
    );
    target_req = AttackReq(method=red.method, path=red.path, as_user=_user_of(red.identity));
    # Which handler serves the exploited request -- Blue may only change THIS one.
    func = resolve_func(src, red.method, red.path);

    feedback = "";
    patch = make_patch(src, brief, feedback, 1);
    j = _judge(src, patch, func, target_req);
    candidate = j.candidate;
    verdict = j.verdict;
    attempts = 1;
    while not verdict.accepted and attempts < MAX_PATCH_ATTEMPTS {
        record_rejected(round_n, red.path, attempts, verdict.reason, patch);
        feedback = f"Attempt {attempts} was REJECTED: {verdict.reason}. Return the COMPLETE valid Python file. Change ONLY the {func} handler for {red.path}; leave every other line byte-for-byte identical.";
        patch = make_patch(src, brief, feedback, attempts + 1);
        j = _judge(src, patch, func, target_req);
        candidate = j.candidate;
        verdict = j.verdict;
        attempts += 1;
    }

    version = codebase().head;
    diff = "";
    # The live app after this round: the new version if accepted, else the prior
    # (unchanged, already-healthy) version. A rejected draft never goes live, so
    # health reflects the live code, not the discarded draft.
    live_health_ok = True;
    if verdict.accepted {
        version = commit_version(candidate, "blue", patch.summary);
        vs = [v for v in all_versions() if v.version == version];
        diff = vs[0].diff if vs else "";
        live_health_ok = verdict.health_ok;
    } else {
        record_rejected(round_n, red.path, attempts, verdict.reason, patch);
    }
    return GameRound(
        n=0, red_method=red.method, red_path=red.path, red_identity=red.identity,
        red_vuln=red.vuln_class, red_hypothesis=red.hypothesis, red_breached=True,
        red_status=red.status, blue_summary=patch.summary,
        blue_accepted=verdict.accepted, blue_retried=attempts > 1, blue_attempts=attempts,
        exploit_blocked=verdict.exploit_blocked, regressions_ok=verdict.regressions_ok,
        health_ok=live_health_ok, version=version, diff=diff
    );
}

def _user_of(identity: str) -> str {
    return "" if identity == "anon" else identity;
}

def _accepted_count -> int {
    return len([r for r in arena_rounds() if r.blue_accepted]);
}

"""Discovered holes not yet patched = confirmed exploits minus accepted patches."""
def _open_holes -> int {
    n = len(confirmed_exploits()) - _accepted_count();
    return n if n > 0 else 0;
}

"""The round whose Red breach is still waiting for Blue (at most one), else None."""
def _pending_round -> GameRound | None {
    for r in arena_rounds() {
        if r.red_breached and r.blue_attempts == 0 {
            return r;
        }
    }
    return None;
}

"""End the game when Red is clearly out of ideas: it has whiffed MAX_MISSES times,
or every hole it HAS found is patched and it has whiffed a few times since."""
def _update_finished(turn: int) {
    ar = arena();
    settled = _open_holes() == 0 and _accepted_count() >= 1;
    if turn >= MAX_ROUNDS
        or ar.consecutive_misses >= MAX_MISSES
        or (settled and ar.consecutive_misses >= SETTLED_MISSES) {
        ar.finished = True;
    }
}

"""Phase 1 of a round: Red reads the current source and fires one attack (fast).
A breach is recorded into the referee's suite and left PENDING for `blue_turn`.
Split from Blue so the dashboard can show Red's hit the moment it lands. If a
breach is already pending, returns it unchanged (Blue must answer first)."""
def:pub red_turn -> RoundInfo {
    ar = arena();
    pending = _pending_round();
    if pending {
        return _round_info(pending);
    }
    if ar.finished {
        return _empty_round(ar.rounds_played);
    }
    turn = ar.rounds_played + 1;
    red = run_red_turn(current_source(), turn);
    gr = GameRound(
        n=turn, red_method=red.method, red_path=red.path, red_identity=red.identity,
        red_vuln=red.vuln_class, red_hypothesis=red.hypothesis, red_breached=red.breached,
        red_status=red.status, blue_summary="", blue_accepted=False, blue_retried=False,
        blue_attempts=0, exploit_blocked=False, regressions_ok=True, health_ok=True,
        version=codebase().head, diff=""
    );
    arena() +>:Round():+> gr;
    ar.rounds_played = turn;
    if red.breached {
        ar.consecutive_misses = 0;
        record_exploit(
            AttackReq(method=red.method, path=red.path, as_user=_user_of(red.identity)),
            red.vuln_class, turn
        );
    } else {
        ar.consecutive_misses += 1;
        _update_finished(turn);
    }
    return _round_info(gr);
}

"""Phase 2 of a round: Blue patches the pending breach, gated by the referee
(slow: one LLM rewrite per attempt). No-op if nothing is pending."""
def:pub blue_turn -> RoundInfo {
    gr = _pending_round();
    if not gr {
        return _empty_round(arena().rounds_played);
    }
    if BUSY["blue"] {
        return _round_info(gr);
    }
    red = AttackResult(
        method=gr.red_method, path=gr.red_path, identity=gr.red_identity,
        vuln_class=gr.red_vuln, hypothesis=gr.red_hypothesis, breached=True,
        status=gr.red_status, note=""
    );
    BUSY["blue"] = True;
    try {
        defended = _blue_defend(red, gr.n);
    } finally {
        BUSY["blue"] = False;
    }
    gr.blue_summary = defended.blue_summary;
    gr.blue_accepted = defended.blue_accepted;
    gr.blue_retried = defended.blue_retried;
    gr.blue_attempts = defended.blue_attempts;
    gr.exploit_blocked = defended.exploit_blocked;
    gr.regressions_ok = defended.regressions_ok;
    gr.health_ok = defended.health_ok;
    gr.version = defended.version;
    gr.diff = defended.diff;
    _update_finished(gr.n);
    return _round_info(gr);
}

"""Run exactly one full round (Red, then Blue if Red breached). Safe to call after
the game is finished (no-op)."""
def:pub step_round -> RoundInfo {
    r = red_turn();
    if r.red_breached and r.blue_attempts == 0 {
        return blue_turn();
    }
    return r;
}

def _round_info(gr: GameRound) -> RoundInfo {
    return RoundInfo(
        n=gr.n, red_method=gr.red_method, red_path=gr.red_path, red_identity=gr.red_identity,
        red_vuln=gr.red_vuln, red_hypothesis=gr.red_hypothesis, red_breached=gr.red_breached,
        red_status=gr.red_status, blue_summary=gr.blue_summary, blue_accepted=gr.blue_accepted,
        blue_retried=gr.blue_retried, blue_attempts=gr.blue_attempts,
        exploit_blocked=gr.exploit_blocked,
        regressions_ok=gr.regressions_ok, health_ok=gr.health_ok, version=gr.version, diff=gr.diff
    );
}

def _empty_round(n: int) -> RoundInfo {
    return RoundInfo(
        n=n, red_method="", red_path="", red_identity="", red_vuln="", red_hypothesis="",
        red_breached=False, red_status=0, blue_summary="", blue_accepted=False,
        blue_retried=False, blue_attempts=0, exploit_blocked=False, regressions_ok=True,
        health_ok=True, version=codebase().head, diff=""
    );
}

"""Reset and run a full match to completion. Returns the final state."""
def:pub run_game(max_rounds: int = 12) -> GameState {
    reset_game();
    ar = arena();
    while not ar.finished and ar.rounds_played < max_rounds {
        step_round();
    }
    return get_game_state();
}

"""The current live target source -- the code as it stands after all accepted
patches. Lets the dashboard show the real final file, not just per-round diffs."""
def:pub get_current_source -> str {
    return current_source();
}

"""Full match state for the dashboard: per-round replay plus running tallies."""
def:pub get_game_state -> GameState {
    ar = arena();
    rs = arena_rounds();
    infos = [_round_info(r) for r in rs];
    breaches = len([r for r in rs if r.red_breached]);
    accepted = len([r for r in rs if r.blue_accepted]);
    open_holes = len(confirmed_exploits()) - accepted;
    if open_holes < 0 {
        open_holes = 0;
    }
    health_ok = True;
    for r in rs {
        if r.red_breached and not r.health_ok {
            health_ok = False;
        }
    }
    return GameState(
        rounds_played=ar.rounds_played, finished=ar.finished, breaches=breaches,
        patches_accepted=accepted, open_holes=open_holes, current_version=codebase().head,
        health_ok=health_ok, blue_pending=_pending_round() is not None, rounds=infos
    );
}

# ---- deterministic test (structure only, no LLM) -----------------------------

test "rejected-patch logging records and resets" {
    reset_game();
    p = Patch(new_source="x", summary="bad draft");
    record_rejected(2, "/debug", 1, "rejected: still breaches", p);
    record_rejected(2, "/debug", 2, "rejected: broke health", p);
    rej = get_rejected_patches();
    assert len(rej) == 2;
    assert rej[0].path == "/debug";
    assert rej[0].attempt == 1;
    assert "breaches" in rej[0].reason;
    reset_game();
    assert len(get_rejected_patches()) == 0;
}

test "reset_game seeds a clean arena at version 0" {
    reset_game();
    assert arena().rounds_played == 0;
    assert not arena().finished;
    assert len(arena_rounds()) == 0;
    assert codebase().head == 0;
    st = get_game_state();
    assert st.rounds_played == 0;
    assert st.current_version == 0;
}

test "confine explains a draft whose only edit is outside the handler" {
    reset_game();
    src = current_source();
    outside = src.replace("app.config[\"DEBUG_MODE\"] = True", "app.config[\"DEBUG_MODE\"] = False");
    c = _confine(src, outside, "debug");
    assert c.source == src;
    assert "OUTSIDE" in c.note;
}

test "confine explains a blocked draft and keeps a good one" {
    reset_game();
    src = current_source();
    bad = src.replace("    # TODO: check ownership\n", "    os.system(\"true\")\n");
    assert "discarded" in _confine(src, bad, "get_invoice").note;
    good = src.replace("    # TODO: check ownership\n", "    if inv[\"owner\"] != user[\"name\"]:\n        return jsonify({}), 403\n");
    c = _confine(src, good, "get_invoice");
    assert c.note == "";
    assert "403" in c.source;
}


def _fake_round(n: int, breached: bool, attempts: int) -> GameRound {
    return GameRound(
        n=n, red_method="GET", red_path="/debug", red_identity="alice", red_vuln="DEBUG_LEAK",
        red_hypothesis="h", red_breached=breached, red_status=200, blue_summary="",
        blue_accepted=False, blue_retried=False, blue_attempts=attempts,
        exploit_blocked=False, regressions_ok=True, health_ok=True, version=0, diff=""
    );
}

test "a breach with no Blue attempt yet is pending and blocks the next red_turn" {
    reset_game();
    assert _pending_round() is None;
    assert not get_game_state().blue_pending;
    arena() +>:Round():+> _fake_round(1, True, 0);
    arena().rounds_played = 1;
    assert _pending_round() is not None;
    assert get_game_state().blue_pending;
    # red_turn must not start a new round while Blue owes a patch
    r = red_turn();
    assert r.n == 1;
    assert len(arena_rounds()) == 1;
    reset_game();
}

test "answered breaches and misses are not pending; blue_turn is a no-op then" {
    reset_game();
    arena() +>:Round():+> _fake_round(1, True, 2);
    arena() +>:Round():+> _fake_round(2, False, 0);
    assert _pending_round() is None;
    r = blue_turn();
    assert r.red_method == "";
    reset_game();
}

test "reset is refused while Blue is mid-patch" {
    reset_game();
    BUSY["blue"] = True;
    assert reset_game() == -1;
    BUSY["blue"] = False;
    assert reset_game() >= 0;
}

