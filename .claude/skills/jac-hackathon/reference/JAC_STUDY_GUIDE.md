# Jac Study Guide (jaclang 0.37.23)

Condensed from a full read of the docs at <https://jaclang.org/docs/latest>. The
site is client-rendered, so this was read from its source:
`jaseci-labs/jaseci` → `jac/jaclang/cli/docs/**` (the docs) and
`jac/jaclang/cli/skills/**` (the agent guides that `jac guide` prints). Snapshot:
repo `main` @ `7e812d1`, 2026-09-26.

> **Version note.** Latest release is **jaclang 0.37.23** (2026-09-24). The
> Breaking Changes page labels several entries "unreleased", but the release
> notes show they shipped in **0.37.22**: private-by-default endpoints and
> required edge endpoints. 0.37.23 also bumps litellm so structured output
> works on **Claude Opus 5.5 / Fable 5.1**. Run `jac --version`. If it's older
> than 0.37.22, the endpoint and edge rules below don't apply yet.

> **Verified with the real compiler** (jac 0.37.23 on macOS arm64, 2026-09-26):
> - A bare `edge {}` is E2086, and only `:pub` and `:protect` are served.
> - `.length` is E1030, and `jacSignup` returns `.success`.
> - **`jac install` is broken on this binary** because the bundled python can't
>   import `_posixsubprocess`. As a result `by llm()`, even with MockLLM, can't get
>   litellm. Use `harness/template/.claude/scripts/jac-install-safe.sh`. See
>   `harness/README.md`.

---

## 0. Top 25 rules (the ones that bite)

1. Blocks use `{ }`. Every statement ends with `;`. The exception is
   `match`/`case`: arms are `case X:` plus **Python indentation**.
2. Brace imports take **no** semicolon: `import from os { path }`. Module imports
   do: `import os;`. `import:py` **does not exist**.
3. There's no `pass` statement (E0010). Write `{}`.
4. Tuple unpacking needs parens: `for (i, x) in enumerate(xs) { }`.
5. Ternaries are Python style (`a if c else b`), booleans are `and`/`or`/`not`,
   and the literals are `True`/`False`/`None`.
6. Every `def` parameter and `has` field needs a type, and so does the return
   of a value-returning `def`. Don't write `-> None` (W3037). A bare
   `list`/`dict` is E1036. Write `dict[str, any]`.
7. The gradual type is lowercase `any`. `` `any(...) `` (with a backtick) is the
   builtin function. `import from typing { Any }` is an error (E1122).
8. `self` is implicit in methods. The constructor is `def init` (call
   `super.init()`), and there's also `def postinit`. Instance fields are declared
   with `has`.
9. Use `def` for methods and functions. `can` is **only** for event abilities
   (`can x with T entry/exit`).
10. `root` is a bare keyword. `root()` is an error (E0049). Use `Root` in type
    positions.
11. `with entry {}` runs **every time the module is imported**. Put demo and CLI
    code in `with entry:__main__ {}`.
12. **Endpoint exposure (≥0.37.22):** `:pub` is an anonymous endpoint and
    `:protect` is an authenticated, per-user endpoint. **A plain declaration or
    `:priv` is not served at all.** Much older material says otherwise.
13. **Edges must declare endpoints:** `edge Follows: Person --> Person {}`. A
    bare `edge E {}` is E2086. Use `any --> any` to opt out.
14. `visit` **queues** destinations and does not jump. Traversal is BFS by
    default. `visit :0: [-->]` is DFS.
15. A walker's generic `can x with entry` fires **only at the spawn node**. Use
    typed entries.
16. Exit abilities are deferred and run post-order (LIFO). Accumulate on entry,
    then `report` once in `with Root exit`.
17. `report` also prints to stdout. Declare `has reports: list[T] = [];` on
    walkers. The `= []` is required (E1050).
18. `skip;` ends the current ability only. `disengage;` stops the whole walker.
19. `++>` returns its right-hand side: a single node when connecting one node
    (no `[0]`), a list when connecting a list.
20. `by llm()` replaces the function body. Describe things with `sem`, not
    docstrings. Inline `"..." by llm` is **not implemented** and raises at
    runtime.
21. Client-side calls to server functions are async, so always `await` them.
    Walkers are called with `root spawn W(kw=..)` and the results are in
    `result.reports`.
22. Client state is `has`, and updates must be **immutable**:
    `xs = xs + [x]`, not `xs.append(x)`.
23. Client event lambdas need typed params: `lambda (e: ChangeEvent) { ... }`.
24. `jac clean` does **not** reset the graph database. The graph lives in
    embedded Postgres under `~/.cache/jac/pg/main`. Use `jac db list` and
    `jac db drop <name> -y`.
25. After every edit, run `jac check`. Unused names warn (W2003); prefix them
    with `_`.

---

## 1. What Jac is

Jac is one language that compiles to **three codespaces**: server (Python
bytecode, with PyPI available), client (JavaScript/React, with npm available),
and native (LLVM/C-ABI, which can also target wasm). It rests on two ideas:

- **Synechic.** It's one continuous, compiler-checked medium across tiers. The
  compiler **infers placement** and generates the RPC, serialization and routing
  between codespaces. You write no route tables and no fetch code.
- **Topokinetic (Object-Spatial Programming).** Data lives in a graph of `node`s
  and `edge`s. Computation (`walker`s) moves *to* the data, and abilities fire
  on arrival ("dispatch by arrival, not invocation").

It also has these supporting mechanisms:

- **Meaning types / byLLM:** `def f(x: T) -> U by llm();`. The prompt is
  synthesized from names, types and `sem`, and the return type is the validated
  output schema.
- **Scale invariance:** the same code runs as a script, as an API server
  (`jac run`), and on Kubernetes (`jac scale deploy`).
- **Persistence by reachability:** a node attached to `root` is persisted.
  Every authenticated user gets their own `root`.
- **Gradual borrow checking** (`own`, `&`, `&mut`, `imm`, `Region`) is opt-in
  and mostly matters for native code.

Placement is inferred with no syntax:

- **Client evidence:** JSX, browser globals, and string-path npm imports
  (`import from "react" { ... }`, `import "./x.css";`).
- **Server anchors:** Python imports, `node`/`edge`/`walker`, `::py::`, and
  persistence/root access. Server is also the default.
- **Native seeds:** extern C declarations
  (`import from raylib { def InitWindow(w: i32, ...) -> None; }`).

Placement propagates through references. `def:pub`/`:protect` functions and
walkers **stay server** and are RPC-bridged. An `obj` or `node` used on both
sides is shared as a wire type. To override a placement, use `jac.toml`
`[placement.pins] "mod.name" = "server"|"client"|"native"`, and inspect the
result with `jac explain placement`. (The old `sv`/`cl`/`na` markers and the
`.cl.jac`/`.sv.jac`/`.na.jac` suffixes are gone; `jac fix placement` migrates
them.)

---

## 2. Toolchain and CLI

```bash
curl -fsSL https://raw.githubusercontent.com/jaseci-labs/jaseci/main/scripts/install.sh | bash
jac --version        # self-contained binary: no Python/pip/Node needed (bundles Bun)
```

- **VS Code:** install the "Jac Language Support" extension (`jaseci-labs.jaclang-extension`).
- **Docker:** `jaseci/jaclang:latest`.

### Project kinds (`jac create <name> --kind <k>`)

Run `jac create --list` to see them.

| Kind | Bare `jac run` does |
|---|---|
| `cli` (default) | execute |
| `service` | serve API (no client) |
| `web-app` | serve server + React client (`main.jac` + `endpoints.jac` scaffold) |
| `web-static` | client-only static page (no backend) |
| `desktop` / `mobile` | OS-webview app / React Native (mobUI) app |
| `cli-native`, `native-binary`, `native-lib` | native JIT / binary / C-ABI lib |
| `py-package`, `js-package` | build a wheel / npm tarball |
| `service-mesh` | microservices |

Variant: `jac create app --use jac-shadcn` gives a web-app with shadcn/ui and
Tailwind. Jacpacks can be loaded by URL:
`jac create x --use https://.../foo.jacpack`.

