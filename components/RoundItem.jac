"""One round in the ledger: what Red found, then how Blue fixed it."""

import from ..arena { RoundInfo, RejectedInfo }
import from .DiffView { DiffView }

"""Plain-language name for Red's weakness label (the model's own words vary)."""
def weakness_name(vc: str) -> str {
    v = vc.upper();
    if "IDOR" in v or "OWNER" in v {
        return "Missing ownership check";
    }
    if "DEBUG" in v {
        return "Debug endpoint left open";
    }
    if "SECRET" in v or "EXPOSURE" in v {
        return "Secret exposed";
    }
    if "ACCESS" in v or "BFLA" in v or "AUTH" in v or "ADMIN" in v {
        return "Missing admin check";
    }
    return "Access control flaw";
}

def who_text(identity: str) -> str {
    return "without logging in" if identity == "anon" else "as " + identity + " (a regular user)";
}

def:pub RoundItem(
    r: RoundInfo,
    drafts: list[RejectedInfo],
    fixing: bool,
    liveDraft: int,
    liveEvents: list[str],
    selected: bool,
    onSelect: Callable[[int], None]
) -> JsxElement {
    has showDiff: bool = False,
        showDrafts: bool = False;

    pending: bool = r.blue_attempts == 0;
    fixed: bool = r.blue_accepted;

    def select(e: MouseEvent) {
        onSelect(r.n);
    }

    def toggle_diff(e: MouseEvent) {
        e.stopPropagation();
        showDiff = not showDiff;
    }

    def toggle_drafts(e: MouseEvent) {
        e.stopPropagation();
        showDrafts = not showDrafts;
    }

    <li className={"round" + (" is-selected" if selected else "")}>
        <button type="button" className="round-hit" onClick={select} aria-pressed={selected}>
            <span className="round-n">{str(r.n)}</span>
            <span className="sr-only">{"Show round " + str(r.n) + " in the code"}</span>
        </button>
        <div className="round-body">
            <div className="step found">
                <p className="step-head">
                    <span className="step-kind">{"Found"}</span>
                    <span className="step-title">{weakness_name(r.red_vuln)}</span>
                </p>
                <p className="req">
                    <code>{r.red_method + " " + r.red_path}</code>
                    <span className="req-who">{" " + who_text(r.red_identity) + " returned the secret."}</span>
                </p>
                <p className="why"><span className="why-label">{"Red's reasoning: "}</span>{r.red_hypothesis}</p>
            </div>
            {if pending {
                <div className="step working">
                    <p className="step-head">
                        <span className="step-kind">{"Fixing"}</span>
                        <span className="step-title">
                            {("Blue is writing draft " + str(liveDraft)) if fixing and liveDraft > 0 else "Waiting for Blue"}
                        </span>
                    </p>
                    {if len(liveEvents) > 0 {
                        <ul className="events">
                            {for (i, ev) in enumerate(liveEvents) {
                                <li key={str(i)}>{ev}</li>
                            }}
                        </ul>
                    }}
                </div>
            } elif fixed {
                <div className="step fixed">
                    <p className="step-head">
                        <span className="step-kind">{"Fixed"}</span>
                        <span className="step-title">{r.blue_summary}</span>
                    </p>
                    <p className="verified">{"Re-tested: the exploit is blocked, earlier fixes still hold, and the app works for normal users."}</p>
                    <RoundTools r={r} drafts={drafts} showDiff={showDiff} showDrafts={showDrafts} onDiff={toggle_diff} onDrafts={toggle_drafts}/>
                </div>
            } else {
                <div className="step open">
                    <p className="step-head">
                        <span className="step-kind">{"Still open"}</span>
                        <span className="step-title">{"Every draft was rejected, so this hole was not fixed."}</span>
                    </p>
                    <RoundTools r={r} drafts={drafts} showDiff={showDiff} showDrafts={showDrafts} onDiff={toggle_diff} onDrafts={toggle_drafts}/>
                </div>
            }}
        </div>
    </li>
}

def:pub RoundTools(
    r: RoundInfo,
    drafts: list[RejectedInfo],
    showDiff: bool,
    showDrafts: bool,
    onDiff: Callable[[MouseEvent], None],
    onDrafts: Callable[[MouseEvent], None]
) -> JsxElement {
    n_rej: int = len(drafts);
    <div className="tools">
        <div className="tool-row">
            {if r.diff {
                <button type="button" className="link" onClick={onDiff} aria-expanded={showDiff}>
                    {"Hide change" if showDiff else "Show change"}
                </button>
            }}
            {if n_rej > 0 {
                <button type="button" className="link" onClick={onDrafts} aria-expanded={showDrafts}>
                    {("Hide " if showDrafts else "Show ") + str(n_rej) + (" rejected draft" if n_rej == 1 else " rejected drafts")}
                </button>
            }}
        </div>
        {if showDrafts {
            <ol className="drafts">
                {for d in drafts {
                    <li key={str(d.attempt)}><strong>{"Draft " + str(d.attempt) + ": "}</strong>{d.reason.replace("rejected: ", "")}</li>
                }}
            </ol>
        }}
        {if showDiff and r.diff {
            <DiffView diff={r.diff}/>
        }}
    </div>
}

"""Consecutive rounds where Red found nothing, folded into one line."""
def:pub MissGroup(rounds: list[RoundInfo]) -> JsxElement {
    has open: bool = False;
    first: int = rounds[0].n;
    last: int = rounds[len(rounds) - 1].n;
    label: str = ("Round " + str(first)) if first == last else ("Rounds " + str(first) + "–" + str(last));
    count: int = len(rounds);

    def toggle(e: MouseEvent) {
        open = not open;
    }

    <li className="miss">
        <button type="button" className="miss-line" onClick={toggle} aria-expanded={open}>
            {label + ": " + str(count) + (" attack" if count == 1 else " attacks") + (" was" if count == 1 else ", all") + " blocked"}
        </button>
        {if open {
            <ul className="miss-list">
                {for m in rounds {
                    <li key={str(m.n)}>
                        <code>{m.red_method + " " + m.red_path}</code>
                        {" " + who_text(m.red_identity) + " got HTTP " + str(m.red_status) + "."}
                    </li>
                }}
            </ul>
        }}
    </li>
}
