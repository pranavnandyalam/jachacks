"""Red -- the attacker agent. It reads the target's SOURCE CODE (a white-box
security auditor) and picks one HTTP request most likely to leak protected data.

Red's identity is constrained to an enum (its own low-privilege account, or
anonymous) so it can never cheat by impersonating admin -- every breach is a
genuine authorization failure in the code. A breach = the runtime flag appears
in the response. Red keeps memory of what it already tried so it moves on to
new areas instead of repeating itself.
"""

import json;

import from jaclang.byllm.lib { Model }
import from sandbox { AttackReq, run_one_attack }
import from config { attacker_user, secret_hint }

glob attacker: Model = Model(model_name="ollama_chat/huihui_ai/qwen3-coder-abliterated");

glob ATTACKER_USER: str = attacker_user();

enum Identity {
    ATTACKER,
    ANON
}
sem Identity = "Who Red sends the request as. It only holds ONE real credential.";
sem Identity.ATTACKER = "Red's own low-privilege user account. Use this to test whether the code lets a normal logged-in user reach data that is not theirs.";
sem Identity.ANON = "No credentials at all. Use this to test whether an endpoint that should require login or admin is reachable unauthenticated.";

obj Attack {
    has method: str,
        path: str,
        identity: Identity,
        body_json: str = "",
        vuln_class: str = "",
        hypothesis: str = "";
}
sem Attack = "A single HTTP request to try against the app this turn.";
sem Attack.method = "HTTP method: GET, POST, etc.";
sem Attack.path = "The exact URL path to request, taken verbatim from a route in the source.";
sem Attack.identity = "Which identity to send as -- ATTACKER (your own account) or ANON.";
sem Attack.body_json = "JSON object as a string for POST/PUT bodies, else empty string.";
sem Attack.vuln_class = "The weakness class you are testing: IDOR, BROKEN_ACCESS, DEBUG_LEAK, SECRET_EXPOSURE, or similar.";
sem Attack.hypothesis = "One sentence: which line(s) of code look wrong and why this request should leak protected data. Target a weakness you have NOT already breached.";

sem plan_attack = "You are Red, a white-box offensive-security agent. You are given the full source of a small web app, a note on the secret you are trying to make it leak, and your memory of what you already tried. Read the code, find a MISSING authorization/ownership check, an endpoint that skips a login or role check, or any other leak, and return the single HTTP request most likely to make the app return that secret to you. Prefer a weakness you have not already breached.";
sem plan_attack.source = "The full current source of the target app.";
sem plan_attack.context = "What you are logged in as and what secret to try to leak. This is all you are told about the target -- it names no specific bug.";
sem plan_attack.memory = "What Red already tried this game and whether each breached.";
def plan_attack(source: str, context: str, memory: str) -> Attack by attacker(temperature=0.4);

node RedAgent {
    has name: str = "red",
        turns: int = 0;
}

node Attempt {
    has method: str,
        path: str,
        identity: str,
        vuln_class: str,
        hypothesis: str,
        breached: bool,
        round_n: int;
}

edge Tried: RedAgent --> Attempt {}

obj AttackResult {
    has method: str,
        path: str,
        identity: str,
        vuln_class: str,
        hypothesis: str,
        breached: bool,
        status: int,
        note: str;
}

def red_agent -> RedAgent {
    found = [root -->[?:RedAgent]];
    if found {
        return found[0];
    }
    return root ++> RedAgent(name="red");
}

def red_attempts -> list[Attempt] {
    return [red_agent() ->:Tried:->[?:Attempt]];
}

def identity_user(idn: Identity) -> str {
    return ATTACKER_USER if idn == Identity.ATTACKER else "";
}

def identity_label(idn: Identity) -> str {
    return "alice" if idn == Identity.ATTACKER else "anon";
}

