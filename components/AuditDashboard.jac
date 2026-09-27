"""Audit-mode dashboard: point Red Queen at a codebase and it hardens it, one
pass at a time, until a scan comes back clean. Every number comes from the
running engine; the server publishes live progress (get_live) so a slow pass
shows what it's doing."""

import from "react" { useEffect }
import from ..audit {
    AuditState, PassInfo, TargetFile, Finding, FileDiff,
    audit_step, reset_audit, get_audit_state
}
import from ..config { TargetInfo, list_targets, set_active_target }
import from ..live { LiveInfo, get_live }
import from .AuditPass { AuditPass }
import from .FileViewer { FileViewer }
import from .VoiceGuide { VoiceGuide }

glob _aseq: int = 0;
glob _lastPhase: str = "idle";

def:pub AuditDashboard -> JsxElement {
    has state: AuditState | None = None,
        sites: list[TargetInfo] = [],
        live: LiveInfo | None = None,
        running: bool = False,
        pickedFile: str = "",
        err: str = "";

    async def load_sites {
        try {
            sites = await list_targets();
        } except Exception as e {
            err = "Can't load sites: " + str(e);
        }
    }

    """Switch to another example site: point the engine at it, wipe the old run."""
    async def on_pick_site(e: ChangeEvent) {
        if running {
            return;
        }
        chosen: str = e.target.value;
        try {
            await set_active_target(chosen);
            await reset_audit();
            pickedFile = "";
            await load_sites();
            await refresh();
        } except Exception as ex {
            err = "Couldn't switch site: " + str(ex);
        }
    }

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
        await load_sites();
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
    busy: bool = running;
    # Apps in other languages (Go, TypeScript, FastAPI) can't run in-process, so
    # their fixes are checked by compiling + Red re-scanning, not by live exploit.
    staticMode: bool = bool(state and state.mode == "static");
    activeDir: str = "";
    for s in sites {
        if s.active {
            activeDir = s.dir;
        }
    }
    primaryLabel: str = "Hardening..." if busy else "Harden this codebase";

    <div className="app">
        <header className="top">
            <div className="brand">
                <h1>{"Red Queen"}</h1>
                <p>{"Pick an app. An attacker agent finds the ways it leaks data, a defender agent fixes them, and it repeats until a scan comes back clean."}</p>
            </div>
            <div className="actions">
                <label className="site-pick">
                    <span className="site-pick-label">{"Example app"}</span>
                    <select className="site-select" value={activeDir} disabled={busy} onChange={on_pick_site}>
                        {for s in sites {
                            <option key={s.dir} value={s.dir}>
                                {s.name + " (" + (str(s.files) + " files" if s.files > 1 else "1 file") + (", checked by re-scan" if s.mode == "static" else "") + ")"}
                            </option>
                        }}
                    </select>
                </label>
                <button type="button" className="btn primary" disabled={busy} onClick={run}>{primaryLabel}</button>
                <button type="button" className="btn" disabled={busy or not state or state.passes_done == 0} onClick={on_reset}>{"Reset"}</button>
                <VoiceGuide stamp={(state.target if state else "") + ":" + str(state.passes_done if state else 0)}/>
                <a className="quiet-link" href="/graph" target="_blank" rel="noreferrer">{"View graph"}</a>
            </div>
        </header>

        {if err {
            <p className="alert" role="alert">{err}</p>
        }}

        <AuditStatus phase={phase} secs={secs} livePass={livePass} state={state} clean={clean} staticMode={staticMode}/>
        {if state {
            <AuditSummary state={state} staticMode={staticMode}/>
        }}

        <main className="layout">
            <section className="ledger" aria-label="Audit passes">
                <header className="panel-head">
                        <h2 className="panel-title">{"Passes"}</h2>
                        <span className="panel-note">{(state.target if state else "") + " · " + str(len(files)) + (" files" if len(files) != 1 else " file")}</span>
                    </header>
                    {if not state or state.passes_done == 0 {
                        <p className="empty">{"No passes yet. Hardening runs scans until one comes back clean."}</p>
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

def:pub AuditStatus(phase: str, secs: int, livePass: int, state: AuditState | None, clean: bool, staticMode: bool) -> JsxElement {
    msg: str = "Ready. Harden this codebase to start.";
    tone: str = "idle";
    if phase == "scan" {
        msg = "Pass " + str(livePass) + ": Red is reading the code and looking for ways to leak the secret.";
        tone = "working";
    } elif phase == "fix" {
        msg = "Pass " + str(livePass) + (": Blue is patching the code." if staticMode else ": Blue is rewriting the affected files.");
        tone = "working";
    } elif clean {
        msg = "Clean. The last scan found nothing left to fix after " + str(state.passes_done if state else 0) + (" pass." if (state and state.passes_done == 1) else " passes.");
        if staticMode {
            msg = msg + " (This app runs in another language: fixes are checked by compiling and re-scanning, not by live exploit.)";
        }
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

def:pub AuditSummary(state: AuditState, staticMode: bool) -> JsxElement {
    <dl className="summary">
        <div><dt>{"Passes"}</dt><dd>{str(state.passes_done)}</dd></div>
        <div><dt>{"Found"}</dt><dd className={"n-found" if state.total_found > 0 else ""}>{str(state.total_found)}</dd></div>
        <div><dt>{"Still open"}</dt><dd className={"n-open" if state.total_open > 0 else "n-fixed"}>{str(state.total_open)}</dd></div>
        <div><dt>{"Compiles" if staticMode else "App checks"}</dt><dd className={"n-fixed" if state.health_ok else "n-found"}>{("Yes" if staticMode else "Passing") if state.health_ok else "Failing"}</dd></div>
    </dl>
}
