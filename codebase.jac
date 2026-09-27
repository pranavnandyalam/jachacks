"""The evolving codebase: a chain of CodeVersion nodes on the graph.

Version 0 is the seed (the original vulnerable source, read from disk once).
Each accepted Blue patch appends a new version. The whole history is the
evidence that security evolved -- every diff is replayable from the graph.
"""

import os;
import difflib;
import from config { target_source_path }

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
    seed = open(target_source_path()).read();
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

def _version_no(v: CodeVersion) -> int {
    return v.version;
}

"""For each line of the current source, the version that introduced it (0 = the
original). Traced version by version with difflib, so a line keeps its origin
even as later patches shift it around."""
def line_origins -> list[int] {
    vs = sorted(all_versions(), key=_version_no);
    if not vs {
        return [];
    }
    prev = vs[0].source.splitlines();
    origins = [0 for _ in prev];
    for v in vs[1:] {
        cur = v.source.splitlines();
        nxt = [v.version for _ in cur];
        sm = difflib.SequenceMatcher(None, prev, cur, autojunk=False);
        for (tag, i1, i2, j1, j2) in sm.get_opcodes() {
            if tag == "equal" {
                for k in range(i2 - i1) {
                    nxt[j1 + k] = origins[i1 + k];
                }
            }
        }
        origins = nxt;
        prev = cur;
    }
    return origins;
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

test "line_origins tags each line with the version that introduced it" {
    reset_codebase();
    seed = current_source();
    v1 = seed.replace("    # TODO: check ownership\n", "    if inv[\"owner\"] != user[\"name\"]:\n        return jsonify({}), 403\n");
    commit_version(v1, "blue", "idor");
    v2 = "# new header line\n" + v1;
    commit_version(v2, "blue", "header");
    o = line_origins();
    lines = current_source().splitlines();
    assert len(o) == len(lines);
    assert o[0] == 2;
    i = lines.index("    if inv[\"owner\"] != user[\"name\"]:");
    assert o[i] == 1;
    assert o[1] == 0;
    reset_codebase();
}