### `jac run` is kind-aware

A bare `jac run` resolves the app's kind and **executes**, **serves**, or
**builds**. A standalone `.jac` file with no `jac.toml` just executes.
`--serve`/`--no-serve` force the choice. Put flags **before** the filename,
because everything after it goes to `sys.argv`.

```bash
jac hello.jac                 # == jac run hello.jac (execute)
jac run                       # default app per [project] kind
jac run --dev                 # HMR dev loop (client modules hot-reload; server edits need restart)
jac run --serve app.jac -p 3000
jac run --no-client           # API only
jac run --faux                # print endpoint docs, no server
jac run --show                # print resolved plan
jac run -e all main.jac       # show warnings too
jac run --entry my_walker main.jac
```

While serving, these URLs are available: `/docs` (Swagger), `/redoc`,
`/openapi.json`, `/graph` (live graph viewer), `/healthz`, and `/admin`
(admin portal).

**Renamed or removed commands:**

| Old | New |
|---|---|
| `jac start` | `jac run --serve` |
| `jac dev` | `jac run --dev` |
| `jac start --scale` | `jac scale deploy` |
| `jac lint` | `jac check --lint` |
| `jac add` | `jac install <pkg>` |
| `jac purge` | `jac cache purge` |
| `jac nacompile` | `jac build --native` |
| `jac serve` | doesn't exist |

### Everyday commands

```bash
jac check [paths] [--lint [--fix]]   # type check (also runs on every compile now)
jac fmt . [--check]                  # format
jac test [file|dir|app] [-t name] [-x] [-v]
jac install [pkg] [--dev|--npm|--git URL|--shadcn button card|--no-save]
jac remove pkg [--npm];  jac update
jac guide [name] [--search kw] [--sections|--section s]   # version-matched agent guides
jac guide --export .claude/skills    # export guides as Claude Code skills
claude mcp add jac -- jac mcp        # live compiler tools for Claude Code
jac code map | symbol X | walkers T | slice f -d 2       # structural queries (JSON)
jac browse open localhost:8000 / snapshot / click @e5 / screenshot  # headless QA
jac dot app.jac -p                   # graph as DOT
jac db status|list|inspect|sql "..."|drop NAME -y|prune -y
jac clean [--cache|--all]            # project .jac/ dirs (NOT the Postgres graph)
jac cache status|gc|purge            # machine-wide cache (~/Library/Caches/jac on macOS)
jac build [--as jab|wheel|npm|source|client|native]
jac scale deploy|status|destroy      # Kubernetes
jac model list|pull gemma-4-e4b|rm   # local LLM weights
```

**Persistence reset:** graph data is stored in an **embedded Postgres** cluster
shared by the whole machine (`~/.cache/jac/pg/main`), with one database per
project path. To wipe it, find the database with `jac db list`, then run
`jac db drop jac_<proj>_<hash> -y`. Tutorials that say `jac clean --all` fixes
`NodeAnchor` errors are stale; the FAQ confirms that `jac clean` doesn't touch
the database. After a toolchain upgrade misbehaves, run `jac clean --cache` and
then `jac cache purge --bucket jir-modules`.

---

## 3. Core syntax

