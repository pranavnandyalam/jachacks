"""The codebase files, with the selected one shown."""

import from ..audit { TargetFile }

def:pub FileViewer(files: list[TargetFile], selected: str, onPick: Callable[[str], None]) -> JsxElement {
    cur: str = "";
    for f in files {
        if f.path == selected {
            cur = f.content;
        }
    }
    <section className="code" aria-label="Codebase">
        <header className="panel-head file-tabs">
            {for (i, f) in enumerate(files) {
                <button key={str(i)} type="button"
                    className={"filetab" + (" is-active" if f.path == selected else "")}
                    onClick={lambda { onPick(f.path); }}>{f.path}</button>
            }}
        </header>
        <div className="code-scroll">
            <pre className="code-pre">
                {for (i, ln) in enumerate(cur.split(chr(10))) {
                    <div key={str(i)} className="ln-row">
                        <span className="ln-num">{str(i + 1)}</span>
                        <span className="ln-text">{ln if ln else " "}</span>
                    </div>
                }}
            </pre>
        </div>
    </section>
}
