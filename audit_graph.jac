"""The audit as a real graph. Each pass hangs its story off the Auditor as
typed nodes and edges: who found what (Red -Discovered-> Vulnerability), where
it lives (Vulnerability -LivesIn-> SourceFile), what Blue tried and how the
referee ruled (Blue -Wrote-> PatchAttempt <-Judged- Referee), what a patch
closed (PatchAttempt -Closes-> Vulnerability), and how every file evolved
(SourceFile -VersionOf-> FileVersion -Next-> FileVersion). The dashboard still
reads its compact Pass records; this graph is the full record."""

import hashlib;
import from codecheck { find_handler }
import from jaclang.runtime.archetype { NodeArchetype }

node Agent {
    has role: str,
        job: str;
}

node SourceFile {
    has path: str;
}

node FileVersion {
    has path: str,
        version: int,
        lines: int,
        digest: str;
}

node Vulnerability {
    has route: str,
        sender: str,
        kind: str,
        why: str,
        status: str;
}

node PatchAttempt {
    has pass_n: int,
        attempt: int,
        verdict: str,
        reason: str,
        summary: str;
}

edge Staffs: NodeArchetype --> Agent {}
edge Tracks: NodeArchetype --> SourceFile {}
edge VersionOf: SourceFile --> FileVersion {}
edge Next: FileVersion --> FileVersion {}
edge Found: NodeArchetype --> Vulnerability {}
edge Discovered: Agent --> Vulnerability {}
edge LivesIn: Vulnerability --> SourceFile {}
edge Attempted: NodeArchetype --> PatchAttempt {}
edge Wrote: Agent --> PatchAttempt {}
edge Judged: Agent --> PatchAttempt {
    has verdict: str = "";
}
edge Closes: PatchAttempt --> Vulnerability {}
edge Produced: PatchAttempt --> FileVersion {}

glob AGENT_JOBS: dict[str, str] = {
    "Red": "attacker: reads the code and finds requests that leak data or break the rules",
    "Blue": "defender: patches the code to close the holes Red found",
    "Referee": "judge: confirms each hole is real and accepts or rejects every patch"
};

def _digest(body: str) -> str {
    return hashlib.sha256(body.encode()).hexdigest()[:10];
}

def _version(path: str, body: str, v: int) -> FileVersion {
    return FileVersion(path=path, version=v, lines=len(body.splitlines()), digest=_digest(body));
}

"""Delete everything hanging off the Auditor (passes, agents, files, findings,
attempts) so a reseed starts from a clean graph."""
def graph_clear(auditor: NodeArchetype) -> int {
    seen: list[NodeArchetype] = [];
    frontier: list[NodeArchetype] = [auditor];
    while frontier {
        nxt: list[NodeArchetype] = [];
        for n in frontier {
            for m in [n -->] {
                if m not in seen {
                    seen = seen + [m];
                    nxt = nxt + [m];
                }
            }
        }
        frontier = nxt;
    }
    for m in seen {
        del m;
    }
    return len(seen);
}

"""Red, Blue and the Referee as nodes under the Auditor (get-or-create)."""
def graph_agents(auditor: NodeArchetype) -> dict[str, Agent] {
    out: dict[str, Agent] = {};
    for ag in [auditor ->:Staffs:->[?:Agent]] {
        out[ag.role] = ag;
    }
    for (role, job) in AGENT_JOBS.items() {
        if role not in out {
            ag = Agent(role=role, job=job);
            auditor +>:Staffs:+> ag;
            out[role] = ag;
        }
    }
    return out;
}

"""A SourceFile per target file, each with its v0 FileVersion."""
def graph_seed_files(auditor: NodeArchetype, files: dict[str, str]) -> None {
    graph_agents(auditor);
    for (path, body) in files.items() {
        sf = SourceFile(path=path);
        auditor +>:Tracks:+> sf;
        sf +>:VersionOf:+> _version(path, body, 0);
    }
}

def _latest(sf: SourceFile) -> FileVersion | None {
    best: FileVersion | None = None;
    for fv in [sf ->:VersionOf:->[?:FileVersion]] {
        if best is None or fv.version > best.version {
            best = fv;
        }
    }
    return best;
}

"""Which tracked file holds the handler for METHOD PATH ("" if unknown)."""
def _home(files: dict[str, str], method: str, path: str) -> str {
    h = find_handler(files, method, path);
    return h.split(":\n", 1)[0] if h else "";
}

"""Record one pass as graph structure. `vulns` are dicts with method, path,
as_user, vuln_class, why, closed; `attempts` are dicts with attempt, verdict,
reason, summary, changed (paths)."""
def graph_record_pass(auditor: NodeArchetype, pass_node: NodeArchetype, n: int, before: dict[str, str], after: dict[str, str], vulns: list[dict[str, any]], attempts: list[dict[str, any]], reviewed: bool) -> None {
    agents = graph_agents(auditor);
    tracked: dict[str, SourceFile] = {};
    for sf in [auditor ->:Tracks:->[?:SourceFile]] {
        tracked[sf.path] = sf;
    }
    vnodes: list[Vulnerability] = [];
    for v in vulns {
        status = "reviewed" if reviewed else ("fixed" if v["closed"] else "open");
        vn = Vulnerability(route=f"{v['method']} {v['path']}", sender=v["as_user"] or "anonymous",
                           kind=v["vuln_class"], why=v["why"], status=status);
        pass_node +>:Found:+> vn;
        agents["Red"] +>:Discovered:+> vn;
        home = _home(before, v["method"], v["path"]);
        if home in tracked {
            vn +>:LivesIn:+> tracked[home];
        }
        vnodes = vnodes + [vn];
    }
    for at in attempts {
        pa = PatchAttempt(pass_n=n, attempt=at["attempt"], verdict=at["verdict"],
                          reason=at["reason"], summary=at["summary"]);
        pass_node +>:Attempted:+> pa;
        agents["Blue"] +>:Wrote:+> pa;
        agents["Referee"] +>:Judged(verdict=at["verdict"]):+> pa;
        if at["verdict"] == "accepted" {
            for (vn, v) in zip(vnodes, vulns) {
                if v["closed"] {
                    pa +>:Closes:+> vn;
                }
            }
            for path in at["changed"] {
                if path in tracked and path in after {
                    prev = _latest(tracked[path]);
                    fv = _version(path, after[path], (prev.version + 1) if prev else 1);
                    tracked[path] +>:VersionOf:+> fv;
                    if prev {
                        prev +>:Next:+> fv;
                    }
                    pa +>:Produced:+> fv;
                }
            }
        }
    }
}
