# JacHacks 2026 project

## Event facts (JacHacks A2Tech — update from the opening ceremony)

- JacHacks A2Tech, UMich Leinweber, Ann Arbor. Sep 26–27, 2026. Hacking 12:30 PM Sat.
  **Partial Devpost checkpoint 9:30 AM Sun. Final submission 12:00 PM ET Sun. No late submissions.**
- **Rule:** all code must be written during the hackathon. No pre-existing projects or
  boilerplate repos. (`.claude/` and this file are dev tooling, not project code.)
- ≥40% of code in Jac. Public GitHub repo, demo video, Devpost explaining Jac usage.
  Host on jachammer.ai (coupon `JACHACKS-UMICH`). Star `github.com/jaseci-labs/jac`. Max 4 per team.
- Tracks: Agentic AI, Developer Tools, Local Impact (Ann Arbor/Washtenaw).
- Jac awards: Best JacHammer, Best Jaclang, Best Mobile. Sponsor awards: Google, IBM,
  ElevenLabs, Backboard.io.
- **Our project: Red Queen** (see `PLAN.md`) — Agentic AI + Best Jaclang (+ ElevenLabs stretch).
- Team: 4 people.

## Hackathon mode (overrides global workflow rules)

Speed and a demo-able product beat coverage. Skip the 80% coverage/TDD mandate. Write
tests only for core walkers and `by llm()` functions, using MockLLM. Still plan before
building (`PLAN.md`), commit small and often with conventional messages, and never commit
secrets.

## Workflow

| Step | Tool |
|---|---|
| Kickoff | `/jac-kickoff [idea]` (idea, then the `jac-architect` subagent writes `PLAN.md`) |
| Build | `/jac-slice <name>` per vertical slice (`jac-builder`, then verify, then `jac-reviewer`, then commit) |
| Broken | `jac-debugger` subagent |
| Pre-demo | `/jac-ship-check` |
| Final hours | `/jac-submit` (`jac-demo-producer`) |

- A hook runs `jac check` after every `.jac` edit, and errors come back automatically.
  Fix them first.
- The `jac` MCP server is available: `validate_jac`, `explain_error`, `search_docs`,
  `run_jac`, `graph_visualize`.
- Its resource `jac://guide/pitfalls` is partly stale (it says `:priv` means auth). Trust
  the rules below.

## Jac reference: consult before writing Jac

- `jac guide jac-essentials`, then the task guide: `jac-walker-patterns`,
  `jac-node-edge-patterns`, `jac-by-llm`, `jac-sv-endpoints`, `jac-sv-auth`,
  `jac-sv-multi-user`, `jac-cl-components`, `jac-cl-routing`, `jac-cl-auth`,
  `jac-fullstack-patterns`, `jac-types`, `jac-testing`, `jac-debugging`.
- These are also exported as skills in `.claude/skills/`.
- The `jac-hackathon` skill has the condensed, compiler-verified rules plus the full
  study guide.

## Rules verified against jac 0.37.23

1. **Endpoint exposure:**

   | Tag | Behavior |
   |---|---|
   | `:pub` | anonymous; anonymous callers share `root.shared` |
   | `:protect` | login required; runs on the caller's own `root` |
   | plain / `:priv` | **not served** (the scaffold's comment saying otherwise is stale) |

2. `edge E: Src --> Tgt {}`: endpoints are required (E2086).
3. `import from x { y }` has no `;`, but `import x;` does. `True`/`False`. No `pass`.
   `for (i, x) in enumerate(xs)`. `match` arms use indentation.
4. No-arg defs are written `def f -> int { }`, because empty `()` warns (W3005).
   Don't write `-> None` (W3037).
5. On the client, use `len(result.reports)`, not `.length` (E1030). `jacSignup(u, p)`
   returns `.success` and does NOT log in, so `await jacLogin(u, p)` next.
6. Client state is `has`. Rebuild lists instead of mutating them (`xs = xs + [x]`).
   `await` every server call.
7. `by llm()` replaces the function body. Use `sem`, not docstrings. Return `obj`/`enum`.
   There's no inline `"..." by llm`.
8. Graph data is stored in embedded Postgres. `jac clean` does not reset it.
   **Never `jac db drop` without asking.**
9. `jac check` has a false positive on pristine scaffolds: W2001 on HTML tags and W2003
   on `setX`. Ignore those two.
10. **Install deps with `.claude/scripts/jac-install-safe.sh [--dev] [pkg...]`, not bare
    `jac install`.**
    - The jac 0.37.23 macOS-arm64 binary can't build `.jac/venv`
      (`_posixsubprocess ... _PyBytes_AsString`). The script falls back to a system
      CPython 3.14 venv plus jac's resolved plan.
    - `by llm()` (even MockLLM) needs `[byllm]` in `jac.toml` and installed deps
      (litellm).
11. The graph persists across `jac run`s. `with entry` code that does
    `root ++> X(...)` duplicates nodes on every run. Put demos and tests in `test`
    blocks, which are isolated, or use get-or-create
    (`visit [-->[?:X, k == v]] else { ... }`).
12. **API keys:** the app's model key lives in `JAC_ANTHROPIC_KEY`, never
    `ANTHROPIC_API_KEY`. If `ANTHROPIC_API_KEY` is set, Claude Code bills the API
    instead of the team's subscription. Put the key in `jac.toml` via interpolation,
    never as a literal (the repo is public):

    ```toml
    [byllm.model]
    default_model = "anthropic/claude-sonnet-4-6"
    api_key = "${JAC_ANTHROPIC_KEY}"
    ```

13. **Always serve with `JAC_DB_RO_UNITS=0`**, for example
    `JAC_DB_RO_UNITS=0 jac run --dev`. This works around a jac 0.37.23 runtime bug,
    reproduced in the dry run:
    - The first time a unit of work writes after a server start, the runtime re-runs
      it from its read-only tier.
    - An in-memory update from the aborted attempt survives the re-run, so
      `x.count += 1` is applied twice.
    - A recall "strength" boost went 1.0 → 1.30 instead of 1.15 on the first request
      after every restart. With the flag set it was a correct 1.15 every time.

14. **Demo / long runs: serve with `--no-dev`** — `JAC_DB_RO_UNITS=0 jac run --no-dev main.jac`
    (UI + API on :8000, prebuilt bundle, no file watcher). Plain `jac run main.jac`
    defaults to dev mode, and the dev watcher also watches `.git/`: a background git
    fetch (or a git GUI writing `.git/gk`) hot-reloads the server MID-MATCH, which
    wipes the live-progress state and resets the page (verified 2026-09-26). Use
    `--dev` only while editing UI code.