```jac
"""Module docstring (docstrings go BEFORE declarations)."""
import os;                                  # module import: needs ;
import from math { sqrt, pi as PI }         # brace import: NO ;
import type from billing { Invoice }        # annotation-only (breaks cycles)
include utils;                              # merge namespace

glob MAX: int = 100;                        # module variable

def add(a: int, b: int) -> int { return a + b; }
def double(n: int) -> int { n * 2 }        # tail expr w/o ';' = implicit return
def greet(name: str, greeting: str = "Hi") -> str { f"{greeting}, {name}!" }

with entry:__main__ {
    xs: list[int] = [1, 2, 3];
    for (i, x) in enumerate(xs) { print(i, x); }
    for i = 0 while i < 10 with i += 2 { print(i); }   # C-style for
    while MAX > 0 { MAX -= 1; }             # assignment inside a function rebinds the glob
    label = "big" if len(xs) > 2 else "small";
    sq = lambda (x: int) -> int { x * x; };  # lambda: parens + braces + typed params
    get = lambda { 42; };                    # zero-arg may omit parens
    print(xs?[99], os?.name);                # null-safe ?. ?[] (also out-of-range → None)
    if (n := len(xs)) > 2 { print(n); }      # walrus
    5 |> str |> print;                       # pipes: |> <| :> <: .> <.
    try { int("x"); } except ValueError as e { print(str(e)); } finally { }
    with open("f.txt") as fh { _ = fh.read(); }
    assert len(xs) == 3, "msg";
    match xs {
        case [a, b, c]:
            print(a + b + c);
        case _:
            print("other");
    }
    switch 2 { case 1: print("one"); break; default: print("other"); }  # C fallthrough
}
```

- **Comments:** `# line` and `#* block *#`.
- **Keywords as names:** escape them with one leading backtick, e.g.
  `` has `type: str; ``. Python reserved words can't be used as field or
  parameter names even when escaped (E0067). A backtick on a non-keyword is
  E0014.
- **Scoping:** there's no `global` or `nonlocal`. Assignment binds to the
  nearest enclosing binding (including a `glob`). To shadow instead, write a
  *typed* declaration (`x: int = 5;`) before first use.
- **Other forms:** generators (`yield`, `yield from`), `async def`/`await`,
  `flow f()` / `wait fut` (a thread pool), `::py:: ... ::py::` inline Python,
  and `comptime` (compile-time evaluation).
- **Tests:** `test "name" { assert ...; }` blocks sit alongside the code.

---

## 4. Types

- Builtins: `int float str bool bytes list tuple set dict any type None`, plus
  the fixed-width types `i8..i64 u8..u64 f32 f64`. Those trap on overflow;
  narrowing needs `T(x)`, and `T.wrap(x)` truncates modularly.
- Unions are written `A | B`, and optionals `T | None`. Don't use
  `Optional`/`Union`/`List`/`Dict`.
- **Ambient names** need no import: `Callable`, `Iterable`, `Sequence`,
  `Mapping`, `Protocol`, `TypeVar`, `Literal`, `ClassVar`, `Awaitable`, and
  others. Importing them is E1125.
- **Strict `any` rule:** an `any` value can't flow into a typed destination
  (E1001/E1002), and the check applies element-wise to containers. There are
  three fixes: type the source (for example `has reports: list[T]`, or a
  `.pyi`), accept an `any` local and narrow it with `isinstance`, or cast with
  `value as T`. The cast is unchecked and does nothing at runtime; write
  `(x as int) + 1` with parens.
- Generics: `def first[T](xs: list[T]) -> T`, `obj Result[T, E = Exception]`.
  Watch out: `Result[int](...)` with a defaulted parameter raises at runtime, so
  construct without the subscript.
- `-> Self` resolves to Unknown in the checker, so return the concrete class
  name instead.
- Type aliases look like `type Json = str | int | list[Json];`.
- **Common codes:**

  | Code | Meaning |
  |---|---|
  | E1030 | no such attribute (for example `.map()` on a list) |
  | E1032 | type is Unknown (bad import or `Self`) |
  | E1001 | assignment type mismatch |
  | E1036 | bare generic container |
  | E1050 | missing required walker `has` |
  | E0052 | untyped parameter |

---

## 5. Archetypes: `obj`, `class`, `enum`, `impl`

```jac
obj Person {                              # dataclass-like: auto __init__/__eq__/__repr__
    has name: str,
        age: int = 0;                     # non-default fields BEFORE defaulted (E2004)
    static has count: int = 0;
    has area: float postinit;             # set in postinit
    has _bal: float = 0.0,
        bal: float { getter -> float { return self._bal; } setter(v: float) { self._bal = v; } };
    def postinit { self.area = 0.0; }
    def greet -> str { return f"Hi {self.name}"; }     # no-arg def: parens optional
    static def make(n: str) -> Person { return Person(name=n); }
    def area_fn() -> float abst;          # abstract (keyword is `abst`)
}
obj Dog(Person) { override def greet -> str { return "Woof"; } }

class Legacy { def init(n: str) { self.n = n; } }   # Python-class semantics (metaclasses etc.)

enum Color { RED, GREEN }                  # Color.RED.value → 1
enum Tag: str { OPEN = "open" }            # StrEnum: members ARE strs (no .value)
enum Code: int { OK = 200 }                # IntEnum

obj Calc { has v: int = 0; def add(n: int) -> int; }   # declaration only
impl Calc.add { self.v += n; return self.v; }          # body (often in calc.impl.jac)
```

- **Annex files** share the base name and merge automatically: `mod.impl.jac`
  holds implementations, `mod.test.jac` holds tests, and `Comp.style.css` holds
  auto-scoped CSS.
- **Access tags** mean different things in three contexts:

  | Context | `:pub` | `:protect` | `:priv` |
  |---|---|---|---|
  | Member (inside an archetype) | anyone | class and subclasses | class only |
  | Top-level visibility | any module / other projects | same project | same module |
  | Served endpoint | anonymous endpoint | authenticated endpoint | **not served** (same as plain) |

---

## 6. Object-Spatial Programming

### Declaring and connecting

```jac
node Person { has name: str; has age: int = 0; }
edge Knows: Person --> Person { has since: int = 2020; }   # endpoints REQUIRED
edge Link: any --> any {}                                  # explicit "untyped"

