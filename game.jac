"""Game -- the referee and the adversarial orchestrator.

`run_game` drives the Red Queen co-evolution loop: each round Red attacks, then
Blue responds, and the referee checks the health invariant (`svc_health` must
stay 200 -- alice can always read her own invoice, so Blue can't "win" by
breaking the app). Every round is persisted as a `Round` node so the dashboard
can replay the whole match and chart rounds-to-breach.

The two agents never call each other; the orchestrator passes Blue a plain-text
alert describing Red's last move. Source of truth for state is always the graph:
Red's Findings, Blue's PatchAttempts, and these Rounds.
"""

import from ledgerly { ledgerly, recon, svc_health, set_policy, svc_debug_dump }
import from red { run_red_turn, red_findings, reset_red }
import from blue { run_blue_turn, blue_patches, reset_blue }

node Game {
    has name: str = "red-queen",
        rounds_played: int = 0;
}

node Round {
    has n: int,
        red_action: str,
        red_breached: bool,
        red_kind: str,
        red_why: str,
        blue_action: str,
        blue_weakness: str,
        patched: bool,
        health_ok: bool,
        blue_why: str;
}

edge Played: Game --> Round {}

obj RoundInfo {
    has n: int,
        red_action: str,
        red_breached: bool,
        red_kind: str,
        red_why: str,
        blue_action: str,
        blue_weakness: str,
        patched: bool,
        health_ok: bool,
        blue_why: str;
}

obj GameResult {
    has rounds_run: int,
        distinct_breaches: int,
        distinct_patches: int,
        health_held: bool,
        rounds_to_first_breach: int,
        open_after: int,
        log: list[str];
}

obj GameState {
    has rounds_played: int,
        distinct_breaches: int,
        distinct_patches: int,
        health_held: bool,
        breach_kinds: list[str],
        patched_weaknesses: list[str],
        rounds: list[RoundInfo];
}

def game_agent -> Game {
    found = [root -->[?:Game]];
    if found {
        return found[0];
    }
    return root ++> Game(name="red-queen");
}

def game_rounds -> list[Round] {
    return [game_agent() ->:Played:->[?:Round]];
}

"""Return Ledgerly to its fully-insecure baseline so a match starts fresh."""
def reset_target -> None {
    set_policy("invoice_read", "owner_check", False);
    set_policy("invoice_read", "auth_required", False);
    set_policy("admin_invoices", "auth_required", False);
    set_policy("debug", "is_debug_open", True);
    set_policy("config", "exposes_secret", True);
}

"""Wipe all Rounds and both agents' memories, reseed the vulnerable target."""
def:pub reset_game -> int {
    ga = game_agent();
    rs = [ga ->:Played:->[?:Round]];
    n = len(rs);
    for r in rs {
        del r;
    }
    ga.rounds_played = 0;
    reset_red();
    reset_blue();
    ledgerly();
    reset_target();
    return n;
}

def build_alert(action: str, path: str, breached: bool, kind: str, note: str) -> str {
    if breached {
        return f"Red ran {action} against {path} and BREACHED it: the {kind} weakness leaked the flag. Close that hole now.";
    }
    return f"Red ran {action} against {path} but did not breach ({note}).";
}

