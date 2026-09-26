# PLAN: Red Queen

> AI attackers find real vulnerabilities in an app's code, AI defenders patch that code, and a referee verifies every patch. The app's security evolves round by round.
> Track: **Agentic AI** (primary) + **Best Jaclang**. JacHacks A2Tech, Sep 26–27.
> Status (Sat ~19:00): **v2 ENGINE DONE + consistency-tested** (tag `v2-engine-stable`). Red finds real vulns in `target/app.py`, Blue rewrites the real code (local ollama model), referee verifies every patch, security evolves v0→v1→v2→v3. 5/5 live matches find + patch all 3 holes, health held, ~55s each, offline (no API/quota). **NEXT: dashboard (T6), seed a demo match, jachammer deploy (T8, subprocess-under-hosting = biggest risk).** v1 settings-flip version preserved at tag `v1-fallback`.

## Check-in: where we are (Sat 17:30)

**Works (v1, verified live 17:05 with gemini-3.5-flash-lite)**
- Ledgerly target: 4 real holes (IDOR, BFLA, open debug, leaked secret), each leaking the flag over HTTP.
- Red (`by llm`) picks attacks, keeps memory, writes rationales. Blue (`by llm`) patches the hole Red just hit.
- Referee: health invariant held every round. `run_game` / `get_game_state` / replay saved in the graph.
- 29 deterministic tests pass. A live 5-round match gave 4/4 breaches, 4/4 patched, and all 4 holes verified closed over HTTP afterwards.

**Doesn't work / gaps**
- Blue doesn't fix code. It flips pre-written on/off switches, so security doesn't *evolve*. It reaches a final state we wrote in advance.
- The game is over at round 5, and every run plays out in the same order, so it looks scripted.
- `run_game` blocks for about 48s in one HTTP call, so the dashboard can't show rounds live.
- No LLM-failure fallback. No dashboard (`frontend.jac` is still the template guestbook). Not deployed. **7 commits not pushed.**

**Decision:** pivot to v2. Red finds holes in real source code and Blue rewrites the code. The referee keeps a patch only if it verifiably works. v1 stays as the fallback.

## v2: what we're building

```
        ┌──────────── each round ────────────┐
source ─▶ RED reads code + memory ─▶ attack ─▶ sandbox ─▶ breach? (flag in response)
                                                        │ yes
                              BLUE rewrites the code ◀──┘
                                        │
         REFEREE: exploit now fails? + all old exploits fail? + normal use still works?
                 ├─ yes → keep patch (new CodeVersion)       └─ no → revert, Blue gets 1 retry
```
Security evolves because every accepted patch is new code that nobody pre-wrote. The whole history (attacks, diffs, verdicts) lives in the Jac graph.

### Components

**1. Target app (Python, swappable), `target/`**
- `app.py`: a small Flask invoice app, about 120 lines, in-memory data, with 3 planted bugs:
  - IDOR on `GET /invoices/<id>`
  - missing admin check on `GET /admin/invoices`
  - a debug route that dumps config, including the secret
- Auth is `Authorization: Bearer <token>`, with seeded tokens for alice, bob and admin. Red only holds alice's token.
- **The flag is injected at runtime** (env `RQ_FLAG`, written onto the admin invoice and the app secret) and never appears in the source. Otherwise Red could "breach" just by reading the code.
- `manifest.json` holds the entry file, flag env var, attacker token and the list of health checks (`method, path, token, expect_status, expect_contains`). **The engine only reads the manifest**, so the vibecoded app can be swapped in later without touching Jac.

**2. Sandbox runner, `sandbox/runner.py` (Python, about 80 lines)**
- `runner.py <source_file> attack <request.json>` or `runner.py <source_file> health`.
- It loads the source fresh, seeds the flag, sends requests through Flask's `test_client()`, and prints JSON.
- Run as a subprocess with `.jac/venv/bin/python` and a 10s timeout, so broken or malicious AI code can't hang or crash the server.

**3. Jac engine (the product; all logic is Jac)**
- `codebase.jac`: `CodeVersion` node `{version, source, author (seed|blue), diff, accepted}`, plus `current_source()` and revert.
- `sandbox.jac`: bridge to the runner, `run_attack(src, req) -> HttpResult` and `run_health(src) -> HealthReport`.
- `attacker.jac` (Red v2): `plan_attack(source, memory) -> Attack by llm`.
  - `Attack {method: GET|POST, path, use_token: ATTACKER|NONE, body, vuln_class, hypothesis}`.
  - Breach = the flag appears in the response. Every attempt, breached or blocked, is saved as an `Exploit` node, so Red adapts to what failed and the referee can re-run old exploits.
