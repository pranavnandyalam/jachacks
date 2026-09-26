"""Blue -- the defender agent.

Blue plays one move per turn in response to Red's activity. Like Red, its move is
a typed `by llm` return (`BlueMove`) confined to a fixed menu, so the model can
only pick WHICH known weakness to harden -- never write freeform code. Every patch
is a single structured field edit via `set_policy` (Ledgerly's only lever), which
is why Blue can act autonomously without codegen and can never break the app in a
way the referee's health check won't catch.

Deterministic mechanics (execute_blue_move, record_patch, blue_memory) are split
from the single LLM decision (choose_blue_move) so they are unit-testable without
a model, exactly as in red.jac.
"""

import from jaclang.byllm.lib { Model }
import from ledgerly {
    recon, svc_health, set_policy
}

glob blue_llm: Model = Model(model_name="gemini/gemini-3.5-flash-lite");

enum BlueAction {
    MONITOR,
    PATCH_IDOR,
    PATCH_BFLA,
    PATCH_DEBUG,
    PATCH_CONFIG
}
sem BlueAction = "The fixed menu of hardening actions Blue may apply. MONITOR does nothing this turn; the other four each close exactly one endpoint's weakness by flipping one policy field.";
sem BlueAction.MONITOR = "Take no action this turn -- watch and wait. Use only if every known weakness is already patched.";
sem BlueAction.PATCH_IDOR = "Close the broken object-level authorization on /invoices by turning owner_check ON, so a user can only read invoices they own.";
sem BlueAction.PATCH_BFLA = "Close the broken function-level authorization on /admin/invoices by turning auth_required ON, so only admins can list.";
sem BlueAction.PATCH_DEBUG = "Disable the /debug/dump diagnostics endpoint (is_debug_open OFF) so it stops leaking internal state in production.";
sem BlueAction.PATCH_CONFIG = "Stop /config from serializing the backup secret (exposes_secret OFF).";

obj BlueMove {
    has action: BlueAction,
        rationale: str = "";
}
sem BlueMove = "A single defensive move to apply this turn.";
sem BlueMove.action = "Which hardening action from the menu to apply this turn.";
sem BlueMove.rationale = "One sentence: why this patch now, given the latest attack and what you have already hardened. Prioritize closing a weakness Red just breached that is still open.";

sem choose_blue_move = "You are Blue, a defensive security agent protecting the Ledgerly SaaS. Each turn you see the endpoint surface, a live alert about Red's latest attack, and a memory of what you have already hardened. Choose the single patch most likely to close a currently-open hole -- ideally the one Red just breached. Never re-patch something already in your memory; if all known holes are closed, MONITOR.";
sem choose_blue_move.surface = "Ledgerly's exposed endpoints.";
sem choose_blue_move.alert = "What Red attempted on the most recent turn and whether it breached.";
sem choose_blue_move.memory = "The weaknesses Blue has already hardened this game.";
def choose_blue_move(surface: str, alert: str, memory: str) -> BlueMove by blue_llm(temperature=0.2);

node BlueAgent {
    has name: str = "blue",
        turns: int = 0;
}

node PatchAttempt {
    has weakness: str,
        endpoint_path: str,
        field: str,
        value_set: bool,
        success: bool,
        health_ok: bool,
        turn: int = 0;
}

edge Applied: BlueAgent --> PatchAttempt {}

obj BlueResult {
    has action: str,
        patched: bool,
        health_ok: bool,
        weakness: str = "",
        endpoint_path: str = "",
        field: str = "",
        rationale: str = "",
        note: str = "";
}

def blue_agent -> BlueAgent {
    found = [root -->[?:BlueAgent]];
    if found {
        return found[0];
    }
    return root ++> BlueAgent(name="blue");
}

def blue_patches -> list[PatchAttempt] {
    return [blue_agent() ->:Applied:->[?:PatchAttempt, success == True]];
}

"""Blue's memory: the distinct weaknesses it has already hardened."""
def blue_memory -> str {
    ps = blue_patches();
    if not ps {
        return "Nothing hardened yet. Every endpoint is still at its insecure default.";
    }
    lines = [f"- {p.weakness} closed via {p.endpoint_path} ({p.field})" for p in ps];
    return "Hardened so far:\n" + "\n".join(lines);
}

def blue_label(a: BlueAction) -> str {
    if a == BlueAction.PATCH_IDOR { return "PATCH_IDOR"; }
    if a == BlueAction.PATCH_BFLA { return "PATCH_BFLA"; }
    if a == BlueAction.PATCH_DEBUG { return "PATCH_DEBUG"; }
    if a == BlueAction.PATCH_CONFIG { return "PATCH_CONFIG"; }
    return "MONITOR";
}

"""Record a successful patch once, deduped by weakness so repeated patches of the
same hole don't pile up duplicate PatchAttempts."""
def record_patch(
    wk: str, endpoint_path: str, field: str, value_set: bool,
    success: bool, health_ok: bool, turn: int
) -> PatchAttempt {
    existing = [blue_agent() ->:Applied:->[?:PatchAttempt, weakness == wk]];
    for e in existing {
        if e.success {
            return e;
        }
    }
    return blue_agent() +>:Applied():+> PatchAttempt(
        weakness=wk, endpoint_path=endpoint_path, field=field,
        value_set=value_set, success=success, health_ok=health_ok, turn=turn
    );
}

