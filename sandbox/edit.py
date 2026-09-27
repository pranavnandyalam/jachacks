# Structural single-endpoint editing helpers.
#
#   edit.py resolve <source_file> <method> <path>
#       -> {"func": "<view function name>"}  (which handler serves this request)
#
#   edit.py splice <current_file> <patched_file> <func_name>
#       -> {"source": "<current with ONLY func_name replaced by the patched version>"}
#
# Splicing guarantees Blue can only change the one endpoint it was asked to fix:
# any other edits in Blue's full-file rewrite are discarded.

import ast
import importlib.util
import json
import os
import sys


def resolve(source_file: str, method: str, path: str) -> dict:
    os.environ.setdefault("RQ_FLAG", "x")
    os.environ.setdefault("RQ_TOKENS", "{}")
    spec = importlib.util.spec_from_file_location("rq_resolve", source_file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    app = getattr(module, "app")
    adapter = app.url_map.bind("localhost")
    try:
        endpoint, _ = adapter.match(path, method=method.upper())
    except Exception as exc:
        return {"func": "", "error": f"no route for {method} {path}: {exc}"}
    return {"func": endpoint}


# A fixed Flask handler only needs plain request logic (ifs, current_user(),
# jsonify, dict lookups). Anything that reaches the host, the interpreter, or
# attribute internals is refused outright -- a deny-by-shape rule, so there is
# no clever spelling that slips past a name blocklist.
FORBIDDEN_NAMES = {"os", "sys", "open", "getattr", "setattr", "delattr", "eval",
                   "exec", "compile", "globals", "locals", "vars", "input",
                   "breakpoint", "memoryview", "subprocess", "socket", "shutil",
                   "importlib", "builtins", "ctypes", "pty", "pathlib", "io"}


def _scan_dangerous(func_node) -> str:
    """Reason string if the patched handler does anything beyond plain request
    logic, else ''."""
    for n in ast.walk(func_node):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            return "disallowed: import inside handler"
        if isinstance(n, (ast.Global, ast.Nonlocal)):
            return "disallowed: global/nonlocal"
        if isinstance(n, ast.Name) and (n.id in FORBIDDEN_NAMES or n.id.startswith("__")):
            return f"disallowed name: {n.id}"
        if isinstance(n, ast.Attribute) and n.attr.startswith("_"):
            return f"disallowed attribute: .{n.attr}"
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and "__" in n.value:
            return "disallowed: dunder string"
    return ""


def _func_span(source: str, func_name: str):
    """Return (start_line, end_line) 1-indexed inclusive for a top-level function
    named func_name, including its decorators. None if not found."""
    tree = ast.parse(source)
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == func_name:
            start = node.lineno
            if node.decorator_list:
                start = min(d.lineno for d in node.decorator_list)
            return start, node.end_lineno
    return None


def splice(current_file: str, patched_file: str, func_name: str) -> dict:
    current = open(current_file).read()
    patched = open(patched_file).read()
    try:
        cur_span = _func_span(current, func_name)
        new_span = _func_span(patched, func_name)
    except SyntaxError as exc:
        return {"source": "", "error": f"parse error: {exc}"}
    if cur_span is None:
        return {"source": "", "error": f"{func_name} not found in current source"}
    if new_span is None:
        return {"source": "", "error": f"{func_name} not found in patched source"}

    # Reject a patch whose replacement function uses a disallowed operation.
    for node in ast.parse(patched).body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == func_name:
            danger = _scan_dangerous(node)
            if danger:
                return {"source": "", "error": f"blocked: {danger}"}
            break

    cur_lines = current.splitlines()
    new_lines = patched.splitlines()
    replacement = new_lines[new_span[0] - 1:new_span[1]]
    spliced = cur_lines[:cur_span[0] - 1] + replacement + cur_lines[cur_span[1]:]
    return {"source": "\n".join(spliced) + "\n"}


def main() -> None:
    cmd = sys.argv[1]
    if cmd == "resolve":
        print(json.dumps(resolve(sys.argv[2], sys.argv[3], sys.argv[4])))
    elif cmd == "splice":
        print(json.dumps(splice(sys.argv[2], sys.argv[3], sys.argv[4])))
    else:
        print(json.dumps({"error": f"unknown command {cmd}"}))


if __name__ == "__main__":
    main()