- `defender.jac` (Blue v2): `write_patch(source, exploit, feedback) -> Patch by llm`, with `Patch {new_source, summary}`.
  - Blue returns the full patched file (the file is small, so this is simpler and more reliable than diffs).
  - Model: `gemini-3.5-flash` (flash-lite is too weak for code).
- `referee.jac`: `verify(new_source, exploit)` accepts only if (a) this exploit now fails, (b) every previously accepted exploit still fails, and (c) every health check passes. Otherwise it reverts and gives Blue one retry, passing along the failure reason.
- `arena.jac`: `start_game()`, **`step_round()`** (one round per HTTP call, which the dashboard polls), `get_game_state()`, and `run_game(n)` for convenience. The game ends when Red fails 3 rounds in a row, or at max rounds.
- Every LLM call has a deterministic fallback (Red: replay a known probe; Blue: count the patch as rejected), so one bad model response can't kill a game.

**4. Dashboard, `frontend.jac`**
- Start and Step buttons, with Auto mode.
- Round feed: Red's attack plus hypothesis, BREACH or blocked, Blue's patch summary, and the referee's verdict.
- Code-diff panel per accepted patch.
- Chart of open holes over the rounds.

**State contract, fixed now so the dashboard can start against mock data:**
```
GameState { rounds_played, open_holes, patched, health_ok, finished,
  rounds: [ { n, red: {method, path, hypothesis, vuln_class, breached},
              blue: {summary, accepted, retried} | null,
              referee: {exploit_blocked, regressions_ok, health_ok},
              diff } ] }
```

### Tasks (build → `jac check`/`jac test` → review → commit)

| # | Task | Owner | Est | Acceptance check |
|---|---|---|---|---|
| T0 | Push 7 commits and tag `v1-fallback`. Add `flask` to jac.toml and run `jac-install-safe.sh --dev`. | A | 15m | `.jac/venv/bin/python -c "import flask"` works; tag visible on GitHub |
| T1 | Target app + manifest + runner | B | 45m | Health passes on the original source; 3 hand-written exploits leak the flag; a hand-fixed copy blocks all 3 and still passes health |
| T2 | `sandbox.jac` + `codebase.jac` | A | 45m | jac tests call the runner via subprocess; CodeVersion persists; revert works |
| T3 | `referee.jac` + `defender.jac` (**riskiest, do first after plumbing**) | C | 1.5h | Given each known exploit, a live Blue patch is accepted for ≥2 of 3 bugs; a deliberately broken patch fixture is rejected |
| T4 | `attacker.jac` | C | 1h | Live Red finds ≥2 of 3 bugs from source alone within 6 attempts |
| T5 | `arena.jac` + serve in `main.jac` | A | 1h | 8-round live game over HTTP: all 3 holes found and patched, health holds, diffs saved, `step_round` < 30s each |
| T6 | Dashboard | D | parallel | Works on mock GameState by 21:00, live by 23:00 |
| T7 | **Vibecoded target swap** (cuttable) | B | 1h | Generate an app from a lazy prompt (save the prompt), write its manifest, and a full game runs on it |
| T8 | Deploy to jachammer (**test subprocess + venv work when hosted**), tune prompts, seed a strong run | A/C | overnight | Hosted URL runs a round, or the local + video fallback is decided |

### Timeline
| Time | What |
|---|---|
| 17:30–18:15 | T0 (A) · T1 (B) · C reads the Jac `by llm` patterns + drafts Red/Blue `sem`s · D starts T6 on mock state |
| 18:15–19:00 | T2 (A) · T1 finish (B) |
| 19:00–20:30 | **T3** (C, pairs with B) · A starts T5 skeleton |
| 20:30–21:30 | T4 (C) · T5 (A) |
| **22:00** | **CHECKPOINT.** If T3 isn't passing (Blue patches unreliable), ship v1 + dashboard; v2 becomes a "preview" demo |
| 22:00–23:00 | Wire the dashboard live · end-to-end runs |
| 23:00–00:00 | T7 vibecoded swap (cuttable) |
| 00:00–02:00 | T8 deploy test + prompt tuning |
| 02:00–05:00 | Seeded strong run saved · polish · sleep in shifts |
| Sun 08:00–09:30 | Backup video, Devpost draft, **partial submit ≤ 9:30** |
| 09:30–12:00 | Ship check, final video, **final submit by 12:00** |

