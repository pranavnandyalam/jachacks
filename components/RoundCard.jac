"""One round of the match: Red's attack, Blue's patch, the referee's verdict."""

import from ..arena { RoundInfo }
import from .DiffView { DiffView }

def:pub RoundCard(r: RoundInfo, blueBusy: bool, rejections: int) -> JsxElement {
    pending: bool = r.red_breached and r.blue_attempts == 0;
    red_cls: str = "rc-red breach" if r.red_breached else "rc-red miss";
    who: str = "anonymous" if r.red_identity == "anon" else r.red_identity;
    if not r.red_breached {
        return <MissRow r={r} who={who}/>;
    }
    <div className="rc rc-hit">
        <div className="rc-head">
            <span className="rc-n">{"Round " + str(r.n)}</span>
            <span className="rc-ver">{"code v" + str(r.version)}</span>
        </div>
        <div className={red_cls}>
            <div className="rc-row">
                <span className="tag tag-red">RED</span>
                <code className="rc-req">{r.red_method + " " + r.red_path}</code>
                <span className="rc-who">{"as " + who}</span>
                <span className="rc-vuln">{r.red_vuln}</span>
            </div>
            <p className="rc-why">{r.red_hypothesis}</p>
            <p className="rc-result">
                {("FLAG LEAKED - HTTP " + str(r.red_status)) if r.red_breached else ("blocked - HTTP " + str(r.red_status) + ", no flag")}
            </p>
        </div>
        {if r.red_breached {
            <BlueBlock r={r} pending={pending} blueBusy={blueBusy} rejections={rejections}/>
        }}
    </div>
}

def:pub BlueBlock(r: RoundInfo, pending: bool, blueBusy: bool, rejections: int) -> JsxElement {
    <div className="rc-blue">
        <div className="rc-row">
            <span className="tag tag-blue">BLUE</span>
            {if pending {
                <span className="rc-pending">
                    {("rewriting the code to close " + r.red_path + "...") if blueBusy else "waiting to patch"}
                </span>
            } else {
                <span className="rc-summary">{r.blue_summary}</span>
            }}
        </div>
        {if not pending {
            <div className="rc-verdict">
                <span className={"chk " + ("ok" if r.exploit_blocked else "bad")}>{("✓" if r.exploit_blocked else "✗") + " exploit closed"}</span>
                <span className={"chk " + ("ok" if r.regressions_ok else "bad")}>{("✓" if r.regressions_ok else "✗") + " no old holes reopened"}</span>
                <span className={"chk " + ("ok" if r.health_ok else "bad")}>{("✓" if r.health_ok else "✗") + " app still works"}</span>
                <span className={"verdict " + ("ok" if r.blue_accepted else "bad")}>
                    {("REFEREE ACCEPTED" if r.blue_accepted else "REFEREE REJECTED - hole stays open") + " · attempt " + str(r.blue_attempts)}
                </span>
                {if rejections > 0 {
                    <span className="rc-rej">{str(rejections) + " bad draft(s) caught by the referee"}</span>
                }}
            </div>
            if r.diff {
                <DiffView diff={r.diff}/>
            }
        }}
    </div>
}

"""A round where Red found nothing: one compact line, so the breach rounds stay
the focus of the feed."""
def:pub MissRow(r: RoundInfo, who: str) -> JsxElement {
    <div className="miss-row">
        <span className="miss-n">{"R" + str(r.n)}</span>
        <span className="tag tag-red dim">RED</span>
        <code className="rc-req">{r.red_method + " " + r.red_path}</code>
        <span className="rc-who">{"as " + who}</span>
        <span className="miss-res">{"blocked · HTTP " + str(r.red_status)}</span>
    </div>
}