"""Apply a chosen BlueMove to Ledgerly (deterministic). Flips one policy field,
then confirms the health invariant (alice can still read her own invoice) still
holds -- Blue must never harden in a way that takes the app down."""
def execute_blue_move(move: BlueMove, turn: int = 0) -> BlueResult {
    a = move.action;
    label = blue_label(a);

    if a == BlueAction.MONITOR {
        h = svc_health();
        return BlueResult(
            action=label, patched=False, health_ok=h.ok,
            rationale=move.rationale, note="monitoring; no patch applied"
        );
    }

    ep_kind = "";
    field = "";
    weakness = "";
    path = "";
    value = True;
    if a == BlueAction.PATCH_IDOR {
        ep_kind = "invoice_read"; field = "owner_check"; weakness = "IDOR";
        path = "/invoices"; value = True;
    } elif a == BlueAction.PATCH_BFLA {
        ep_kind = "admin_invoices"; field = "auth_required"; weakness = "BFLA";
        path = "/admin/invoices"; value = True;
    } elif a == BlueAction.PATCH_DEBUG {
        ep_kind = "debug"; field = "is_debug_open"; weakness = "DEBUG_OPEN";
        path = "/debug/dump"; value = False;
    } elif a == BlueAction.PATCH_CONFIG {
        ep_kind = "config"; field = "exposes_secret"; weakness = "SECRET_EXPOSURE";
        path = "/config"; value = False;
    }

    ok = set_policy(ep_kind, field, value);
    h = svc_health();
    record_patch(weakness, path, field, value, ok, h.ok, turn);
    return BlueResult(
        action=label, weakness=weakness, endpoint_path=path, field=field,
        patched=ok, health_ok=h.ok, rationale=move.rationale,
        note=f"set {field}={value} on {ep_kind}"
    );
}

"""One autonomous Blue turn: recon -> read memory -> choose (LLM) -> execute."""
def:pub run_blue_turn(alert: str = "No alert.") -> BlueResult {
    ba = blue_agent();
    ba.turns += 1;
    eps = recon();
    surface = "Endpoints:\n" + "\n".join([f"- {e.kind} at {e.path}" for e in eps]);
    move = choose_blue_move(surface, alert, blue_memory());
    return execute_blue_move(move, ba.turns);
}

"""Reset Blue's memory (delete all PatchAttempts) -- for a clean game start."""
def:pub reset_blue -> int {
    ba = blue_agent();
    ps = [ba ->:Applied:->[?:PatchAttempt]];
    n = len(ps);
    for p in ps {
        del p;
    }
    ba.turns = 0;
    return n;
}

# ---- deterministic tests (no LLM) --------------------------------------------

test "execute PATCH_IDOR turns owner_check on and keeps health 200" {
    reset_blue();
    assert set_policy("invoice_read", "owner_check", False);
    r = execute_blue_move(BlueMove(action=BlueAction.PATCH_IDOR), 1);
    assert r.patched;
    assert r.weakness == "IDOR";
    assert r.health_ok;
    assert len(blue_patches()) == 1;
}

test "execute PATCH_BFLA gates the admin listing" {
    reset_blue();
    assert set_policy("admin_invoices", "auth_required", False);
    r = execute_blue_move(BlueMove(action=BlueAction.PATCH_BFLA), 1);
    assert r.patched and r.weakness == "BFLA";
    assert r.health_ok;
}

test "execute PATCH_DEBUG and PATCH_CONFIG close their holes" {
    reset_blue();
    assert set_policy("debug", "is_debug_open", True);
    assert set_policy("config", "exposes_secret", True);
    d = execute_blue_move(BlueMove(action=BlueAction.PATCH_DEBUG), 1);
    c = execute_blue_move(BlueMove(action=BlueAction.PATCH_CONFIG), 2);
    assert d.patched and d.weakness == "DEBUG_OPEN";
    assert c.patched and c.weakness == "SECRET_EXPOSURE";
    assert len(blue_patches()) == 2;
}

test "patches are deduped by weakness across turns" {
    reset_blue();
    execute_blue_move(BlueMove(action=BlueAction.PATCH_IDOR), 1);
    execute_blue_move(BlueMove(action=BlueAction.PATCH_IDOR), 2);
    assert len(blue_patches()) == 1;
}

test "MONITOR applies no patch" {
    reset_blue();
    r = execute_blue_move(BlueMove(action=BlueAction.MONITOR), 1);
    assert not r.patched;
    assert len(blue_patches()) == 0;
}

test "blue_memory reflects hardened weaknesses" {
    reset_blue();
    assert "insecure default" in blue_memory();
    execute_blue_move(BlueMove(action=BlueAction.PATCH_CONFIG), 1);
    assert "SECRET_EXPOSURE" in blue_memory();
}