"""Convert Red's chosen Attack into a sandbox request."""
def attack_to_req(a: Attack) -> AttackReq {
    body: dict[str, any] = {};
    if a.body_json {
        try {
            body = json.loads(a.body_json);
        } except Exception {
            body = {};
        }
    }
    return AttackReq(
        method=a.method, path=a.path,
        as_user=identity_user(a.identity), body=body
    );
}

"""Red's memory: what it tried, and -- importantly -- which endpoints are
already breached-and-now-patched so it stops wasting turns re-attacking them."""
def red_memory -> str {
    ats = red_attempts();
    if not ats {
        return "Nothing tried yet. Read the code and find the first hole.";
    }
    breached_paths = [];
    for a in ats {
        if a.breached and a.path not in breached_paths {
            breached_paths = breached_paths + [a.path];
        }
    }
    lines = [
        f"- {a.method} {a.path} as {a.identity} [{a.vuln_class}]: {'BREACHED (now patched by Blue)' if a.breached else 'no leak'}"
        for a in ats
    ];
    guidance = "";
    if breached_paths {
        guidance = f"\n\nDO NOT attack these already-closed endpoints again: {breached_paths}. Pick a DIFFERENT endpoint/route from the source that you have not yet breached.";
    }
    return "Already tried:\n" + "\n".join(lines) + guidance;
}

def record_attempt(a: Attack, breached: bool, round_n: int) -> Attempt {
    return red_agent() +>:Tried():+> Attempt(
        method=a.method, path=a.path, identity=identity_label(a.identity),
        vuln_class=a.vuln_class, hypothesis=a.hypothesis,
        breached=breached, round_n=round_n
    );
}

"""One autonomous Red turn against `source`: read code + memory -> choose (LLM)
-> fire the request through the sandbox -> record the attempt."""
def run_red_turn(source: str, round_n: int = 0) -> AttackResult {
    ra = red_agent();
    ra.turns += 1;
    attack = plan_attack(source, secret_hint(), red_memory());
    outcome = run_one_attack(source, attack_to_req(attack));
    record_attempt(attack, outcome.breached, round_n);
    note = outcome.error if outcome.error else outcome.body[:160];
    return AttackResult(
        method=attack.method, path=attack.path, identity=identity_label(attack.identity),
        vuln_class=attack.vuln_class, hypothesis=attack.hypothesis,
        breached=outcome.breached, status=outcome.status, note=note
    );
}

def reset_red -> int {
    ats = red_attempts();
    n = len(ats);
    for a in ats {
        del a;
    }
    ra = red_agent();
    ra.turns = 0;
    return n;
}

# ---- deterministic tests (no LLM) --------------------------------------------

def _seed -> str {
    s = open("target/app.py").read();  # tests pin the shipped invoice app
    return s;
}

test "attack_to_req maps ATTACKER to alice and ANON to empty" {
    a1 = Attack(method="GET", path="/x", identity=Identity.ATTACKER);
    a2 = Attack(method="GET", path="/x", identity=Identity.ANON);
    assert attack_to_req(a1).as_user == "alice";
    assert attack_to_req(a2).as_user == "";
}

test "recording attempts builds memory" {
    reset_red();
    assert "Nothing tried" in red_memory();
    a = Attack(method="GET", path="/debug", identity=Identity.ANON, vuln_class="DEBUG_LEAK");
    record_attempt(a, True, 1);
    assert "BREACHED" in red_memory();
    assert len(red_attempts()) == 1;
}

test "a hand-built IDOR request breaches the seed source (no LLM)" {
    a = Attack(method="GET", path="/invoices/INV-0001", identity=Identity.ATTACKER, vuln_class="IDOR");
    outcome = run_one_attack(_seed(), attack_to_req(a));
    assert outcome.breached;
}

test "an anonymous request to a login-required route does not breach" {
    a = Attack(method="GET", path="/invoices", identity=Identity.ANON, vuln_class="X");
    outcome = run_one_attack(_seed(), attack_to_req(a));
    assert not outcome.breached;
}
