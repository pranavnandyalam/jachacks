---
name: check-in
description: Team status check-in for the hackathon. Verifies what actually works (tests, a live match, an independent exploit probe), lists what doesn't work or doesn't exist, and produces a time-boxed plan to the deadline with owners and a cut line. Use when the team asks "where are we", "check in", "status", "what's left", "make a plan", or before a checkpoint.
argument-hint: "[quick]  (quick = skip the live matches)"
---

# Check-in

Answer four questions with evidence: **what works, what doesn't, what we still need,
and the plan.** Every "works" claim must come from something you ran in THIS check-in,
not from memory, PLAN.md, commit messages or earlier sessions. If you didn't run it,
it goes under "untested".

Args: `$ARGUMENTS`. If it contains `quick`, skip step 4 (live matches, ~1 min each).

## 1. Situation (read-only)

Run these, each on its own:
- `date +%H:%M` to get the time. The deadlines are in `CLAUDE.md` (partial Devpost 9:30 AM Sun,
  final 12:00 PM Sun). Compute hours left.
- `git status --short`, `git log --oneline -8`, `git fetch -q && git status -sb | head -1`
  to find uncommitted work, unpushed commits, and teammates' new commits. **Read any new
  teammate commits** (`git show <sha> --stat` and the diff) since they change what you verify.
- The status line and task table in `PLAN.md`.
- `pgrep -fl "jac run"`: a stale server deadlocks the embedded Postgres, so kill it
  before starting another.
- `ollama ps`: the local model must be available for live matches.

## 2. Static checks

- `jac check` at the repo root: zero errors (W1051/W2003 warnings are noise).
- `jac test <file>.jac` for each engine module that has tests: `sandbox codebase referee
  attacker arena`. Report passed/failed per file. Test counts overlap because imported
  tests re-run, so report the per-file numbers, not a sum.

## 3. Independent ground truth (no game engine)

`python3 .claude/skills/check-in/probe.py target/app.py` should show LEAK on the
planted holes and health GREEN. That proves the target really is vulnerable and the
flag detection works. If the target was swapped, update the probe's ATTACKS list first.

## 4. Live matches (skip if `quick`)

Start the server in the background:
`JAC_DB_RO_UNITS=0 jac run --dev --no-client main.jac` (the API is on :8000; wait until
`POST /function/get_current_source` returns `"ok": true`).
Then `python3 .claude/skills/check-in/match.py 3` (run it in the background, ~1 min per match).
It plays full matches over HTTP and probes each final source independently.
Look for:
- Every planted hole found and patched (`open=0`), health true, and the probe all "safe".
- Rejected patches and their reasons. If Blue fails the same hole repeatedly, the
  feedback or the guard is wrong. To inspect a rejected draft's full source, temporarily
  add a `def:pub` that returns `RejectedPatch.source`, then remove it (you can't read the
  embedded Postgres directly).
- Round times, wasted rounds, and whether the game ended too early (holes never found).
Kill the server when done: `pkill -f "jac run --dev --no-client"`.

## 5. Output

Use plain, concrete language (the team dislikes abstract option lists). Use this format:

**Time:** HH:MM, N hours to the partial checkpoint / final deadline.

**Works (verified just now):** bullets, each with the evidence (e.g. "3/3 live matches,
all holes patched, 48–64s").

**Doesn't work / doesn't exist:** a table (item | status | why it matters). Include
untested things (deploy, hosted model) explicitly as untested, and uncommitted or unpushed work.

**Key decision(s):** at most 1–2 choices that change the plan, each with your
recommendation.

**Plan:** a table (time | what | who (A/B/C/D, per PLAN.md roles) | done-when) from now
to submission. Put the riskiest unknowns first (spike them early), the demo-critical
build next, a hard sleep/cut time, then the submission work (README, Devpost, video
under 3 minutes, partial checkpoint by 9:30). End with **Cut first:** and **Never cut:** lists.

Close by asking the 1–2 questions you need answered to proceed.

## Rules
- Read-only apart from starting and stopping the server: don't fix, commit or push during a
  check-in. List fixes in the plan instead and offer to do them.
- A failed or skipped step goes in the report as failed or skipped. Never round a flaky
  result up to "works". Report "2/3", not "works".
- Update `PLAN.md`'s status line only if the team asks.
