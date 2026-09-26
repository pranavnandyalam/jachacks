# PLAN: Red Queen

> Adversarial red/blue AI agents that fight over a mock server on a Jac graph.
> Track: **Agentic AI** (primary) + **Best Jaclang**. JacHacks A2Tech, Sep 26–27.
> Slice status: [x] 0 Spike · [ ] 1 Target+recon · [ ] 2 Red · [ ] 3 Blue+loop · [ ] 4 Dashboard · [ ] 5 Polish

## One-line pitch
Two teams of real LLM agents — Red (attackers) and Blue (defenders) — battle over a mock SaaS target across many rounds. Red exploits real weaknesses over HTTP; Blue patches them; both adapt from memory stored in the graph; the target measurably hardens over time (rounds-to-breach climbs).

## Constraints (from the hacker guide)
- ≥40% of code in Jac — the whole stack is Jac ✓
- Public GitHub repo, demo video, Devpost description explaining Jac usage
- Host on jachammer.ai (coupon `JACHACKS-UMICH`); star `github.com/jaseci-labs/jac`
- **All code written Sat 12:30 PM → Sun 12:00 PM.** Brainstorming/this doc = allowed.

## Core design decision (the de-risker)
**Everything is one Jac app. Weaknesses are policy fields on graph nodes; patches are structured field edits — never generated code.**

- Ledgerly's endpoints are `:pub` Jac walkers that self-enforce policy read from an `Endpoint` node's boolean fields.
- A **weakness** = a field in its insecure state (e.g. `owner_check = False` → real IDOR). Misconfiguration is the #1 real-world vuln class, so this is authentic.
- **Red** attacks by making real `POST /walker/...` calls that only succeed because a field is wrong.
- **Blue** patches by flipping that field on the node — a hot, reliable, structured edit. This removes the biggest risk (an agent reliably writing working patch *code* in 24h) while keeping exploit + defense real.
- Demo honesty: "Blue hardens misconfigurations," not "Blue rewrites code."

## Graph schema (Jac 0.37.23)

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

## Agents (walkers + `by llm`, tool-menu constrained)
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

## Build status (updated 2026-09-26 — read this first when resuming)

| Slice | State | Commit |
|---|---|---|
| 0 Spike | ✅ done, pushed | `5c1c523` |
| 1 Target + recon | ✅ done, 12 tests + 15 HTTP checks | `110c05f`, `6ba84e7` |
| 2 Red agent | ⚠️ code done (19 tests pass); **live LLM run blocked** | `d476f4e` |
| 3 Blue + Referee + loop | not started | — |

Commits after `5c1c523` are **local only**, not pushed yet.

**Files:** `ledgerly.jac` (target: 4 weakness classes — invoice_read/owner_check IDOR, admin_invoices/auth_required BFLA, debug/is_debug_open, config/exposes_secret; `recon()`, `svc_health()`, unserved `set_policy`). `red.jac` (RedAction/RedMove typed `by llm` menu, `choose_red_move`, deterministic `execute_red_move`/`record_finding`/`red_memory`, served `run_red_turn`/`run_red_campaign`/`reset_red`). `main.jac` imports both.

**Blocker:** live `by llm` → `credit balance is too low`. The Anthropic API account behind `JAC_ANTHROPIC_KEY` has no credits. Wiring and auth are confirmed correct. Fix: add credits at console.anthropic.com, or point the model at a funded/free provider.

**Next:** (1) prove Red's autonomy (≥2 of 4 breaches) live, or with MockLLM. Swapping the `llm` glob in a test is unresolved: jac has no `global` keyword. (2) Slice 3.

**Gotchas learned:** the guest-root graph persists in embedded Postgres (`jac db status --entry main.jac`). After a schema change, run `jac db drop <name> -y` and restart, or `ledgerly()` keeps stale state. Serve with `JAC_DB_RO_UNITS=0 jac run --dev --no-client main.jac` (there is no `serve` subcommand). `sem` strings must be single-line. GET `/function/x` returns the signature; POST executes. W1051/W2003 warnings are noise.

