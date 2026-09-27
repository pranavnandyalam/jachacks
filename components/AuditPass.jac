"""One audit pass: what Red found and what Blue fixed, with diffs."""

import from ..audit { PassInfo, Finding, FileDiff }
import from .DiffView { DiffView }

def:pub AuditPass(p: PassInfo, onPickFile: Callable[[str], None]) -> JsxElement {
    has showDiff: bool = False;

    clean: bool = p.found == 0;

    def toggle(e: MouseEvent) {
        showDiff = not showDiff;
    }

    <li className="round">
        <div className="round-hit" aria-hidden="true">
            <span className="round-n">{str(p.n)}</span>
        </div>
        <div className="round-body">
            {if clean {
                <div className="step fixed">
                    <p className="step-head">
                        <span className="step-kind">{"Clean"}</span>
                        <span className="step-title">{"This scan found nothing left to fix."}</span>
                    </p>
                </div>
            } else {
                <div className="step found">
                    <p className="step-head">
                        <span className="step-kind">{"Found"}</span>
                        <span className="step-title">{str(p.found) + (" issue" if p.found == 1 else " issues") + " Red could exploit"}</span>
                    </p>
                    <ul className="findings">
                        {for (i, f) in enumerate(p.findings) {
                            <li key={str(i)} className={"finding " + ("ok" if f.closed else "bad")}>
                                <code>{f.method + " " + f.path}</code>
                                <span className="finding-cls">{f.vuln_class}</span>
                                <span className={"finding-state " + ("ok" if f.closed else "bad")}>{"fixed" if f.closed else "still open"}</span>
                            </li>
                        }}
                    </ul>
                </div>
            }}
            {if not clean {
                <div className="step fixed">
                    <p className="step-head">
                        <span className="step-kind">{"Fixed"}</span>
                        <span className="step-title">{p.summary}</span>
                    </p>
                    <p className="verified">
                        {str(p.fixed) + " closed, re-tested; " + ("app still works." if p.health_ok else "WARNING: an app check now fails.")}
                    </p>
                    {if len(p.files_changed) > 0 {
                        <p className="changed-files">
                            {"Changed: "}
                            {for (i, name) in enumerate(p.files_changed) {
                                <button key={str(i)} type="button" className="filechip" onClick={lambda { onPickFile(name); }}>{name}</button>
                            }}
                        </p>
                    }}
                    {if len(p.diffs) > 0 {
                        <button type="button" className="link" onClick={toggle} aria-expanded={showDiff}>
                            {("Hide changes" if showDiff else "Show changes") + " (" + str(len(p.diffs)) + " file" + ("" if len(p.diffs) == 1 else "s") + ")"}
                        </button>
                    }}
                    {if showDiff {
                        <div className="pass-diffs">
                            {for (i, d) in enumerate(p.diffs) {
                                <div key={str(i)} className="pass-diff">
                                    <p className="diff-file">{d.path}</p>
                                    <DiffView diff={d.diff}/>
                                </div>
                            }}
                        </div>
                    }}
                </div>
            }}
        </div>
    </li>
}