with entry {
    a = Person(name="A"); b = Person(name="B"); c = Person(name="C");
    root ++> a;                       # untyped edge (returns a)
    a ++> [b, c];                     # fan-out (returns list)
    a <++> b;                         # both directions
    c <++ a;                          # a → c written backwards
    a +>:Knows(since=2021):+> b;      # typed edge; fields ONLY via ctor parens
    root ++> a ++> b;                 # chains
    f = graph { a ++> [b, c]; };      # construction expr → GraphFragment (.root .nodes .edges .tips)
}
```

- Typed connections that violate an edge's declared endpoints are E1136 or
  E1137.
- `a +>:Knows:since=1:+> b` parses but **silently drops** the field.

### Querying the graph

| Expression | Returns |
|---|---|
| `[root -->]` | out-neighbors (also `[root <--]` in, `[root <-->]` both) |
| `[a ->:Knows:->]` | via edge type; inferred as `list[Person]` from endpoints |
| `[a <-:Knows:<-]` | incoming via edge type |
| `[a ->:Knows:since > 2020:->]` | edge-field predicate (name the edge type) |
| `[root -->][?:Person]` or `[root -->[?:Person]]` | type filter |
| `[root -->[?:Person, age >= 18]]` | type + field predicate |
| `[root -->[?age > 3]]` | field predicate only |
| `[a ->:Knows:-> ->:Knows:->]` | multi-hop (friends of friends) |
| `[root -->[?:Person, -age]][:10]` | order (`-` = descending) + limit, pushed into SQL |
| `[ch ->:Posted:-sent:-> [?:Msg]]` | order by an **edge** field |
| `[?:Msg, (at, seq) < (c.at, c.seq)]` | keyset paging |
| `[edge a ->:Knows:->]` | the edge objects themselves |
| `[root -->[?:Person]](=age=0)` | assign-comprehension bulk update |

- A query is deduplicated, returns results in edge-creation order, and is
  evaluated eagerly where it's written.
- The edge-type slot takes a bare name only. For a dynamic type, assign it to
  a variable first (`t = Knows; [->:t:->]`).

### Walkers

```jac
walker FindAdults {
    has min_age: int = 18,
        found: list[Person] = [],
        reports: list[list[Person]] = [];         # typed report channel
    can start with Root entry { visit [-->]; }     # MUST visit to leave root
    can check with Person entry {
        if here.age >= self.min_age { self.found.append(here); }
        visit [-->];                               # queue children (BFS)
    }
    can done with Root exit { report self.found; } # once, after everything
}
with entry {
    res = root spawn FindAdults(min_age=21);       # also: w spawn root; node spawn W()
    adults: list[Person] = res.reports[0] if res.reports else [];
}
```

**Special references:**

| Name | Available in | Refers to |
|---|---|---|
| `self` | walker ability | the walker |
| `here` | walker ability | current node |
| `self` | node ability | the node |
| `visitor` | node ability | the walker |
| `root` | anywhere | the root node |

**Visit forms:**

| Form | Effect |
|---|---|
| `visit [-->]` | queue out-neighbors at the end (BFS) |
| `visit :0: [-->]` | queue at the front (DFS) |
| `visit [-->] else { ... }` | else-branch runs if nothing was queued (get-or-create) |
| `visit here` / `visit node_var` | queue a specific node |
| `visit [edge -->]` | run **edge abilities**; plain node visits don't wake edges |
| `visit [-->] by llm(intent="...", select=1)` | the LLM chooses the next hop |

- **Node-side abilities:** `can greet with MyWalker entry { visitor.x ... }`.
  A generic `can f with entry` on a **node** fires for every walker. A union
  entry looks like `with A | B entry`.
- **Typed context blocks** switch on the node's subtype:
  `->Dog{ ... } ->Cat{ ... }`. The `->_{}` wildcard form is not supported.
- Spawning a walker on a node runs that node's matching entry too, which can
  cause off-by-one counts.
- Separate `visit`s can enqueue the same node twice in diamond-shaped graphs.
  Guard with a `seen` set.

### `del` and graph builtins

- `del node_var` destroys the node and all its edges.
- `a del --> b` removes an untyped edge. `del [edge a ->:E:-> b]` removes typed
  edges.
- To drop a reference *without* destroying the node, rebind it
  (`x = None`). `del root` is rejected.
- Graph builtins: `jid(x)` (stable ID string), `jobj(id)` (resolve by ID,
  **ignores permissions**), `save(x)`, `commit()`, `on_commit(fn)` (a side
  effect that runs exactly once after commit), `printgraph(root)` (returns DOT),
  `allroots()`, `grant`/`revoke`, `root.shared`.
- **Use `jid()`, never Python `id()`, for identity.**

---

## 7. Persistence and multi-user data

- Nodes reachable from `root` persist in Postgres: embedded locally, or set
  `JAC_DB_URL` / `[scale.database] url` for an external server. Each request
  runs in one SERIALIZABLE transaction. On a write conflict, the loser is
  **replayed** (the default `on_conflict = "retry"`), so find-or-create is safe.
  Put external side effects in `on_commit(...)`.
- **Schema edits never delete data.** An added field with a default gets that
  default. A removed field goes to the "attic". Changed types are coerced. Rows
  that can't load go to quarantine (`jac db sql "SELECT * FROM quarantine"`).
  Renames need `@archetype_alias("__main__.Old")` or
  `schema_alias("new", stored="old")` inside `__jac_schema__`.
- **Per-user isolation:** authenticated requests see `root` as *the caller's*
  root. Anonymous `:pub` calls run on the shared guest root (`root.shared`).
- **Sharing:**

  | Tool | Effect |
  |---|---|
  | `grant(node, level=AccessLevel.READ)` | open one node to **all** users |
  | `Jac.allow_root(node, UUID(root_id), level)` | open to one user (`import from jaclang { JacRuntime as Jac }`) |
  | `Jac.allow_group(node, UUID(jid(team)), level)` | open to a group; membership is an edge |
  | `root.shared ++> Post(...)` | public commons (floored at CONNECT) |
  | `def __jac_access__ -> AccessLevel { ... }` | archetype-wide policy |

  Levels are `AccessLevel.NO_ACCESS` < `READ` < `CONNECT` < `WRITE`. The enum is
  ambient; the old `ReadPerm` etc. are removed.
- **Pitfall:** grants are per-node, not per-subtree. Forgetting a grant is the
  #1 cause of "the other user sees nothing".
- `allroots()` walks every user's root, which is O(users) per call. For public
  feeds, `root.shared` is better.
- Invite tokens: `jaclang.server.identity.app_tokens`
  (`token_create`/`token_consume`, which is atomic).

---

## 8. Serving: endpoints, auth, and more

**Exposure, per declaration** (applies to top-level `def` and `walker`):

| Tag | Served? | Auth | `root` inside is… |
|---|---|---|---|
| `:pub` | yes | none | guest `root.shared` if anonymous, the caller's own root if a token is sent |
| `:protect` | yes | JWT required (401 without) | the caller's own isolated root |
| plain / `:priv` | **no** | — | (in-process helper; a client import is E5082) |

- **REST paths:** `POST /function/<name>` has a body matching the parameters.
  `POST /walker/<name>` has a body matching the walker's `has` fields.
- **Response envelope:**
  `{"ok":true,"type":"response","data":{"result":<return>,"reports":[...]},"error":null,"meta":{...}}`.
  Errors come back as `ok:false, error:{code,message}`. Returned archetypes
  carry the `_jac_type`, `_jac_id` and `_jac_archetype` keys.
- **Prefer `def:pub` functions** for anything that doesn't traverse: you get
  typed returns and no `reports[0]` unwrapping. Use walkers when you actually
  `visit`.
- `@restspec(method=HTTPMethod.GET, path="/items/{id}")` changes the method and
  path. `HTTPMethod` needs `import from http { HTTPMethod }`. Parameters are
  classified as path, then file (`UploadFile`), then query (for GET), then body.
  `envelope=False, produces="text/plain"` returns a raw body (functions only).
- Mark an endpoint `async def:pub` when its body `await`s.
- **Auth REST:**
  - `POST /user/register` takes
    `{"identities":[{"type":"username","value":"u"}],"credential":{"type":"password","password":"p"}}`.
    It's an identity array, not a flat body (a flat body is a 422).
  - `POST /user/login` takes `{"identity":{...},"credential":{...}}` and returns
    `data.token`, `root_id` and `role`. Send it as `Authorization: Bearer <token>`.
  - Also available: `/user/refresh-token`, `PUT /user/password`, `/user/me`.
- **Admin and security:** set `[serve.auth] secret` (or `JAC_SERVE_AUTH_SECRET`)
  in production; the dev server mints `.jac/data/jwt_secret`. Roles are
  `admin`/`system`/`user`. The admin portal is at `/admin`. SSO is configured
  with `[scale.sso.google] client_id/client_secret` and served at
  `/sso/google/login`.
- **Webhooks:** `@restspec(protocol=APIProtocol.WEBHOOK)` serves at
  `/webhook/<name>`, authenticated with `X-API-Key` plus an HMAC
  `X-Webhook-Signature`. A GitHub variant is `scheme="github"`.
- **WebSockets:** `@restspec(protocol=APIProtocol.WEBSOCKET[, broadcast=True])`
  on an `async walker:pub` serves at `ws://host/ws/<name>`.