## Slices (each: build → `jac check`/`jac test` → jac-reviewer → commit)

| # | Slice | Acceptance check |
|---|---|---|
| 0 | **Spike (gate)** | Scaffold + Ledgerly with ONE endpoint (`invoice_read`, `owner_check=False`) + Flag. Manual call reads Flag (breach); flip `owner_check=True`; same call denied. **Proves the mechanic before anything else.** |
| 1 | **Target + recon** | All 4 endpoints/weakness kinds + accounts + invoices + flag; `recon()` lists endpoints; scripted legit health request returns 200. Each `svc_*` behaves per its policy fields. |
| 2 | **Red agent** | `run_red_turn()` autonomously breaches ≥2 of 4 weaknesses; `Finding` nodes persist; red reads its own memory. **Run `jac-install-safe.sh --dev` again here** (first `by llm` pulls litellm into the venv). |
| 3 | **Blue + Referee + loop** | `run_game(5)` runs; rounds-to-breach increases; `health_ok` stays true; `PatchAttempt` nodes persist. |
| 4 | **Dashboard** | Full-stack Jac client: force graph (nodes glow red on breach / blue on patch), rounds-to-breach chart, per-round strategy feed. Watchable live game in browser. |
| 5 | **Polish + seed** | Tune `sem` prompts; pre-run a strong 15–20 round game and save the log for the video; deploy to jachammer. |

## Schedule & roles (team of 4; build started 14:45 Sat)

| Block | Slice | A (graph/orch) | B (target/red) | C (blue/referee) | D (dashboard/ship) |
|---|---|---|---|---|---|
| Sat 14:45–16:00 | Spike | scaffold, serve up, merge | Ledgerly + Flag | verify breach/patch manually | dashboard shell (client page, polls `get_state`) |
| 16:00–19:00 | 1→2 | graph model, `recon()`, `get_state()` | red agent + `by llm` | referee + health check | force-graph component |
| 19:00–23:00 | 3 | orchestrator `run_game` | red memory tuning | blue agent + patch executor | rounds-to-breach chart + strategy feed |
| 23:00–03:00 | 4 → S6 | WebSocket/state feed | prompt tuning | S6a battle log | S6b ElevenLabs TTS, then S6c |
| 03:00–05:00 | 5 | seed strong 15–20 round run | tune `sem` prompts | fallback moves / hardening | polish visuals |
| Sun 08:00–09:30 | Ship 1 | **backup video, Devpost draft, PARTIAL SUBMIT ≤ 9:30** | | | video script |
| 09:30–11:30 | Ship 2 | `/jac-ship-check`, host on jachammer, star repo | | | final video |
| 11:30–12:00 | Ship 3 | `/jac-submit`, final Devpost + video | | | |

Parallelism rule: one person owns each `.jac` file per block; merge through A. Don't run
several headless `claude -p` sessions at once on one subscription.

**Fallback if behind at 21:00:** freeze scope at Slices 0–3 + minimal dashboard; 2 weakness kinds.

## Execution sequence (at 12:30)
1. `harness/install.sh <event-repo>` → `cd` in.
2. `/jac-kickoff Red Queen — adversarial red/blue agents on a Jac graph`
   (verifies `jac --version` ≥ 0.37.22, warns if `ANTHROPIC_API_KEY` is set, scaffolds `jac create --kind web-app`, runs `jac-install-safe.sh --dev`, has jac-architect write `PLAN.md`).
3. Dev server for checks (note the RO_UNITS flag): `JAC_DB_RO_UNITS=0 jac run --dev < /dev/null` (background).
4. `/jac-slice Spike`, then Slices 1–5 in order.

