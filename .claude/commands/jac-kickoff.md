---
description: Hackathon kickoff - pick track + idea, then have jac-architect write PLAN.md
argument-hint: [idea or track, optional]
---

We are starting JacHacks. Idea/track input from the team (may be empty): $ARGUMENTS

1. Confirm the environment: `jac --version` (must be >= 0.37.22), that the `jac` MCP
   server is connected, and which app model key is set - check each with its own
   `printenv JAC_ANTHROPIC_KEY >/dev/null && echo set` call (also `GEMINI_API_KEY`,
   `OPENAI_API_KEY`). **If `ANTHROPIC_API_KEY` is set, warn loudly**: Claude Code
   bills the API instead of the subscription; the team should rename it to
   `JAC_ANTHROPIC_KEY` (CLAUDE.md rule 12). Report gaps.
2. If no idea was given, read `.claude/IDEA_BANK.md` (if present) and propose the top 3
   ideas for the tracks in `CLAUDE.md`, each scored on: Jac-unique depth, demo "wow",
   buildability in ~16h, and which special awards it can also target. Ask the team to
   pick one (use AskUserQuestion). Any opening-ceremony announcements the team pastes
   override `CLAUDE.md`.
3. Delegate to the `jac-architect` subagent with the chosen idea to write `PLAN.md`.
4. If there is no `jac.toml` yet, scaffold into the repo root (it keeps existing files
   like `CLAUDE.md`): `jac create --kind web-app` (or `jac create --use jac-shadcn` for
   polished shadcn/Tailwind UI; ask), then `.claude/scripts/jac-install-safe.sh --dev`
   (NOT bare `jac install` - see CLAUDE.md rule 10), `jac check`, and commit
   ("chore: scaffold"). Note: the scaffold's comments say "switch to `:priv` to require
   auth" - that's stale; use `:protect`.
5. Summarize: the pitch, the build order with the cut line, and the first slice to build
   (`/jac-slice <name>`).