- **Scheduler:** `@schedule(trigger=ScheduleTrigger.STATIC, interval=60 | cron="0 9 * * *")`
  on a function or walker. Cron is in UTC and **0 = Monday**. DYNAMIC jobs are
  managed through `POST /jobs`. It only runs while serving; set
  `[scale.scheduler] enabled = true` and run `jac install`.
- **SSE streaming:** in a `def:pub`, `report gen();` where `gen` yields. The
  browser consumes it with raw `fetch`, not the RPC stub.
- **Blob storage:** `store()` (local by default; S3/GCS with config).
- **Microservices:** `[apps.<name>] kind="service"`. Imports across apps become
  typed-async bridge stubs (`await` them). Services are colocated by default;
  `--fleet` runs them separately.

---

## 9. Full-stack client (React under the hood)

Components are written as Jac functions, not React JS.

```jac
import "./styles.css";                              # string import → client
import from "@jac/runtime" { Link, useNavigate }

node Task { has title: str, done: bool = False; }

def:protect add_task(title: str) -> Task { return root ++> Task(title=title); }
def:protect list_tasks -> list[Task] { return [root-->][?:Task]; }

def:pub TaskItem(task: Task, onToggle: Callable[[], None]) -> JsxElement {
    <li className={"done" if task.done else ""} onClick={onToggle}>{task.title}</li>
}

def:pub app -> JsxElement {                          # entry: lowercase `app`, :pub
    has tasks: list[Task] = [],                      # has = reactive state
        text: str = "";

    async can with entry { tasks = await list_tasks(); }   # mount effect
    # can with [dep] entry {...}  re-run on dep change;  can with exit {...} cleanup

    async def add {
        if text.strip() {
            t = await add_task(text.strip());        # ALWAYS await RPC
            tasks = tasks + [t];                     # immutable update → re-render
            text = "";
        }
    }

    <div>
        <input value={text}
            onChange={lambda (e: ChangeEvent) { text = e.target.value; }}
            onKeyDown={lambda (e: KeyboardEvent) { if e.key == "Enter" { add(); } }} />
        <button onClick={add}>Add</button>
        <ul>{for t in tasks { <TaskItem key={jid(t)} task={t} onToggle={lambda { }} /> }}</ul>
        {len(tasks) == 0 and <p>Nothing yet</p>}
    </div>
}
```

