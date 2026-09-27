# Devpost submission: Red Queen

Copy each section into the matching Devpost field.

---

## Project name
Red Queen

## Tagline (Devpost limit: 200 characters)
An AI attacker hacks your app, an AI defender patches the code, and a referee proves every fix works. Round after round, until the scan comes back clean.

## Tracks and prizes to select
- **Agentic AI** (primary)
- **Developer Tools**
- **Best Jaclang**
- **Best Jachammer** (it's hosted on JacHammer)
- **ElevenLabs** sponsor prize ("Ask Red Queen" voice agent)

## Links ("Try it out")
- Live app (JacHammer): <PASTE HOSTED URL>
- GitHub: https://github.com/pranavnandyalam/jachacks
- Demo video: <PASTE VIDEO LINK>

## Built with
jac, jaseci, jac-client, by-llm, jachammer, openai, elevenlabs, react, python, flask, fastapi, typescript, express, go, litellm

---

## Inspiration

AI now writes a large share of the code that ships, and it makes the same security mistakes over and over: a route that forgets to check who's asking, an admin page any user can open, a debug endpoint that dumps secrets. These are **broken access control** bugs, the #1 risk on the OWASP Top 10.

Security scanners hand you a list of warnings and leave the fixing to you. And if you ask an LLM to "fix the security bugs", you get a confident answer with no proof, and sometimes a patch that quietly breaks the app.

We wanted a tool that **finds real exploits, fixes them, and proves each fix works**, without taking any AI's word for it. The name comes from the Red Queen hypothesis in evolution: you have to keep running just to stay in place. Attack and defense co-evolve until nothing gets through.

## What it does

Pick an app and press **Harden this codebase**. Red Queen runs a loop you can watch round by round:

1. **Red (attacker agent)** reads the source and finds concrete requests that break the app's rules: *"alice can read the admin's private notes with `GET /members/admin/notes`"*.
2. **The Referee** confirms each hole is real before anything gets fixed. For Python apps it **actually fires the exploit** in a sandbox and checks whether a freshly generated secret leaks.
3. **Blue (defender agent)** patches the code, at most two holes per round.
4. **The Referee judges the patch.** It re-fires every exploit, and it re-runs the app's own health checks (e.g. "alice can still read her *own* notes"). A patch that breaks the app or doesn't close the hole is **rejected, and Blue retries with the referee's exact reason.** Bad patches never go live.
5. Red scans the patched code again. When a scan finds nothing, the app is **clean**.

It works across **4 stacks** (Flask, FastAPI, Express/TypeScript and Go) on 5 demo apps with 17 planted access-control bugs. In our test runs it found and fixed them all, at 10 to 70 seconds and about 1 to 2 cents per app.

**Ask Red Queen:** an ElevenLabs voice agent sits on the dashboard. Ask it *"what did you find?"* or *"how did Blue fix it?"* and it explains, out loud and in plain English, the vulnerabilities and fixes on screen. It's grounded in the live audit, so it describes what actually happened instead of making things up.

## How we built it

**Jac end to end: about 75% of the codebase (23 Jac files).**

- **The audit is a Jac graph.** An `Auditor` node owns the run. Every round becomes typed nodes and edges: `Agent` nodes for Red, Blue and the Referee; `Vulnerability` nodes (`Found` by a pass, `Discovered` by Red, `LivesIn` the `SourceFile` whose handler has the bug); `PatchAttempt` nodes, including **rejected ones with the referee's reason** (`Wrote` by Blue, `Judged` by the Referee, `Closes` the vulns it fixed); and a `FileVersion` chain per file (`VersionOf`, `Next`, `Produced`). You can walk the graph from any bug to the exact patch and file version that closed it. In total: 17 node types and 18 typed edges.
- **Agents are typed `by llm` functions, not prompt strings.** `find_vulns -> VulnReport`, `fix_all -> PatchSet`, `fix_by_edits -> EditPlan`, `check_hole -> HoleCheck` and `judge_outcome -> Outcome` (an enum). `sem` annotations describe each field. Every agent returns structured, typed data that the deterministic code can act on. One `RQ_MODEL` setting switches every agent between a local model and a hosted one (we ship on `gpt-4.1-mini`).
- **The Referee is code wherever it can be.** Python targets run in a subprocess sandbox that injects a random secret, replays each exploit, and runs the manifest's health checks. For Go, TypeScript and FastAPI, which we can't run in-process, a patch must apply cleanly and pass the language's own parser (`gofmt`, `py_compile`, TypeScript). A code-tracing referee then gets the **exact handler source**, located deterministically in any of the four languages, and traces the request step by step.
- **Frontend in jac-client:** a React dashboard written in Jac, with live round-by-round progress, per-file diffs, a code viewer, the graph view, and the ElevenLabs voice button (`@elevenlabs/react`). The API key stays server-side: a Jac `def:pub` endpoint mints signed session URLs.
- **Drop-in targets:** any app becomes a target with a `manifest.json` (users, a secret hint, health checks, and a plain-English access `policy`).
- **Hosted on JacHammer.**

## Challenges we ran into

- **LLMs grading LLMs rubber-stamp.** Our first code-tracing referee agreed with whatever Red claimed. Three fixes: the referee only ever sees the *request*, never Red's argument; it gets the exact handler code (so it can't trace a look-alike route); and a separate enum classifier reads its trace. With those, it went from "everything is exploitable" to judging every one of our 11 Task Board test cases correctly.
- **Models fill booleans badly.** A structured `exploitable: bool` field came back wrong even when the model's own trace said "returns 404". Pulling the verdict from the trace, and later a dedicated enum judge, fixed it.
- **Over-eager defenders.** Blue would rewrite whole files, or "fix" a leak by locking a page that had to stay public. The referee now tells Blue exactly which legitimate request its patch broke. That produces our favorite demo moment: a patch rejected, then a correct retry.
- **Red stopped after its first few ideas.** It also returned route templates (`/lists/<int:list_id>`) instead of real URLs. Now later scans are told what's already been found and must cover the other routes, and the referee fills template slots with each known user and a few ids.
- **Infra:** a Jac macOS install bug, a read-only-tier database bug we worked around with `JAC_DB_RO_UNITS=0`, a local 30B model too slow and weak for the referee (we moved to a hosted model), and a hosting proxy that dropped the page's first API calls (the dashboard now retries on boot).

