"""The app's current source. Every line Blue changed is tagged with its round;
the selected round's lines are highlighted and scrolled into view."""

def:pub CodeView(source: str, version: int, origins: list[int], selected: int) -> JsxElement {
    lines: list[str] = source.split(chr(10));

    can with [selected, version] entry {
        box: any = document.querySelector(".code-scroll");  # jac:ignore[W1037]
        first: any = document.querySelector(".ln-row.is-selected");  # jac:ignore[W1037]
        if box and first {
            box.scrollTop = first.offsetTop - box.clientHeight / 3;
        } elif box {
            box.scrollTop = 0;
        }
    }

    <section className="code" aria-label="Current source code">
        <header className="panel-head">
            <h2 className="panel-title">{"target/app.py"}</h2>
            <span className="panel-note">
                {"Original version, before any fixes" if version == 0 else "Version " + str(version) + ", after " + str(version) + (" fix" if version == 1 else " fixes")}
            </span>
        </header>
        <div className="code-scroll">
            <pre className="code-pre">
                {for (i, ln) in enumerate(lines) {
                    <CodeLine key={str(i)} n={i + 1} text={ln} origin={origins[i] if i < len(origins) else 0} selected={selected}/>
                }}
            </pre>
        </div>
    </section>
}

def:pub CodeLine(n: int, text: str, origin: int, selected: int) -> JsxElement {
    cls: str = "ln-row";
    if origin > 0 {
        cls = "ln-row is-changed" + (" is-selected" if origin == selected else "");
    }
    <div className={cls}>
        <span className="ln-round">{("R" + str(origin)) if origin > 0 else ""}</span>
        <span className="ln-num">{str(n)}</span>
        <span className="ln-text">{text if text else " "}</span>
    </div>
}
