"""The target app's LIVE source (HEAD), with the lines Blue added in its most
recent accepted patch highlighted."""

glob _NL: str = chr(10);

def:pub CodeView(source: str, version: int, lastDiff: str) -> JsxElement {
    lines: list[str] = source.split(_NL);
    fresh: list[int] = added_lines(lastDiff);

    # When a new patch lands, scroll the code panel to Blue's first new line
    # (back to the top when there is no patch yet, e.g. after a reset).
    can with [lastDiff] entry {
        box: any = document.querySelector(".code-body");  # jac:ignore[W1037]
        first: any = document.querySelector(".cl-new");  # jac:ignore[W1037]
        if box and first {
            box.scrollTop = first.offsetTop - box.clientHeight / 3;
        } elif box {
            box.scrollTop = 0;
        }
    }
    <div className="code">
        <div className="code-head">
            <span>{"target/app.py"}</span>
            <span className="code-ver">{"v" + str(version) + (" (original, vulnerable)" if version == 0 else " (patched by Blue)")}</span>
        </div>
        <pre className="code-body">
            {for (i, ln) in enumerate(lines) {
                <div key={str(i)} className={"cl " + ("cl-new" if (i + 1) in fresh else "")}>
                    <span className="ln">{str(i + 1)}</span>
                    <span className="lt">{ln if ln else " "}</span>
                </div>
            }}
        </pre>
    </div>
}

"""New-file line numbers of the '+' lines in a unified diff."""
def added_lines(diff: str) -> list[int] {
    out: list[int] = [];
    cur: int = 0;
    for ln in diff.split(_NL) {
        if ln.startswith("@@") {
            # "@@ -82,7 +82,8 @@" -> new-file hunk starts at 82
            plus: str = ln.split(" ")[2];
            cur = int(plus[1:].split(",")[0]);
        } elif ln.startswith("+") and not ln.startswith("+++") {
            out = out + [cur];
            cur = cur + 1;
        } elif not ln.startswith("-") and cur > 0 {
            cur = cur + 1;
        }
    }
    return out;
}
