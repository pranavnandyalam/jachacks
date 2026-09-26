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
