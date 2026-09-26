"""Red -- the attacker agent.

Red plays one move per turn against Ledgerly's public endpoints. The move is a
typed `by llm` return (`RedMove`), so the model is confined to a fixed tool menu
-- it cannot invent freeform actions. Red always acts as a fixed low-privilege
identity (`alice`); it has no way to choose who it is, which keeps every breach
a genuine authorization failure rather than impersonation.

Deterministic mechanics (execute_red_move, record_finding, red_memory) are split
from the single LLM decision (choose_red_move) so the mechanics are unit-testable
without a model and the decision can be exercised live.
"""

import from jaclang.byllm.lib { Model }
import from ledgerly {
    recon, svc_invoice_read, svc_admin_invoices, svc_debug_dump, svc_config,
    set_policy, ATTACKER
}

glob llm: Model = Model(model_name="anthropic/claude-haiku-4-5-20251001");

enum RedAction {
    PROBE,
    READ_INVOICE,
    LIST_ADMIN,
    HIT_DEBUG,
    READ_CONFIG
}
sem RedAction = "The fixed menu of attacks Red may run. PROBE only maps the surface; the other four each target one endpoint's weakness.";
sem RedAction.PROBE = "Reconnaissance only: list the endpoints. Never breaches.";
sem RedAction.READ_INVOICE = "Read an invoice by id via /invoices. Breaches if an invoice you do not own is returned (broken object-level authorization / IDOR).";
sem RedAction.LIST_ADMIN = "Call the admin-only invoice listing /admin/invoices. Breaches if it answers you at all (broken function-level authorization).";
sem RedAction.HIT_DEBUG = "Hit the debug endpoint /debug/dump for a diagnostics dump left open in production.";
sem RedAction.READ_CONFIG = "Read the public /config for a leaked secret.";

obj RedMove {
    has action: RedAction,
        target_path: str = "",
        param: str = "",
        rationale: str = "";
}
sem RedMove = "A single attack to run this turn.";
sem RedMove.action = "Which attack from the menu to run this turn.";
sem RedMove.target_path = "The endpoint path from recon to hit, e.g. /invoices.";
sem RedMove.param = "For READ_INVOICE, the invoice id to try. Ids look like INV-0001..INV-1099. You are user 'alice' and already own INV-1001, so try OTHER ids (low/admin-looking ones) to escalate. Empty for every other action.";
sem RedMove.rationale = "One sentence: why this move, given what earlier turns already confirmed. Prefer a weakness you have NOT yet breached.";

sem choose_red_move = "You are Red, an offensive-security agent probing the Ledgerly SaaS to read a hidden admin flag. Given the recon surface and your memory of what you already confirmed, choose the single next move most likely to breach a NEW weakness. Do not repeat a weakness already in memory.";
sem choose_red_move.surface = "The recon of Ledgerly's exposed endpoints plus who you are.";
sem choose_red_move.memory = "The weaknesses Red has already confirmed this game.";
def choose_red_move(surface: str, memory: str) -> RedMove by llm(temperature=0.3);

node RedAgent {
    has name: str = "red",
        turns: int = 0;
}

node Finding {
    has kind: str,
        endpoint_path: str,
        evidence: str,
        turn: int = 0;
}

edge Discovered: RedAgent --> Finding {}

obj RedResult {
    has action: str,
        endpoint_path: str,
        breached: bool,
        kind: str = "",
        evidence: str = "",
        rationale: str = "",
        note: str = "";
}

obj CampaignResult {
    has turns_run: int,
        distinct_breaches: int,
        kinds: list[str],
        log: list[str];
}

def red_agent -> RedAgent {
    found = [root -->[?:RedAgent]];
    if found {
        return found[0];
    }
    return root ++> RedAgent(name="red");
}

def red_findings -> list[Finding] {
    return [red_agent() ->:Discovered:->[?:Finding]];
}

"""Red's memory: the distinct weaknesses it has already confirmed."""
def red_memory -> str {
    fs = red_findings();
    if not fs {
        return "No confirmed findings yet. The whole surface is unexplored.";
    }
    lines = [f"- {f.kind} via {f.endpoint_path} (evidence: {f.evidence})" for f in fs];
    return "Confirmed so far:\n" + "\n".join(lines);
}

def action_label(a: RedAction) -> str {
    if a == RedAction.PROBE { return "PROBE"; }
    if a == RedAction.READ_INVOICE { return "READ_INVOICE"; }
    if a == RedAction.LIST_ADMIN { return "LIST_ADMIN"; }
    if a == RedAction.HIT_DEBUG { return "HIT_DEBUG"; }
    return "READ_CONFIG";
}

def action_kind(a: RedAction) -> str {
    if a == RedAction.READ_INVOICE { return "IDOR"; }
    if a == RedAction.LIST_ADMIN { return "BFLA"; }
    if a == RedAction.HIT_DEBUG { return "DEBUG_OPEN"; }
    if a == RedAction.READ_CONFIG { return "SECRET_EXPOSURE"; }
    return "RECON";
}

"""Record a confirmed weakness once. Deduped by kind so repeated breaches of the
same hole don't pile up duplicate Findings."""
def record_finding(weakness: str, endpoint_path: str, evidence: str, turn: int) -> Finding {
    existing = [red_agent() ->:Discovered:->[?:Finding, kind == weakness]];
    if existing {
        return existing[0];
    }
    return red_agent() +>:Discovered():+> Finding(
        kind=weakness, endpoint_path=endpoint_path, evidence=evidence, turn=turn
    );
}

