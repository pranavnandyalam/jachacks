---
description: Full pre-demo verification - check, test, serve, click through the demo path, review
---

Verify the app is demo-ready. Report each step's result; don't stop at the first failure.

1. `jac check` at the project root - zero errors.
2. `jac test` - all pass (LLM calls must use MockLLM in tests).
3. `jac run --serve --faux` - list served endpoints; flag anything user-facing that is
   plain/`:priv` (not served) or user data on `:pub`.
4. Start the server fresh (`pkill -f "jac run"`; `JAC_DB_RO_UNITS=0 jac run < /dev/null &`), then walk the
   exact demo path from `PLAN.md` with `jac browse` (open, snapshot, click/fill, screenshot)
   - including signup -> login as two different users to prove data isolation if auth is
   in the demo. Save screenshots to `submission/screens/`.
5. Check `/graph` renders the graph and `/docs` loads.
6. Ask `jac-reviewer` for a final pass; list BLOCKERS.
7. Output a go/no-go with the list of fixes, most demo-critical first.