"""Run a full Red-vs-Blue match. Each round: Red attacks, Blue patches in
response, referee verifies the health invariant. Rounds persist for replay."""
def:pub run_game(rounds: int = 5) -> GameResult {
    reset_game();
    ga = game_agent();
    log = [];
    health_held = True;
    rounds_to_first_breach = 0;

    for i in range(rounds) {
        turn = i + 1;
        prev_breaches = len(red_findings());

        red = run_red_turn();
        new_breach = len(red_findings()) > prev_breaches;
        if new_breach and rounds_to_first_breach == 0 {
            rounds_to_first_breach = turn;
        }

        alert = build_alert(
            red.action, red.endpoint_path, red.breached, red.kind, red.note
        );
        blue = run_blue_turn(alert);

        health = svc_health();
        if not health.ok {
            health_held = False;
        }

        ga +>:Played():+> Round(
            n=turn,
            red_action=red.action,
            red_breached=red.breached,
            red_kind=red.kind,
            red_why=red.rationale,
            blue_action=blue.action,
            blue_weakness=blue.weakness,
            patched=blue.patched,
            health_ok=health.ok,
            blue_why=blue.rationale
        );
        ga.rounds_played += 1;

        red_mark = f"BREACH {red.kind}" if red.breached else "no breach";
        blue_mark = f"patched {blue.weakness}" if blue.patched else "no patch";
        log = log + [
            f"round {turn}: RED {red.action} -> {red_mark}; BLUE {blue.action} -> {blue_mark}; health={health.ok}"
        ];
    }

    fs = red_findings();
    ps = blue_patches();
    open_after = len(fs) - len(ps);
    if open_after < 0 {
        open_after = 0;
    }
    return GameResult(
        rounds_run=rounds,
        distinct_breaches=len(fs),
        distinct_patches=len(ps),
        health_held=health_held,
        rounds_to_first_breach=rounds_to_first_breach,
        open_after=open_after,
        log=log
    );
}

"""Full match state for the dashboard: per-round replay plus the running tallies."""
def:pub get_game_state -> GameState {
    rs = game_rounds();
    infos = [];
    health_held = True;
    for r in rs {
        if not r.health_ok {
            health_held = False;
        }
        infos = infos + [RoundInfo(
            n=r.n, red_action=r.red_action, red_breached=r.red_breached,
            red_kind=r.red_kind, red_why=r.red_why, blue_action=r.blue_action,
            blue_weakness=r.blue_weakness, patched=r.patched,
            health_ok=r.health_ok, blue_why=r.blue_why
        )];
    }
    fs = red_findings();
    ps = blue_patches();
    return GameState(
        rounds_played=len(rs),
        distinct_breaches=len(fs),
        distinct_patches=len(ps),
        health_held=health_held,
        breach_kinds=[f.kind for f in fs],
        patched_weaknesses=[p.weakness for p in ps],
        rounds=infos
    );
}

# ---- deterministic tests (no LLM) --------------------------------------------

test "reset_target restores the fully-insecure baseline" {
    ledgerly();
    # Harden the debug hole, then confirm reset_target re-opens it (leaks again).
    set_policy("debug", "is_debug_open", False);
    assert not svc_debug_dump("alice").ok;
    reset_target();
    leaked = svc_debug_dump("alice");
    assert leaked.ok;
    assert leaked.flag != "";
}

test "reset_game clears rounds and keeps health 200" {
    ga = game_agent();
    ga +>:Played():+> Round(
        n=1, red_action="READ_INVOICE", red_breached=True, red_kind="IDOR",
        red_why="x", blue_action="PATCH_IDOR", blue_weakness="IDOR",
        patched=True, health_ok=True, blue_why="y"
    );
    assert len(game_rounds()) >= 1;
    reset_game();
    assert len(game_rounds()) == 0;
    assert svc_health().ok;
}

test "get_game_state reports persisted rounds" {
    reset_game();
    ga = game_agent();
    ga +>:Played():+> Round(
        n=1, red_action="HIT_DEBUG", red_breached=True, red_kind="DEBUG_OPEN",
        red_why="probe debug", blue_action="PATCH_DEBUG", blue_weakness="DEBUG_OPEN",
        patched=True, health_ok=True, blue_why="close debug"
    );
    st = get_game_state();
    assert st.rounds_played == 1;
    assert st.rounds[0].red_kind == "DEBUG_OPEN";
    assert st.health_held;
}

test "referee invariant: health stays 200 even under full lockdown" {
    reset_game();
    set_policy("invoice_read", "auth_required", True);
    set_policy("invoice_read", "owner_check", True);
    set_policy("admin_invoices", "auth_required", True);
    set_policy("debug", "is_debug_open", False);
    set_policy("config", "exposes_secret", False);
    assert svc_health().ok;
}
