---
name: jac-hackathon
description: Compiler-verified Jac rules, the stale-vs-current contradictions in the Jac docs, and JacHacks judging-aligned patterns (agents as walkers, meaning-typed AI, per-user graphs). Load before designing or writing any Jac code for the hackathon, and when a Jac doc/guide seems to contradict itself.
---

# Jac for JacHacks (jac 0.37.23)

The full study guide (every major doc page condensed) is in
`reference/JAC_STUDY_GUIDE.md` next to this file - read its §0 (top rules) and
§14 (doc contradictions) when unsure. The version-matched official guides are the
`jac-*` skills (`jac guide <name>`).

## Verified against the real compiler (0.37.23)

| Claim | Result |
|---|---|
| `edge E {}` without endpoints | **E2086** error - write `edge E: Src --> Tgt {}` (or `any --> any`) |
| Which declarations are served | only `:pub` and `:protect`; plain and `:priv` are NOT served |
| `result.reports.length` in client | **E1030** - use `len(result.reports)` |
| `jacSignup(...)` result | object with `.success` (`s["success"]` fails to type) ; signup doesn't log in |
| `def f() -> int` | W3005 "empty parentheses" - write `def f -> int` |
| `return false;` | W2001 + E1002 - booleans are `True`/`False` |
| `jac check` exit code | 1 on errors, 0 with only warnings |
| Stock `web-app` scaffold | emits false-positive W2001 (HTML tags) and W2003 (`setX`) - ignore |
| Scaffold comment "switch to `:priv` to require auth" | stale - use `:protect` |
| First write after server start (e.g. `m.strength += 0.15`) | applied **twice** (read-tier replay keeps the aborted attempt's in-memory change) - serve with `JAC_DB_RO_UNITS=0` |
| Client file importing an endpoint AND the same types from the schema module | builds fine with `jac build --as client` (re-tested with nodes nested in objs). A dev-server "duplicate symbol" error was reported once in the dry run; only if you see it, alias the type imports (`ChatTurn as ChatTurnT`) |

## Patterns that score on "leverages what makes Jac unique"

**Agents as walkers, memory as a graph.**

```jac
node Agent { has role: str; }
node Memory { has text: str, at: str = ""; }
edge Remembers: Agent --> Memory { has salience: float = 0.5; }
edge HandsOff: Agent --> Agent {}

obj Decision { has action: str, rationale: str, next_role: str | None = None; }
sem Decision.next_role = "Role of the agent to hand off to, or None when done";

def decide(role: str, task: str, memories: list[str]) -> Decision by llm();
sem decide = "Decide the next action for an agent with this role on the task.";

walker Orchestrate {
    has task: str,
        trace: list[Decision] = [],
        reports: list[list[Decision]] = [];

    can start with Root entry { visit [-->[?:Agent, role == "planner"]]; }

    can act with Agent entry {
        mem = [m.text for m in [here ->:Remembers:-salience:-> [?:Memory]][:5]];
        d = decide(here.role, self.task, mem);
        self.trace.append(d);
        here +>:Remembers(salience=0.8):+> Memory(text=d.rationale);
        if d.next_role {
            visit [here ->:HandsOff:-> [?:Agent, role == d.next_role]];
        }
    }

    can done with Root exit { report self.trace; }
}

# Verified: `jac check` clean + this test passes on jac 0.37.23 with
# `glob llm = MockLLM(outputs=[Decision(action="plan", rationale="split task", next_role="coder"),
#                              Decision(action="code", rationale="wrote it", next_role=None)]);`
test "planner hands off to coder" {
    p = root ++> Agent(role="planner");
    p +>:HandsOff():+> Agent(role="coder");
    res = root spawn Orchestrate(task="build app");
    assert [d.action for d in res.reports[0]] == ["plan", "code"];
    assert len([p ->:Remembers:->]) == 1;
}
```

Gotchas this example surfaced:
- MockLLM still needs `[byllm]` in jac.toml + installed deps (litellm) -> `.claude/scripts/jac-install-safe.sh`.
- The same walker run from `with entry` visited 3 "planners" because each earlier run
  persisted another planner on `root`. Build demo graphs in `test` blocks (isolated) or
  get-or-create them.

Other high-leverage moves:
- `visit [-->] by llm(intent="most relevant next step", select=1);` - LLM-guided traversal.
- `def agent(q: str) -> str by llm(tools=[tool_a, tool_b]);` + `sem` on each tool - ReAct.
- Typed outputs (`enum`/`obj`) instead of free text - the type is the output schema.
- `:protect` endpoints -> per-user isolated graphs with zero auth code; `root.shared` + `grant()` for public/shared data.
- Show the live graph at `/graph` in the demo.

## Model config

```toml
[byllm.model]
default_model = "anthropic/claude-sonnet-4-6"   # jac 0.37.23 also supports Claude Opus 5.5 / Fable 5.1 via litellm
api_key = "${JAC_ANTHROPIC_KEY}"                # NOT ANTHROPIC_API_KEY: that makes Claude Code bill the API
```

Free fallback: `gemini/gemini-2.5-flash` with `GEMINI_API_KEY`.
Run `jac install` after adding `[byllm]`. Tests use `MockLLM(outputs=[...])`.
