"""A fix's unified diff, with added and removed lines marked."""

def:pub DiffView(diff: str) -> JsxElement {
    lines: list[str] = [ln for ln in diff.split(chr(10)) if not ln.startswith("---") and not ln.startswith("+++")];
    <pre className="diff">
        {for (i, ln) in enumerate(lines) {
            <div key={str(i)} className={line_class(ln)}>{ln if ln else " "}</div>
        }}
    </pre>
}

def line_class(ln: str) -> str {
    if ln.startswith("@@") {
        return "d-hunk";
    }
    if ln.startswith("+") {
        return "d-add";
    }
    if ln.startswith("-") {
        return "d-del";
    }
    return "d-ctx";
}
