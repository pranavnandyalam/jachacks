"""Audit-mode dashboard: point Red Queen at a codebase and it hardens it, one
pass at a time, until a scan comes back clean. Every number comes from the
running engine; the server publishes live progress (get_live) so a slow pass
shows what it's doing."""

import from "react" { useEffect }
import from ..audit {
    AuditState, PassInfo, TargetFile, Finding, FileDiff,
    audit_step, reset_audit, get_audit_state
}
import from ..live { LiveInfo, get_live }
import from .AuditPass { AuditPass }
import from .FileViewer { FileViewer }

glob _aseq: int = 0;
glob _lastPhase: str = "idle";

def:pub AuditDashboard -> JsxElement {
    has state: AuditState | None = None,
        live: LiveInfo | None = None,
        running: bool = False,
        pickedFile: str = "",
        err: str = "";

    async def refresh {
        _aseq = _aseq + 1;
        t: int = _aseq;
        try {
            s = await get_audit_state();
            if t == _aseq {
                state = s;
                err = "";
            }
        } except Exception as e {
            err = "Can't reach the server: " + str(e);
        }
    }

    async def poll_live {
        try {
            live = await get_live();
        } except Exception {
            live = None;
        }
    }

    async def run {
        if running {
            return;
        }
        running = True;
        try {
            await reset_audit();
            await refresh();
            keep: bool = True;
            while keep and running {
                await audit_step();
                await refresh();
                keep = bool(state and not state.finished);
            }
        } except Exception as e {
            err = "Audit stopped: " + str(e);
        }
        running = False;
    }

    async def on_reset {
        if not running {
            await reset_audit();
            pickedFile = "";
            await refresh();
        }
    }

    def pick(name: str) {
        pickedFile = name;
    }

    async can with entry {
        await refresh();
        await poll_live();
    }

    useEffect(lambda {
        live_i = setInterval(lambda { poll_live(); }, 1000);
        return lambda { clearInterval(live_i); };
    }, []);

    files: list[TargetFile] = state.files if state else [];
    passes: list[PassInfo] = sorted(state.passes, key=_pass_no, reverse=True) if state else [];
    selected: str = pickedFile if pickedFile else (files[0].path if len(files) > 0 else "");
    clean: bool = bool(state and state.finished and state.total_open == 0 and state.passes_done > 0);
    phase: str = live.phase if live else "idle";
    livePass: int = live.round_n if live else 0;
    secs: int = live.elapsed_s if live and phase != "idle" else 0;

    <div className="app">
        <header className="top">
            <div className="brand">
                <h1>{"Red Queen"}</h1>
                <p>{"Point it at a codebase. An attacker agent finds the ways it leaks data, a defender agent fixes them, and it repeats until a scan comes back clean."}</p>
            </div>
            <div className="actions">
                <button type="button" className="btn primary" disabled={running} onClick={run}>
                    {"Running..." if running else "Harden this codebase"}
                </button>
                <button type="button" className="btn" disabled={running or not state or state.passes_done == 0} onClick={on_reset}>{"Reset"}</button>
                <a className="quiet-link" href="/graph" target="_blank" rel="noreferrer">{"View graph"}</a>
            </div>
        </header>

        {if err {
            <p className="alert" role="alert">{err}</p>
        }}

        <AuditStatus phase={phase} secs={secs} livePass={livePass} state={state} clean={clean}/>
        {if state {
            <AuditSummary state={state}/>
        }}

        <main className="layout">
            <section className="ledger" aria-label="Audit passes">
                <header className="panel-head">
                    <h2 className="panel-title">{"Passes"}</h2>
                    <span className="panel-note">{(state.target if state else "") + " · " + str(len(files)) + " files"}</span>
                </header>
                {if not state or state.passes_done == 0 {
                    <p className="empty">{"No passes yet. Harden this codebase runs scans until one comes back clean."}</p>
                }}
                <ol className="rounds">
                    {for p in passes {
                        <AuditPass key={str(p.n)} p={p} onPickFile={pick}/>
                    }}
                </ol>
            </section>
            <FileViewer files={files} selected={selected} onPick={pick}/>
        </main>
    </div>
}

def _pass_no(p: PassInfo) -> int {
    return p.n;
}

def:pub AuditStatus(phase: str, secs: int, livePass: int, state: AuditState | None, clean: bool) -> JsxElement {
    msg: str = "Ready. Harden this codebase to start.";
    tone: str = "idle";
    if phase == "scan" {
        msg = "Pass " + str(livePass) + ": Red is reading the code and looking for ways to leak the secret.";
        tone = "working";
    } elif phase == "fix" {
        msg = "Pass " + str(livePass) + ": Blue is rewriting the affected files.";
        tone = "working";
    } elif clean {
        msg = "Clean. The last scan found nothing left to fix after " + str(state.passes_done if state else 0) + (" pass." if (state and state.passes_done == 1) else " passes.");
        tone = "done";
    } elif state and state.passes_done > 0 {
        msg = "Paused after pass " + str(state.passes_done) + ".";
    }
    <div className={"status is-" + tone} role="status" aria-live="polite">
        <span className="status-dot" aria-hidden="true"></span>
        <span className="status-msg">{msg}</span>
        {if tone == "working" {
            <span className="status-time">{str(secs) + "s"}</span>
        }}
    </div>
}

def:pub AuditSummary(state: AuditState) -> JsxElement {
    <dl className="summary">
        <div><dt>{"Passes"}</dt><dd>{str(state.passes_done)}</dd></div>
        <div><dt>{"Found"}</dt><dd className={"n-found" if state.total_found > 0 else ""}>{str(state.total_found)}</dd></div>
        <div><dt>{"Still open"}</dt><dd className={"n-open" if state.total_open > 0 else "n-fixed"}>{str(state.total_open)}</dd></div>
        <div><dt>{"App checks"}</dt><dd className={"n-fixed" if state.health_ok else "n-found"}>{"Passing" if state.health_ok else "Failing"}</dd></div>
    </dl>
}