### Rules

- Declare props as typed parameters. `children: any = None` needs the default.
  Callback props use `Callable[[A], R]`.
- Events are ambient types needing no import: `MouseEvent`, `ChangeEvent`,
  `KeyboardEvent`, `FormEvent`, `InputEvent`, `FocusEvent`, `Event`.
- Assigning a `has` field in the component body is E0082. Write state from
  handlers and abilities only.
- Declare `has` and call hooks **before** any conditional `return`, per
  React's rules of hooks.
- Lists: `{for x in xs { <li key=...>...</li> }}` (a statement slot) or
  `{[<li key=...>...</li> for x in xs]}`. `.map()` is E1030.
- `className` is idiomatic, though the tutorials also use `class`. `style`
  takes a dict: `style={{"color": "red"}}`. Spread props with `{**props}`.
- A JSX comment is `{#* ... *#}`. An empty `{}` is a parse error.
- Use `len(result.reports)`, not `.length` (E1030).
- Use `f"{x:.2f}"`. On the client, `sorted(key=lambda)` fails; use a named key
  function.
- `useParams()["id"]` needs subscript access. Missing values come back as JS
  `undefined`, so use truthy checks rather than `is None`.
- Browser constructors go through `new(URL, s)` or `new(WebSocket, url)`.
- `unsafe_html(x)` renders raw HTML. Use it only with trusted content.

### Calling the server

- **Functions:** `x = await fn(args)`. The client receives hydrated typed
  instances (`obj`, `node`, `enum`, `list[T]`).
- **Walkers:** `import from ...main { AddTask }`, then
  `r = root spawn AddTask(title=t);` (kwargs only), then
  `r.reports[0] if r.reports else []`.
- Count the dots in relative imports from *this* file's folder. Server-side
  code should prefer project-root absolute imports with no dots.
- Reader endpoints are cached for 60s. Calling any writer invalidates the
  cache, and login/logout clears it.

### Routing (pick ONE system)

**File-based** (recommended):

- `pages/index.jac` maps to `/`, `pages/users/[id].jac` to `/users/:id`, and
  `pages/[...notFound].jac` is the catch-all.
- `pages/(group)/x.jac` adds no URL segment.
- Page exports return `JsxPage`. Layouts return `JsxLayout` and render
  `<Outlet/>`.
- Pages in the `(auth)/` group are **auto-protected**. Set the redirect with
  `[client.routing] auth_redirect`. Don't put a `layout.jac` inside `(auth)/`;
  it collides with the root layout.
- ⚠ `main.jac` must then export `def:pub app(children: any) -> JsxElement { <>{children}</> }`.
  A no-argument `app` silently drops every route.

**Manual:** use `Router`, `Routes`, `Route`, `Link`, `Navigate`, `Outlet` and
`AuthGuard` from `@jac/runtime`, with a no-argument `app()`.

**Hooks:** `useNavigate()` (`nav("/x")`, `nav(-1)`), `useLocation()`,
`useParams()`. There's no `useSearchParams`; use `new(URLSearchParams, loc.search)`.

### Auth (client)

Import from `@jac/runtime`:

- `await jacSignup(u, p)` returns a result with `.success`/`.error`. It does
  **not** log the user in.
- `await jacLogin(u, p)` returns a `bool`.
- `jacLogout()` and `jacIsLoggedIn()` are sync. Don't `await` them.
- Signup is **three awaited steps**: signup, then login, then the first
  `:protect` call.
- Pre-declare variables that hold `await` results (`ok: bool = False;`).

### Styling and npm

- Global CSS: import it once in `main.jac`.
- Scoped CSS: put `Comp.style.css` beside `Comp.jac`.
- Tailwind v4: `jac install --npm --dev tailwindcss @tailwindcss/vite`, then in
  `jac.toml` set
  `[client.vite] plugins=["tailwindcss()"] lib_imports=["import tailwindcss from '@tailwindcss/vite'"]`.
- shadcn: `jac create --use jac-shadcn`, `jac install --shadcn button card`, and
  `jac retheme --theme ...`.
- npm packages go in `[dependencies.npm]` or are added with `jac install --npm`.
- Existing `.tsx` files can be imported, but don't author new ones.

### Client config (`jac.toml`)

| Setting | Purpose |
|---|---|
| `[client.app_meta_data] title/description` | page `<head>` metadata |
| `[client.api] base_url` | point the client at a separate API host |
| `[client.pwa]` | make the web build a PWA |
| `[client.paths]` | import aliases |
| `[client.vite.define]` | build-time constants |

---

## 10. byLLM (AI)

```jac
enum Priority { LOW, MEDIUM, HIGH }
sem Priority.HIGH = "Needs attention within the hour";

obj Ingredient { has name: str, cost: float, carby: bool; }
sem Ingredient.cost = "Estimated cost in USD";

def classify(ticket: str) -> Priority by llm();
def plan(meal: str) -> list[Ingredient] by llm(temperature=0.2);
sem plan = "Generate a shopping list for the described meal.";
sem plan.meal = "Free-text meal description";

def get_weather(city: str) -> str { return "sunny"; }
sem get_weather = "Current weather for a city.";
def agent(q: str) -> str by llm(tools=[get_weather], max_react_iterations=5);  # ReAct auto

glob history: list[dict[str, any]] = [];
def chat(msg: str) -> str by llm(conversation=history, system_prompt="Be terse.");
def story(topic: str) -> str by llm(stream=True);      # generator; str return only
```

