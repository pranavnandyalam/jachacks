"""The evolving codebase: a chain of CodeVersion nodes on the graph.

Version 0 is the seed (the original vulnerable source, read from disk once).
Each accepted Blue patch appends a new version. The whole history is the
evidence that security evolved -- every diff is replayable from the graph.
"""

import os;
import difflib;

glob TARGET_SOURCE: str = "target/app.py";

node Codebase {
    has name: str = "target",
        head: int = 0;
}

node CodeVersion {
    has version: int,
        source: str,
        author: str,
        summary: str = "",
        diff: str = "";
}

edge Revision: Codebase --> CodeVersion {}

def unified_diff(old: str, new: str) -> str {
    lines = difflib.unified_diff(
        old.splitlines(), new.splitlines(), fromfile="before", tofile="after", lineterm=""
    );
    return "\n".join(lines);
}

"""Get-or-create the Codebase, seeded from the on-disk target source at v0."""
def codebase -> Codebase {
    found = [root -->[?:Codebase]];
    if found {
        return found[0];
    }
    cb = root ++> Codebase(name="target", head=0);
    seed = open(TARGET_SOURCE).read();
    cb ++> CodeVersion(version=0, source=seed, author="seed", summary="original vibecoded app");
    return cb;
}

def all_versions -> list[CodeVersion] {
    return [codebase() -->[?:CodeVersion]];
}

def version_at(n: int) -> CodeVersion | None {
    vs = [v for v in all_versions() if v.version == n];
    return vs[0] if vs else None;
}

"""The current live source -- what Red attacks and Blue edits this round."""
def current_source -> str {
    cb = codebase();
    v = version_at(cb.head);
    return v.source if v is not None else "";
}

"""Append a new accepted version and advance HEAD. Returns the new version no."""
def commit_version(source: str, author: str, summary: str) -> int {
    cb = codebase();
    old = current_source();
    n = cb.head + 1;
    cb ++> CodeVersion(
        version=n, source=source, author=author,
        summary=summary, diff=unified_diff(old, source)
    );
    cb.head = n;
    return n;
}

"""Wipe all versions and reseed at v0 -- for a fresh game."""
def reset_codebase -> int {
    vs = all_versions();
    n = len(vs);
    for v in vs {
        del v;
    }
    cbs = [root -->[?:Codebase]];
    for c in cbs {
        del c;
    }
    codebase();
    return n;
}

test "codebase seeds v0 from disk and reads current source" {
    reset_codebase();
    assert codebase().head == 0;
    assert "Flask" in current_source();
    assert len(all_versions()) == 1;
}

test "commit_version advances head and records a diff" {
    reset_codebase();
    base = current_source();
    patched = base.replace("DEBUG_MODE\"] = True", "DEBUG_MODE\"] = False");
    n = commit_version(patched, "blue", "disable debug");
    assert n == 1;
    assert codebase().head == 1;
    assert "DEBUG_MODE" in current_source();
    assert current_source() == patched;
    v = version_at(1);
    assert v is not None;
    assert v.author == "blue";
    assert "-" in v.diff;
    assert "+" in v.diff;
}

test "reset_codebase returns to a single v0" {
    reset_codebase();
    commit_version(current_source() + "\n# x", "blue", "noop");
    assert len(all_versions()) == 2;
    reset_codebase();
    assert len(all_versions()) == 1;
    assert codebase().head == 0;
}
