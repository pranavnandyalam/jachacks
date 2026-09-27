"""The target app's LIVE source (HEAD). Every line Blue has changed is highlighted
and tagged with the round that introduced it; the newest patch is brightest."""

def:pub CodeView(source: str, version: int, origins: list[int]) -> JsxElement {
    lines: list[str] = source.split(chr(10));
    latest: int = max(origins) if len(origins) > 0 else 0;

    # When a new patch lands, scroll the code panel to its first line (back to
    # the top when there is no patch yet, e.g. after a reset).
    can with [latest, version] entry {
        box: any = document.querySelector(".code-body");  # jac:ignore[W1037]
        first: any = document.querySelector(".cl-latest");  # jac:ignore[W1037]
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
                <CodeLine key={str(i)} n={i + 1} text={ln} origin={origins[i] if i < len(origins) else 0} latest={latest}/>
            }}
        </pre>
    </div>
}

def:pub CodeLine(n: int, text: str, origin: int, latest: int) -> JsxElement {
    cls: str = "cl";
    if origin > 0 {
        cls = "cl cl-new cl-latest" if origin == latest else "cl cl-new";
    }
    <div className={cls}>
        <span className="tagcol">{("R" + str(origin)) if origin > 0 else ""}</span>
        <span className="ln">{str(n)}</span>
        <span className="lt">{text if text else " "}</span>
    </div>
}
