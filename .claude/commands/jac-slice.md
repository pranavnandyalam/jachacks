---
description: Build one vertical slice from PLAN.md end to end (build -> verify -> review -> commit)
argument-hint: <slice name from PLAN.md>
---

Build the slice "$ARGUMENTS" from `PLAN.md`.

1. Delegate implementation to the `jac-builder` subagent with the slice description from
   `PLAN.md`, the files it should touch, and the acceptance check (what must work in the
   running app).
2. When it returns, verify yourself: `jac check` (project root) and `jac test` must pass;
   for UI, drive the flow with `jac browse` against the running dev server
   (start it in the background with `JAC_DB_RO_UNITS=0 jac run --dev < /dev/null` if it is not running;
   restart it after server-side changes).
3. Delegate a review of the diff to the `jac-reviewer` subagent. Fix BLOCKER and HIGH
   findings (via `jac-builder` or directly).
4. Commit with a conventional message (`feat: <slice>`). Commit small and often - the repo
   history is part of the submission.
5. Mark the slice done in `PLAN.md` and state the next slice.

If anything fails and the cause isn't obvious within a few minutes, delegate to
`jac-debugger` instead of guessing.