### Cut list if behind (cut in this order)
1. T7 vibecoded swap: keep the pitch line, run on the hand-written target.
2. Blue's retry.
3. The open-holes chart (keep the feed and diffs).
4. Auto mode (keep the Step button).
5. All stretch goals (ElevenLabs, battle log) are out unless we're ahead at 02:00.

### Risks
| Risk | Mitigation |
|---|---|
| Blue's code patches are unreliable | Small file, full-file rewrite, stronger model, referee plus 1 retry. The 22:00 checkpoint triggers the v1 fallback |
| Red "breaches" by reading the flag out of the source | Flag injected at runtime only |
| Executing AI-written code | Subprocess, 10s timeout, local target, no secrets in its env beyond the flag |
| jachammer hosting blocks subprocess or the venv | Test at T8 (not at the end). Fallback: in-process exec + thread timeout, or demo locally + video |
| LLM hang (seen before with a retired model) | Pinned model names; subprocess timeouts; per-call fallback |
| Demo nondeterminism | A seeded strong run saved and replayable from the graph |
| ≥40% Jac rule | Python limited to the target (~120 lines) + runner (~80); the engine, agents, referee and dashboard are all Jac |

### Pitch
"AI writes insecure code fast. Red Queen fixes it just as fast. Attacker agents find real holes in the source, defender agents rewrite the code, and a referee only keeps patches that provably work. You can watch the app's security evolve."

## Constraints (from the hacker guide)
- ≥40% of code in Jac. Public GitHub repo, demo video, Devpost description explaining Jac usage.
- Host on jachammer.ai (coupon `JACHACKS-UMICH`); star `github.com/jaseci-labs/jac`.
- **All code written Sat 12:30 PM → Sun 12:00 PM.**

## Known jac 0.37.23 landmines (re-verified 2026-09-26)
- **`jac install` is broken** on macOS-arm64. Always use `.claude/scripts/jac-install-safe.sh --dev`.
- **Serve with `JAC_DB_RO_UNITS=0 jac run --dev --no-client main.jac`**, otherwise the first write after server start is applied twice. POST `/function/<name>` executes a served def.
- **Kill stale `jac run` processes before starting a new one.** Two processes on the same embedded Postgres deadlock silently.
- After a graph-schema change, run `jac db drop <name> -y` and restart, or get-or-create returns stale nodes.
- The byllm key is `GEMINI_API_KEY` (models `gemini/gemini-3.5-flash-lite` and `gemini/gemini-3.5-flash`). A retired model name makes byllm **hang silently**, so check with curl.
- `sem` strings must be single-line. No compound `and` inside filter comprehensions. obj fields without defaults must come before defaulted ones. Never name a filter parameter the same as the node attribute it's compared to (it silently self-compares). W1051/W2003 warnings are noise.
- `sys.executable` inside jac is the jac binary (it accepts `-c`). Run the target via `.jac/venv/bin/python`, which is where flask goes.
- Don't run several headless `claude -p` sessions in parallel (subscription limit).

---

# Appendix: v1 design (as built, tag `v1-fallback`)

### One-line pitch
Two teams of real LLM agents — Red (attackers) and Blue (defenders) — battle over a mock SaaS target across many rounds. Red exploits real weaknesses over HTTP; Blue patches them; both adapt from memory stored in the graph; the target measurably hardens over time (rounds-to-breach climbs).

### Constraints (from the hacker guide)
- ≥40% of code in Jac — the whole stack is Jac ✓
- Public GitHub repo, demo video, Devpost description explaining Jac usage
- Host on jachammer.ai (coupon `JACHACKS-UMICH`); star `github.com/jaseci-labs/jac`
- **All code written Sat 12:30 PM → Sun 12:00 PM.** Brainstorming/this doc = allowed.

### Core design decision (the de-risker)
**Everything is one Jac app. Weaknesses are policy fields on graph nodes; patches are structured field edits — never generated code.**