### Model configuration

`llm` is ambient. Configure it project-wide:

```toml
[byllm.model]
default_model = "anthropic/claude-sonnet-4-6"   # any LiteLLM id; env key ANTHROPIC_API_KEY
# "gpt-4o-mini" (OPENAI_API_KEY), "gemini/gemini-2.5-flash" (free tier), "ollama/llama3.2:1b", "local:gemma-4-e4b"
[byllm.call_params]
temperature = 0.2
max_output_retries = 3
```

- The model can be overridden per shell with `BYLLM_DEFAULT_MODEL=...`, or per
  file with `glob llm = Model(model_name="...")` (after
  `import from jaclang.byllm.lib { Model }`).
- Any glob that holds a `Model` works: `by fast()`.
- For fallback or key rotation, use
  `ModelPool(models=[...], strategy="fallback" | "simple-shuffle")`.
- Run `jac install` after adding `[byllm]` to pull in litellm. Local models
  need `jac install 'byllm[local]'`.

### Semantics

- The prompt is built from the function and parameter names, the types, the
  `sem` strings, and the object's fields (for method `by llm`).
- Use `sem`, not docstrings. The reference says docstrings aren't in the
  prompt, though several tutorials rely on them for tools, so write both for
  tools.
- A typed return value is validated. Malformed output is retried
  `max_output_retries` times, then raises `OutputConversionError` (read the
  output with `getattr(e, "raw_output", "")`).
- Errors derive from `ByLLMError`: `AuthenticationError`, `RateLimitError`,
  `ModelNotFoundError`, `OutputConversionError`, `ConfigurationError`.
- LLM return types should be `obj`, not `node`. Copy the fields into a node to
  persist them.
- `Image("path|url|bytes")` and `Video(path=, fps=)` work as inputs. An `Image`
  *return* makes it an image-generation call (for example with `dall-e-3`).
- MCP tools: `McpClient(command="jac", args=["mcp"]).get_tools()` or
  `McpClient(url=...)`.
- Other options: `on_iteration` hook, parallel tools
  (`parallelize=True`, `mark_serialize`), auto-compaction, telemetry
  (`/admin/llm/telemetry/*` when serving).
- `jac check` doesn't validate `by llm(...)` keyword names. A typo only fails
  at runtime.

### Testing without keys

```jac
import from jaclang.byllm.lib { MockLLM }
glob llm = MockLLM(outputs=[Priority.HIGH]);   # one output consumed per model call, in order
test "mocked" {
    assert classify("db down") == Priority.HIGH;
    assert "db down" in str(llm.sent("messages")[0]);
}
```

---

## 11. Testing

- `test "name" { assert ...; }` blocks run only under `jac test`. Each test
  runs in parallel, isolated workers with a fresh in-memory graph, but the root
  *persists between runs*, so assert on your own fixtures rather than totals.