## Known jac 0.37.23 landmines (re-verified 2026-09-26)
- **`jac install` is broken** on macOS-arm64 (bundled py3.14 `_posixsubprocess` / `_PyBytes_AsString`). Always use `.claude/scripts/jac-install-safe.sh --dev`. Re-run it after adding the first `by llm` (that's when litellm must land in `.jac/venv`).
- **Serve with `JAC_DB_RO_UNITS=0`** — otherwise the first write after server start is replayed and applied twice.
- **App model key is `JAC_ANTHROPIC_KEY`** (jac.toml `api_key = "${JAC_ANTHROPIC_KEY}"`). Never export `ANTHROPIC_API_KEY` — it makes Claude Code bill the API instead of the subscription.
- **Don't run several headless `claude -p` in parallel** — hits the subscription session limit.
- Syntax: no `pass` (use `{}`); `with entry` runs on import (use `with entry:__main__`); `root` is bare (not `root()`); a walker's generic `can x with entry` fires only at the spawn node; `visit` is required to leave root; guard diamond re-visits with a `seen` set; use `jid()` not Python `id()`.

## Stretch goals — "If Time" (only after Slices 0–4 are solid, ~Sat midnight)
Ordered by ROI. Every item is a bolt-on; none blocks the core adversarial loop. Source of truth stays the **graph** — these are derived/optional.

- **S6a — Battle log (`battle_log()`), ~1h.** A `def:pub battle_log() -> str` walks `Game --> Round` and formats a markdown transcript of the whole game (what Red tried, what Blue patched, whether it held). Powers the Devpost writeup + demo transcript for free. Write to disk best-effort in `on_commit(...)` only — always regenerable from the graph, so a hosted read-only FS doesn't matter. **Do not** feed the raw log back to Red/Blue as memory; they query the graph (open weaknesses, last N rounds) instead.
- **S6b — ElevenLabs narration (TTS), ~2h.** Speak each round's `red_why` / `blue_why` in the dashboard ("Round 7: Blue locked the debug endpoint"). Pure text-to-speech, no public endpoint needed. Cheap insurance for the **Best of ElevenLabs** award + big demo flair.
- **S6c — ElevenLabs conversational agent (the best version), ~4–6h.** A Conversational AI agent you talk to: *"what have you patched?"* / *"what's still open?"*. Register **server tools** (webhooks) mapped to `get_state()`, `battle_log()`, `list_open_vulnerabilities()`; system prompt = "SOC analyst for Red Queen, answer via tools"; embed the web widget in the dashboard. This is itself a **tool-using agent**, so it strengthens the Agentic AI story, not just the sponsor award. Needs the **public jachammer URL** (wire it after deploy) + an **ElevenLabs API key** (sponsor credits on Discord — grab early).
- **S6d — Flourishes (only if everything above is done):** WebSocket live push (`@restspec(protocol=APIProtocol.WEBSOCKET, broadcast=True)` on an `async walker:pub`) instead of polling; a third "Director" agent that escalates difficulty each round; multiple target profiles (a bank, a hospital) to show generality.

**Gate:** assign S6 only once Slices 0–4 pass their acceptance checks. On a team of 3, C owns S6 after the dashboard lands. Baseline is S6a + S6b (fast, low-risk); S6c is the reach goal.

## Risks & mitigations
1. **Blue autonomous patching** → structured field edits, not codegen (core design).
2. **Agents don't visibly learn** → feed recent-round summaries into `by llm`; run 15–20 rounds; pre-seed a strong run for the video.
3. **Looks like Inocula (Winter winner)** → lead the demo with the co-evolution curve + adapting tactics, not a SOC dashboard.
4. **`by llm` structured output flakiness** → typed enum returns + a plain-Jac fallback move if parse fails.
5. **Dashboard permissions (judges anonymous)** → run the game on guest root / `grant(... READ)`; start with polling `get_state()`, add WebSocket only if time.

## Submission checklist
Public repo ✓ · ≥40% Jac ✓ · demo video ✓ · Devpost w/ Jac usage ✓ · hosted on jachammer ✓ · starred repo ✓ · tracks: Agentic AI + Best Jaclang.