- Ledgerly's endpoints are `:pub` Jac walkers that self-enforce policy read from an `Endpoint` node's boolean fields.
- A **weakness** = a field in its insecure state (e.g. `owner_check = False` → real IDOR). Misconfiguration is the #1 real-world vuln class, so this is authentic.
- **Red** attacks by making real `POST /walker/...` calls that only succeed because a field is wrong.
- **Blue** patches by flipping that field on the node — a hot, reliable, structured edit. This removes the biggest risk (an agent reliably writing working patch *code* in 24h) while keeping exploit + defense real.
- Demo honesty: "Blue hardens misconfigurations," not "Blue rewrites code."

### Graph schema (Jac 0.37.23)

Target subgraph — Ledgerly:
```jac
node Service { has name: str; }
node Endpoint {
    has path: str;
    has kind: str;                 # invoice_read | login | debug | config_read
    has auth_required: bool = False;
    has owner_check:   bool = False;   # weakness when False on invoice_read
    has is_debug_open: bool = False;   # weakness when True
    has exposes_secret:bool = False;   # weakness when True on config_read
}
node Account { has username: str; has password: str; has role: str; }
node Invoice { has inv_id: str; has owner: str; has amount: float; has secret: bool = False; }
node Flag    { has value: str; }       # Red's goal: read this
```
Edges (endpoints required — a bare `edge {}` is E2086):
`Service -Exposes-> Endpoint`, `Endpoint -Guards-> Invoice`, `Invoice -Holds-> Flag` (the flag lives on the admin invoice `INV-0001`).

**As built (Spike, `ledgerly.jac`):** Ledgerly endpoints are `def:pub svc_*` functions (`POST /function/svc_*`) returning `AccessResult`; the target is get-or-created by `ledgerly()`. Blue's lever `set_policy(kind, field, value)` is a plain `def` — verified NOT served (405) — so only the in-process game can patch.

Battle / memory subgraph:
```jac
node Game  { has started_at: str; }
node Round { has n: int; has breached: bool = False; has health_ok: bool = True;
             has red_move: str = ""; has red_why: str = "";
             has blue_move: str = ""; has blue_why: str = ""; }
node Finding      { has kind: str; has endpoint_path: str; has evidence: str; has round_n: int; }
node PatchAttempt { has kind: str; has field: str; has new_val: bool; has round_n: int; has held: bool = False; }
```
Edges: `Game --has_round--> Round`, `Round --discovered--> Finding`, `Round --applied--> PatchAttempt`, `Finding --targets--> Endpoint`, `PatchAttempt --hardens--> Endpoint`.

The battle graph runs on the **guest root** (all `:pub`) so judges viewing via jachammer without logging in see live state. Use `grant(game, level=AccessLevel.READ)` if a node needs opening.

### Agents (walkers + `by llm`, tool-menu constrained)
`by llm()` replaces the function body; the move is a **typed return**, which enforces the tool menu (no freeform actions). Describe fields with `sem`, not docstrings.
```jac
enum RedAction { PROBE, LOGIN, READ_INVOICE, HIT_DEBUG, READ_CONFIG }
obj RedMove { has action: RedAction; has target_path: str; has param: str = ""; has rationale: str; }
sem RedMove.rationale = "one sentence: why this move given what failed in earlier rounds";
def choose_red_move(recon: str, memory: str) -> RedMove by llm();

enum BlueField { AUTH_REQUIRED, OWNER_CHECK, DEBUG_OPEN, EXPOSES_SECRET }
obj BlueMove { has endpoint_path: str; has field: BlueField; has new_val: bool; has rationale: str; }
def choose_blue_move(observed: str, memory: str) -> BlueMove by llm();
```
- **RedExecutor** (walker): runs the chosen move as a real call to Ledgerly's `:pub` endpoints; if it reads the Flag or another user's invoice, records a `Finding`.
- **BlueExecutor** (walker): applies `endpoint.<field> = new_val`; records a `PatchAttempt`.
- **Referee** (plain Jac, no LLM — fair & repeatable): breach = Red read Flag; `health_ok` = a scripted legit request still returns 200 (Blue can't "win" by breaking the app).
- **Orchestrator** `def:pub run_game(rounds: int)`: per round → recon → red move → execute → referee → blue move → execute → health check → append `Round`. Memory = each team reads its own past `Finding`/`PatchAttempt` subgraph and passes a summary into `by llm`.
- **Model:** Haiku for per-move calls (cost/latency); `api_key = "${JAC_ANTHROPIC_KEY}"` in jac.toml.