- Ambient helpers: ``with testraises(ValueError[, `match="..."]) as ei { }``,
  `testskip("why")`, and `testfail("why")`. There's no pytest.
- Don't name files `test_*.jac`. Use `x_tests.jac`, or a `mod.test.jac` annex
  run via `jac test mod.jac`.
- Endpoint tests: `JacTestClient.from_file("app.jac", base_path=tempfile.mkdtemp())`,
  then `.register_user`, `.post("/walker/X", json={...})`, and `.json()["reports"]`.
- Parametrized tests: `import from jaclang.testing.test { parametrize }`.
- `-t` selects a test by name; `-f` filters files.

---

## 12. Python interop and concurrency

- `import numpy as np;` or `import from sklearn.x { Y }` work directly, as do
  local `.py` files. Add a package to the project with `jac install <pkg>`,
  which records it in `jac.toml` and installs it into `.jac/venv`. Get stubs
  with `jac install types-requests`.
- Python can import `.jac` modules through the import hook. `jaclang.lib`
  exposes `spawn`, `connect`, and `root()` (it's a function there).
  `jac tool jac2py f.jac` shows the equivalent Python.
- Use `class` rather than `obj` when subclassing Python types whose metaclass
  reads class attributes (Pygments, ORMs). `::py::` holds verbatim legacy code.
- Concurrency: launch everything with `flow` first, then `wait` for each
  (`futures=[flow f(x) for x in xs]; [wait f for f in futures]`). This is
  thread-based. `async`/`await` is asyncio and needs `asyncio.run(...)` from
  `with entry`. Declare async walkers with `async walker W` and call them with
  `await (root spawn W())`.

---

## 13. `jac.toml` cheat sheet

```toml
[project]
name = "myapp"
kind = "web-app"          # cli|service|web-app|web-static|desktop|mobile|...
entry-point = "main"      # dotted module name (not "main.jac")

[dependencies]            # PyPI; prefer `jac install <pkg>`
requests = "~=2.32"

[dependencies.npm]
react = "^19.2.0"
[dependencies.npm.dev]
vite = "^6.4.1"

[serve]
port = 8000
[serve.auth]
secret = "${JAC_SERVE_AUTH_SECRET}"   # ${VAR}, ${VAR:-default}, ${VAR:?error}

[byllm.model]
default_model = "anthropic/claude-sonnet-4-6"

[scale]                   # enables serving/scale capability
[client]                  # enables client capability

[placement.pins]
"main.API_KEY" = "server"

[test]
directory = "tests"

[check]
enforce_access = true     # visibility violations → errors
[check.lint]
select = ["default"]
```

- Workspaces use `[apps.<name>] kind=... entry-point="web.main"`, which can't
  be combined with `[project] kind/entry-point`.
- Profiles live in `[environments.<name>]`. Select one with
  `JAC_PROFILE=prod` or `--profile prod`.
- Hyphen versus underscore spelling is per key and is silently ignored when
  wrong: `entry-point`, `default-app`, `jac-version`, but `fail_fast`,
  `on_conflict`.
- `[plugins.*]` tables no longer exist; use the top-level `[byllm]`, `[scale]`
  and `[client]`.

---

## 14. Docs contradictions and stale spots

When sources disagree, trust the ones marked ✅.

| Topic | Stale / wrong source | Current truth |
|---|---|---|
| Endpoint auth tags | MCP "pitfalls" doc, `jac-sv-persistence` skill, websocket notes, Scale overview: "`:priv` = JWT-auth endpoint", "omit `:pub` to require auth", "plain walker is public" | ✅ access-modifiers ref + breaking changes (0.37.22): `:protect` = auth, plain/`:priv` = **not served** |
| Resetting data | OSP tutorial, AI tutorials, testing ref: `jac clean --all` | ✅ FAQ: `jac clean` doesn't touch Postgres. Use `jac db drop` |
| Inline `"..." by llm` | syntax cheatsheet shows it | ✅ byLLM ref: **not implemented** (runtime `NotImplementedError`) |
| `->_{}` wildcard in typed context blocks | syntax cheatsheet | ✅ OSP ref: not supported |
| `result.reports.length` | MCP pitfalls, jac-client ref | ✅ skills: use `len(result.reports)` (`.length` is E1030 in the checker) |
| `cl def:pub` wording | day-planner tutorial prose | markers removed. Write plain `def:pub` |
| `jac check --placements` | core concepts page | ✅ `jac explain placement` |
| Day planner part 6/7 `--kind web-static` | tutorial | it has a server, so use `--kind web-app` |
| Walker exposure in day planner part 7 prose ("plain walker = public", "uses `:priv`") | tutorial text | code uses `walker:protect` ✅ |
| `jacSignup` result | jac-client ref: `result["success"]` dict | `jac-cl-auth` skill: `SignupResult` with `.success`. Try `.success` first |
| Register returns a token? | HTTP ref / tutorial: no | skill says yes ("verified"). Always call login after signup anyway |
| `(auth)/` protection | jac-client ref: add `(auth)/layout.jac` with AuthGuard | ✅ routing skill: `(auth)/` is **auto-guarded**; a layout inside it collides |
| Scheduler | `jac run --serve main.jac` | only needed if the kind doesn't already serve |
| Docstrings in prompts | tutorials use docstrings on tools | ✅ reference: only `sem` is in the prompt. Write both for tools |
| `perm_grant` vs `grant` | Scale HTTP ref uses `perm_grant` | the OSP ref/skills use ambient `grant`/`revoke` ✅. Both documented |

---

## 15. Hackathon playbook

1. **Set up** (about 5 minutes):
   - Install jac.
   - Run `jac guide --export .claude/skills` in the project.
   - Run `claude mcp add jac -- jac mcp`, so Claude writes *and* validates Jac.
   - Set `ANTHROPIC_API_KEY`, or use `gemini/gemini-2.5-flash` for a free tier.
2. **Scaffold:** `jac create app --kind web-app` (or `--use jac-shadcn` for
   polished UI), then `cd app && jac run --dev`.
3. **Backend:** use `node`s for domain data and `def:protect` functions for
   per-user CRUD. Use `walker:protect` only where you traverse, such as
   recommendations, agent memory or multi-hop queries. `by llm()` provides the
   AI features.
4. **Frontend:** use a single `app` component until you need pages, then
   switch to file-based routing (and remember `app(children)`).
5. **Demo polish:** show `/graph` (a live graph visualizer, good for judges) and
   `/docs` (Swagger).
6. **The loop:** `jac check` after every edit, then `jac test`, then check in
   the browser with `jac browse`.
7. **When stuck:** start with the first diagnostic, then run `jac guide <name>`
   (the diagnostic prints which), `jac db status`, and `jac clean --cache`.

**The "signature move" judges will like:** agent memory as a graph hung off
`root`, with a walker that traverses it, and `visit [-->] by llm(intent=...)`
for LLM-guided traversal. It shows OSP and meaning types together.

---

## 16. Where things live in the docs

| Topic | Doc (under `jac/jaclang/cli/docs/`) | `jac guide` name |
|---|---|---|
| Syntax, one page | `reference/language/syntax-cheatsheet.md` | `jac-core-cheatsheet` |
| OSP full spec | `reference/language/osp.md` | `jac-walker-patterns`, `jac-node-edge-patterns` |
| Types | `reference/language/types-and-values.md` | `jac-types` |
| Access modifiers | `reference/language/access-modifiers.md` | `jac-sv-auth` |
| byLLM | `reference/plugins/byllm.md` | `jac-by-llm` |
| Full-stack client | `reference/plugins/jac-client.md` | `jac-cl-*`, `jac-fullstack-patterns` |
| Serving / auth / webhooks / ws | `reference/plugins/jac-scale-http.md` | `jac-sv-endpoints` |
| Persistence / schema | `reference/persistence.md` | `jac-sv-persistence`, `jac-sv-multi-user` |
| CLI | `reference/cli/index.md` | — |
| jac.toml | `reference/config/index.md` | `jac-config` |
| Testing | `reference/testing.md` | `jac-testing` |
| Error codes | `reference/diagnostics.md` | — |
| Breaking changes | `community/breaking-changes.md` | — |
| End-to-end tutorial | `tutorials/first-app/day-planner-0[1-7]*.md` | — |
| AI-agent pitfalls list | `jac/jaclang/cli/mcp/content/pitfalls.md` (partly stale) | — |
