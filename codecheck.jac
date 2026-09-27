"""Language-agnostic code mechanics for apps we can't run in-process (Go,
TypeScript, FastAPI): apply Blue's small find/replace edits to a file map, and
syntax-check the result with each language's own parser. No LLM here."""

import os;
import shutil;
import subprocess;
import sys;
import tempfile;

glob TS_CHECKER: str = os.path.abspath("tools/syntax_check.js");

obj EditResult {
    has files: dict[str, str],
        applied: int,
        missed: list[str];
}

"""Leading whitespace of a line."""
def _indent(line: str) -> str {
    return line[:len(line) - len(line.lstrip())];
}

"""Shift every non-blank line of `text` from indent `old_ind` to `new_ind`."""
def _reindent(text: str, old_ind: str, new_ind: str) -> str {
    out: list[str] = [];
    for line in text.split("\n") {
        if not line.strip() {
            out = out + [line];
        } elif line.startswith(old_ind) {
            out = out + [new_ind + line[len(old_ind):]];
        } else {
            out = out + [new_ind + line.lstrip()];
        }
    }
    return "\n".join(out);
}

"""Replace the first occurrence of `needle` in `body` with `repl`. Tries an exact
match first, then a line-by-line match that ignores indentation and trailing
spaces (models often re-indent). Returns "" when the snippet isn't there."""
def replace_snippet(body: str, needle: str, repl: str) -> str {
    if not needle.strip() {
        return "";
    }
    if needle in body {
        return body.replace(needle, repl, 1);
    }
    want_lines = needle.strip("\n").split("\n");
    want = [l.strip() for l in want_lines];
    lines = body.split("\n");
    n = len(want);
    for i in range(0, len(lines) - n + 1) {
        window = [l.strip() for l in lines[i:i + n]];
        if window == want {
            fixed = _reindent(repl.strip("\n"), _indent(want_lines[0]), _indent(lines[i]));
            return "\n".join(lines[:i] + [fixed] + lines[i + n:]);
        }
    }
    return "";
}

"""Resolve Blue's path to a real key: exact, then by basename, then (when the
app has a single backend file) that file."""
def resolve_path(files: dict[str, str], path: str, backend: list[str]) -> str {
    if path in files {
        return path;
    }
    for k in files.keys() {
        if os.path.basename(k) == os.path.basename(path) {
            return k;
        }
    }
    if len(backend) == 1 {
        return backend[0];
    }
    return "";
}

"""Apply (path, find, replace) edits to a copy of `files`."""
def apply_code_edits(files: dict[str, str], edits: list[tuple[str, str, str]], backend: list[str]) -> EditResult {
    out: dict[str, str] = dict(files);
    applied = 0;
    missed: list[str] = [];
    for (path, find, repl) in edits {
        key = resolve_path(out, path, backend);
        new_body = replace_snippet(out[key], find, repl) if key else "";
        if new_body {
            out[key] = new_body;
            applied += 1;
        } else {
            missed = missed + [path];
        }
    }
    return EditResult(files=out, applied=applied, missed=missed);
}

"""The syntax checker for a file, by extension; [] if we have none -- including
when its tool isn't installed (e.g. no gofmt/node on a hosting box), so a
missing checker skips the check instead of rejecting every patch."""
def _checker(ext: str, tmp: str) -> list[str] {
    cmd: list[str] = [];
    if ext == ".py" {
        cmd = [sys.executable, "-m", "py_compile", tmp];
    } elif ext == ".go" {
        cmd = ["gofmt", "-e", "-l", tmp];
    } elif ext in [".ts", ".tsx", ".js", ".mjs"] and os.path.isfile(os.path.join(os.path.dirname(TS_CHECKER), "node_modules", "typescript", "package.json")) {
        cmd = ["node", TS_CHECKER, tmp];
    }
    if cmd and not shutil.which(cmd[0]) {
        print(f"[codecheck] no {cmd[0]} on this machine; skipping {ext} syntax check");
        return [];
    }
    return cmd;
}

"""Syntax-check one file with its language's parser. "" if it parses (or we
have no checker for it), else a short error message."""
def syntax_error(path: str, body: str) -> str {
    ext = os.path.splitext(path)[1];
    d = tempfile.mkdtemp(prefix="rq-check-");
    tmp = os.path.join(d, "check" + ext);
    msg = "";
    try {
        with open(tmp, "w") as fh {
            fh.write(body);
        }
        cmd = _checker(ext, tmp);
        if cmd {
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30);
            if proc.returncode != 0 {
                detail = (proc.stdout + proc.stderr).replace(tmp, path).strip();
                msg = path + ": " + detail[:300];
            }
        }
    } except Exception as e {
        msg = path + ": checker failed: " + str(e);
    }
    shutil.rmtree(d, ignore_errors=True);
    return msg;
}

"""Syntax-check every file in `paths`; "" if all parse, else the errors."""
def syntax_errors(files: dict[str, str], paths: list[str]) -> str {
    errs: list[str] = [];
    for p in paths {
        e = syntax_error(p, files[p]);
        if e {
            errs = errs + [e];
        }
    }
    return "\n".join(errs);
}

test "replace_snippet: exact, re-indented, and missing" {
    body = "def f():\n    if x:\n        return 1\n    return 2\n";
    assert replace_snippet(body, "        return 1", "        return 3") == body.replace("return 1", "return 3");
    # model dropped the indentation: still lands, re-indented to the file's
    out = replace_snippet(body, "if x:\nreturn 1", "if x and y:\n    return 1");
    assert "    if x and y:\n        return 1" in out;
    assert replace_snippet(body, "nope", "x") == "";
}

test "apply_code_edits resolves paths and counts misses" {
    files = {"src/server.ts": "const a = 1;\n", "public/app.js": "x();\n"};
    res = apply_code_edits(files, [("server.ts", "const a = 1;", "const a = 2;"), ("src/server.ts", "zzz", "y")], ["src/server.ts"]);
    assert res.applied == 1;
    assert res.files["src/server.ts"] == "const a = 2;\n";
    assert files["src/server.ts"] == "const a = 1;\n";  # original untouched
    assert len(res.missed) == 1;
}

test "syntax_error catches broken Python, Go and TypeScript" {
    assert syntax_error("a.py", "x = 1\n") == "";
    assert syntax_error("a.py", "def (:\n") != "";
    assert syntax_error("main.go", "package main\nfunc main() {}\n") == "";
    assert syntax_error("main.go", "package main\nfunc main() {\n") != "";
    assert syntax_error("s.ts", "const x: number = 1;\n") == "";
    assert syntax_error("s.ts", "const x = {;\n") != "";
    assert syntax_error("style.css", "anything") == "";
}