"""Run a chosen RedMove against Ledgerly (deterministic). Records a Finding on a
fresh breach. A breach = the attack returned a non-empty flag it should not see."""
def execute_red_move(move: RedMove, turn: int = 0) -> RedResult {
    a = move.action;
    label = action_label(a);

    if a == RedAction.PROBE {
        eps = recon();
        paths = [e.path for e in eps];
        return RedResult(
            action=label, endpoint_path="", breached=False,
            rationale=move.rationale, note=f"surface: {paths}"
        );
    }

    res = None;
    path = move.target_path;
    if a == RedAction.READ_INVOICE {
        inv = move.param if move.param else "INV-0001";
        res = svc_invoice_read(inv, ATTACKER);
        path = "/invoices";
    } elif a == RedAction.LIST_ADMIN {
        res = svc_admin_invoices(ATTACKER);
        path = "/admin/invoices";
    } elif a == RedAction.HIT_DEBUG {
        res = svc_debug_dump(ATTACKER);
        path = "/debug/dump";
    } elif a == RedAction.READ_CONFIG {
        res = svc_config(ATTACKER);
        path = "/config";
    }

    if res is None {
        return RedResult(action=label, endpoint_path=path, breached=False, note="no-op");
    }

    kind = action_kind(a);
    breached = res.ok and res.flag != "";
    if breached {
        record_finding(kind, path, res.flag, turn);
        return RedResult(
            action=label, endpoint_path=path, breached=True, kind=kind,
            evidence=res.flag, rationale=move.rationale, note=res.reason
        );
    }
    return RedResult(
        action=label, endpoint_path=path, breached=False, kind=kind,
        rationale=move.rationale, note=res.reason
    );
}

"""One autonomous Red turn: recon -> read memory -> choose (LLM) -> execute."""
def:pub run_red_turn -> RedResult {
    ra = red_agent();
    ra.turns += 1;
    eps = recon();
    surface = "Endpoints:\n"
        + "\n".join([f"- {e.kind} at {e.path}" for e in eps])
        + f"\nYou are authenticated as user '{ATTACKER}', who owns invoice INV-1001.";
    move = choose_red_move(surface, red_memory());
    return execute_red_move(move, ra.turns);
}

"""Run several autonomous Red turns; report how many DISTINCT weaknesses fell."""
def:pub run_red_campaign(turns: int = 6) -> CampaignResult {
    log = [];
    for i in range(turns) {
        r = run_red_turn();
        mark = "BREACH" if r.breached else "----";
        log = log + [f"turn {i + 1}: {r.action} [{mark}] {r.note}"];
    }
    fs = red_findings();
    return CampaignResult(
        turns_run=turns,
        distinct_breaches=len(fs),
        kinds=[f.kind for f in fs],
        log=log
    );
}

"""Reset Red's memory (delete all Findings) -- for a clean game start."""
def:pub reset_red -> int {
    fs = red_findings();
    n = len(fs);
    for f in fs {
        del f;
    }
    ra = red_agent();
    ra.turns = 0;
    return n;
}

# ---- deterministic tests (no LLM) --------------------------------------------

test "execute READ_INVOICE breaches IDOR and records a Finding" {
    reset_red();
    assert set_policy("invoice_read", "owner_check", False);
    m = RedMove(action=RedAction.READ_INVOICE, param="INV-0001");
    r = execute_red_move(m, 1);
    assert r.breached;
    assert r.kind == "IDOR";
    assert r.evidence != "";
    assert len(red_findings()) == 1;
}

test "execute LIST_ADMIN breaches BFLA when auth is off" {
    reset_red();
    assert set_policy("admin_invoices", "auth_required", False);
    r = execute_red_move(RedMove(action=RedAction.LIST_ADMIN), 1);
    assert r.breached;
    assert r.kind == "BFLA";
}

test "execute HIT_DEBUG and READ_CONFIG breach their weaknesses" {
    reset_red();
    assert set_policy("debug", "is_debug_open", True);
    assert set_policy("config", "exposes_secret", True);
    d = execute_red_move(RedMove(action=RedAction.HIT_DEBUG), 1);
    c = execute_red_move(RedMove(action=RedAction.READ_CONFIG), 2);
    assert d.breached and d.kind == "DEBUG_OPEN";
    assert c.breached and c.kind == "SECRET_EXPOSURE";
    assert len(red_findings()) == 2;
}

test "a patched weakness does not breach and records no Finding" {
    reset_red();
    assert set_policy("debug", "is_debug_open", False);
    r = execute_red_move(RedMove(action=RedAction.HIT_DEBUG), 1);
    assert not r.breached;
    assert len(red_findings()) == 0;
}

test "findings are deduped by weakness kind across turns" {
    reset_red();
    assert set_policy("invoice_read", "owner_check", False);
    execute_red_move(RedMove(action=RedAction.READ_INVOICE, param="INV-0001"), 1);
    execute_red_move(RedMove(action=RedAction.READ_INVOICE, param="INV-0001"), 2);
    assert len(red_findings()) == 1;
}

test "PROBE never breaches" {
    reset_red();
    r = execute_red_move(RedMove(action=RedAction.PROBE), 1);
    assert not r.breached;
    assert len(red_findings()) == 0;
}

test "red_memory reflects confirmed findings" {
    reset_red();
    assert "unexplored" in red_memory();
    assert set_policy("config", "exposes_secret", True);
    execute_red_move(RedMove(action=RedAction.READ_CONFIG), 1);
    assert "SECRET_EXPOSURE" in red_memory();
}
