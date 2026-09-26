# JacHacks idea bank (ideas only, no code)

Each idea is designed so the graph and walkers carry the product, which is what
"leverages what makes Jac unique" rewards. Score them at kickoff on four things: Jac
depth, how strong the 3-minute demo moment is, whether it can be built in about 16
hours, and which special awards it can also target.

## Agentic AI (flagship, $750)

1. **Swarm Research Desk.**
   - What it is: planner, researcher, critic and writer agents, each a walker spawned
     on a shared "task graph". Claims, sources and critiques are nodes, with typed
     edges `Supports` / `Contradicts` / `DerivedFrom`.
   - How it works: the critic walker traverses `Contradicts` edges to force revisions,
     and `visit [-->] by llm(intent="most promising unexplored claim", select=1)`
     steers exploration.
   - Demo: ask a question, then watch the graph grow live at `/graph` while the agents
     argue. Finish with a sourced report.
2. **Agent Memory Palace.**
   - What it is: a personal assistant whose long-term memory is a per-user graph
     (`:protect` gives each user their own `root`).
   - How it works: `Episode`, `Person`, `Preference` and `Goal` nodes. Recall is a
     walker that ranks edges by salience (`[here ->:Remembers:-salience:->][:5]`).
     A consolidation walker merges duplicates with a `by llm()` judge.
   - Demo: it remembers across sessions, and a second user sees nothing.
3. **Incident Commander.**
   - What it is: an ops multi-agent system over a service-dependency graph. A triage
     walker traverses from the alerting service up its `DependsOn` edges.
   - How it works: each service node's ability calls a diagnosis `by llm()` with tools
     (mock metrics and logs). A commander agent assembles a timeline.
   - Demo: inject a fault and watch the walker localize the root cause hop by hop.

## Fintech & Open ($400)

4. **Fraud Ring Detector.**
   - What it is: transactions and accounts as a graph. Walkers do multi-hop traversal
     (`[acct ->:Sent:-> ->:Sent:->]`) to find rings and mules.
   - How it works: an LLM explains each flagged subgraph as a typed `FraudCase` obj
     with severity as an enum.
   - Demo: load synthetic data and highlight the ring in the graph.
5. **Portfolio Copilot.**
   - What it is: holdings, sectors, news and macro factors as a graph. Exposure is a
     walker that aggregates on exit (post-order) up the ownership tree.
   - How it works: a `by llm(tools=[get_quote, get_news])` agent proposes rebalances
     as typed `Trade` objs.
   - Note: this overlaps with the AutoTrader project, which may help. Keep the data
     mocked or read from a public API.
6. **Bill Negotiator.**
   - What it is: subscriptions and bills as nodes, and an agent that drafts
     negotiation or cancel scripts.
   - How it works: a walker finds overlapping services along `SameCategory` edges.

## Social Impact ($400)

7. **Care Navigator.**
   - What it is: a patient's symptoms, providers, insurance rules and appointments as
     a per-user graph.
   - How it works: a triage walker traverses a symptom→specialty→provider graph, with
     LLM-guided hops for ambiguous symptoms. Output is a typed `CarePlan`.
   - Fit: this overlaps with health-tech and Parkinson's research interests.
8. **Adaptive Tutor.**
   - What it is: a knowledge graph of concepts with `Prerequisite` edges.
   - How it works: a diagnostic walker finds the deepest unmastered prerequisite
     (a DFS with `visit :0:`), and `by llm()` generates typed quiz objs. Mastery is
     stored per user.
9. **Accessibility Auditor.**
   - What it is: crawl a site into a page→element graph. Walkers check WCAG rules at
     each node, and an LLM proposes typed fixes.
   - Demo: a live audit of a real site.

## Special-award add-ons

- **Best JAC Builder:** maximize Jac-only code. Put AI, graph, API and UI in one
  language, with `jac check` clean.
- **Best Claude Code + JAC Dev Tool** (a separate build written at the event): for
  example an MCP server or Claude Code skill *written in Jac*, such as a graph-of-code
  walker that answers "what calls X" using `jac code`.
- **Best Startup Idea:** Care Navigator or Fraud Ring Detector, with a crisp
  business model slide.
- **Viral content:** record the live-graph moment as a short clip.