## Accomplishments that we're proud of

- **No bad patch ever went live.** Every fix is either proven by replaying the exploit plus health checks, or, for other languages, compiled and re-traced.
- **One loop, four languages.** The same attacker/defender/referee loop hardens Flask, FastAPI, TypeScript and Go apps.
- **A graph that tells the whole story:** which agent found what, where it lives, what was tried, why the referee said no, and how every file changed.
- **A voice you can interrogate:** judges can ask it about the security findings in plain English.

## What we learned

- **Don't trust the model; verify it.** The most valuable code in this project isn't a prompt, it's the referee.
- **Typed `by llm` outputs make agents composable.** Structured returns let deterministic code gate, retry and record everything the agents do.
- **Representing the process as a graph pays off.** Once findings, attempts and file versions were nodes and edges, debugging, the dashboard and the voice agent all got easier.

## What's next for Red Queen

- **Always on:** Red Queen watches the codebase and re-audits automatically on every edit, commit or push. A new route or a changed handler triggers a fresh scan of just what changed, so a vulnerability gets caught and patched minutes after it's introduced, not in a quarterly pentest.
- **Agent swarms:** instead of one Red and one Blue, spawn a swarm of specialized attackers (access control, injection, SSRF, secrets) that hunt in parallel and coordinate through the shared Jac graph. Walkers dispatch each agent to its slice of the codebase, and a pool of defenders patches in parallel while the referee serializes what goes live.
- **Scaling with vLLM:** serve open-weight models on our own GPUs with vLLM, so swarms can run hundreds of scans in parallel at high throughput and near-zero cost per run, and code never has to leave the customer's infrastructure.
- **A pull-request bot:** run Red Queen on every PR and push the verified patch as a suggested commit.
- **Live verification for every language:** boot Go, Node and FastAPI apps in containers and replay exploits over HTTP, so non-Python fixes get the same proof as Python ones.
- **More bug classes:** injection, SSRF and insecure deserialization, beyond access control.
- **Real isolation:** a container sandbox instead of a subprocess plus a static blocklist.

---

## Team
<!-- Names and roles -->

## Checklist before submitting
- [ ] Hosted URL pasted, and a harden run tested on it
- [ ] Demo video uploaded and linked (Book Club run → rejected patch → Go/TS site → graph → voice)
- [ ] Tracks selected: Agentic AI, Developer Tools, Best Jaclang, Best Jachammer, ElevenLabs
- [ ] Repo public, README Team section filled
- [ ] Partial submission in by 9:30 AM
