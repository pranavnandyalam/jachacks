"""Red Queen: watch an attacker agent find holes in an app's code and a
defender agent fix them, round by round. Everything shown comes from the
running engine; the server also publishes live progress (get_live), so every
viewer sees the round in flight."""

import from "react" { useEffect }
import from ..arena {
    GameState, RoundInfo, RejectedInfo,
    red_turn, blue_turn, reset_game, get_game_state,
    get_rejected_patches, get_current_source, get_line_origins
}
import from ..live { LiveInfo, get_live }
import from .RoundItem { RoundItem, MissGroup }
import from .CodeView { CodeView }

glob _seq: int = 0;
glob _lastLivePhase: str = "idle";
glob NET_ERR: str = "Can't reach the Red Queen server. Check that it's running, then reload. ";

def by_n(r: RoundInfo) -> int {
    return r.n;
}

"""Chronological rounds, with runs of consecutive misses folded together."""
def segments(rounds: list[RoundInfo]) -> list[list[RoundInfo]] {
    out: list[list[RoundInfo]] = [];
    run: list[RoundInfo] = [];
    for r in rounds {
        if r.red_breached {
            if len(run) > 0 {
                out = out + [run];
                run = [];
            }
            out = out + [[r]];
        } else {
            run = run + [r];
        }
    }
    if len(run) > 0 {
        out = out + [run];
    }
    return out;
}

def:pub Dashboard -> JsxElement {
    has game: GameState | None = None,
        rejected: list[RejectedInfo] = [],
        source: str = "",
        origins: list[int] = [],
        live: LiveInfo | None = None,
        phase: str = "idle",
        auto: bool = False,
        picked: int = 0,
        err: str = "";

    # Each refresh takes a ticket; a response is applied only if no newer refresh
    # started meanwhile, so a slow poll never overwrites fresher state.
    async def refresh {
        _seq = _seq + 1;
        ticket: int = _seq;
        try {
            g = await get_game_state();
            rj = await get_rejected_patches();
            src = await get_current_source();
            og = await get_line_origins();
            if ticket == _seq {
                game = g;
                rejected = rj;
                source = src;
                origins = og;
                if err.startswith(NET_ERR) {
                    err = "";
                }
            }
        } except Exception as e {
            err = NET_ERR + str(e);
        }
    }

    async def poll_live {
        try {
            li = await get_live();
            live = li;
            if _lastLivePhase != "idle" and li.phase == "idle" and phase == "idle" {
                await refresh();
            }
            _lastLivePhase = li.phase;
        } except Exception {
            live = None;
        }
    }

    async def play_round {
        phase = "red";
        r = await red_turn();
        await refresh();
        if r.red_breached and r.blue_attempts == 0 {
            phase = "blue";
            await blue_turn();
            await refresh();
        }
        phase = "idle";
    }

    async def guarded(label: str, work: Callable[[], any]) {
        try {
            await work();
        } except Exception as e {
            console.error("[RedQueen] " + label + " failed", e);
            err = label + " stopped: " + str(e);
            phase = "idle";
            auto = False;
        }
    }

    async def do_reset -> bool {
        phase = "reset";
        n: int = -1;
        try {
            n = await reset_game();
        } except Exception as e {
            err = "Couldn't reset: " + str(e);
        }
        await refresh();
        phase = "idle";
        picked = 0;
        if n < 0 {
            if not err {
                err = "Blue is still fixing a round, possibly from another window. Try again in a few seconds.";
            }
            return False;
        }
        return True;
    }

    async def run_until_done {
        auto = True;
        while auto and game and not game.finished {
            await guarded("The match", play_round);
        }
        auto = False;
    }

    async def on_start {
        if phase != "idle" {
            return;
        }
        if not await do_reset() {
            return;
        }
        await run_until_done();
    }

    async def on_resume {
        if phase == "idle" {
            await run_until_done();
        }
    }

    async def on_step {
        if phase == "idle" and not (game and game.finished) {
            await guarded("The round", play_round);
        }
    }

    def on_pause(e: MouseEvent) {
        auto = False;
    }

    async def on_reset {
        if phase == "idle" {
            auto = False;
            await do_reset();
        }
    }

    def on_select(n: int) {
        picked = n;
    }

    async can with entry {
        await refresh();
        await poll_live();
    }

    useEffect(lambda {
        poll = setInterval(lambda { if phase == "idle" { refresh(); } }, 3000);
        livePoll = setInterval(lambda { poll_live(); }, 1000);
        return lambda { clearInterval(poll); clearInterval(livePoll); };
    }, []);

    rounds: list[RoundInfo] = sorted(game.rounds, key=by_n) if game else [];
    serverBusy: bool = bool(live and live.phase != "idle");
    busy: bool = phase != "idle" or serverBusy;
    finished: bool = bool(game and game.finished);
    started: bool = len(rounds) > 0;
    liveBlue: bool = bool(live and live.phase == "blue");
    liveRound: int = live.round_n if live else 0;
    liveDraft: int = live.draft if live else 0;
    liveEvents: list[str] = live.events if live and live.phase == "blue" else [];
    latestFix: int = 0;
    for r in rounds {
        if r.blue_accepted {
            latestFix = r.n;
        }
    }
    selected: int = picked if picked > 0 else latestFix;

    <div className="app">
        <header className="top">
            <div className="brand">
                <h1>{"Red Queen"}</h1>
                <p>{"An attacker agent reads your app's code and tries to leak a secret. A defender agent fixes each hole it finds, and every fix is re-tested before it ships."}</p>
            </div>
            <div className="actions">
                <PrimaryAction auto={auto} busy={busy} started={started} finished={finished}
                    onStart={on_start} onResume={on_resume} onPause={on_pause}/>
                <button type="button" className="btn" disabled={busy or finished or not game} onClick={on_step}>{"Step one round"}</button>
                <button type="button" className="btn" disabled={busy or not started} onClick={on_reset}>{"Reset"}</button>
                <a className="quiet-link" href="/graph" target="_blank" rel="noreferrer">{"View graph"}</a>
            </div>
        </header>

        {if err {
            <p className="alert" role="alert">{err}</p>
        }}

        <StatusLine phase={phase} live={live} game={game} rounds={rounds}/>
        {if game {
            <Summary game={game}/>
        }}

        <main className="layout">
            <section className="ledger" aria-label="Rounds">
                <header className="panel-head">
                    <h2 className="panel-title">{"Rounds"}</h2>
                    {if latestFix > 0 {
                        <span className="panel-note">{"Select a round to see its fix in the code"}</span>
                    }}
                </header>
                {if not started {
                    <p className="empty">{"No rounds yet. Start a match and Red takes the first turn."}</p>
                }}
                <ol className="rounds">
                    {for seg in segments(rounds) {
                        if seg[0].red_breached {
                            <RoundItem
                                key={"r" + str(seg[0].n)}
                                r={seg[0]}
                                drafts={[x for x in rejected if x.round_n == seg[0].n]}
                                fixing={liveBlue and liveRound == seg[0].n}
                                liveDraft={liveDraft if liveRound == seg[0].n else 0}
                                liveEvents={liveEvents if liveRound == seg[0].n else []}
                                selected={selected == seg[0].n}
                                onSelect={on_select}
                            />
                        } else {
                            <MissGroup key={"m" + str(seg[0].n)} rounds={seg}/>
                        }
                    }}
                </ol>
            </section>
            <CodeView source={source} version={game.current_version if game else 0} origins={origins} selected={selected}/>
        </main>
    </div>
}

def:pub PrimaryAction(
    auto: bool, busy: bool, started: bool, finished: bool,
    onStart: Callable[[], any], onResume: Callable[[], any], onPause: Callable[[MouseEvent], None]
) -> JsxElement {
    if auto {
        return <button type="button" className="btn primary" onClick={onPause}>{"Pause after this round"}</button>;
    }
    if busy {
        return <button type="button" className="btn primary" disabled={True}>{"Working"}</button>;
    }
    if started and not finished {
        return <button type="button" className="btn primary" onClick={onResume}>{"Resume match"}</button>;
    }
    <button type="button" className="btn primary" onClick={onStart}>{"Start new match" if finished else "Start match"}</button>
}

"""One sentence about what is happening now. Prefers the server's live progress
(the same for every viewer)."""
def:pub StatusLine(phase: str, live: LiveInfo | None, game: GameState | None, rounds: list[RoundInfo]) -> JsxElement {
    sp: str = live.phase if live else "idle";
    eff: str = sp if sp != "idle" else phase;
    secs: int = live.elapsed_s if live and sp != "idle" else 0;
    played: int = game.rounds_played if game else 0;
    n: int = live.round_n if live and sp != "idle" else (played if eff == "blue" else played + 1);
    path: str = "";
    for r in rounds {
        if r.n == n {
            path = r.red_method + " " + r.red_path;
        }
    }
    msg: str = "Start a match to watch Red attack this app and Blue fix what it finds.";
    tone: str = "idle";
    if eff == "red" {
        msg = "Round " + str(n) + ": Red is reading the code and choosing an attack.";
        tone = "working";
    } elif eff == "blue" {
        draft: int = live.draft if live else 0;
        msg = "Round " + str(n) + ": Blue is fixing " + (path if path else "the hole Red found") + "." + ((" Draft " + str(draft) + ".") if draft > 0 else "");
        tone = "working";
    } elif eff == "reset" {
        msg = "Resetting to the original code.";
    } elif game and game.finished {
        msg = "Match complete. Red found " + str(game.breaches) + (" vulnerability" if game.breaches == 1 else " vulnerabilities") + " and Blue fixed " + ("all of them." if game.patches_accepted == game.breaches else str(game.patches_accepted) + ".");
        tone = "done";
    } elif game and game.blue_pending {
        msg = "Round " + str(played) + " is waiting for Blue. Resume the match to continue.";
    } elif game and played > 0 {
        msg = "Paused after round " + str(played) + ".";
    }
    <div className={"status is-" + tone} role="status" aria-live="polite">
        <span className="status-dot" aria-hidden="true"></span>
        <span className="status-msg">{msg}</span>
        {if tone == "working" {
            <span className="status-time">{str(secs) + "s"}</span>
        }}
    </div>
}

def:pub Summary(game: GameState) -> JsxElement {
    <dl className="summary">
        <div><dt>{"Found"}</dt><dd className={"n-found" if game.breaches > 0 else ""}>{str(game.breaches)}</dd></div>
        <div><dt>{"Fixed"}</dt><dd className={"n-fixed" if game.patches_accepted > 0 else ""}>{str(game.patches_accepted)}</dd></div>
        <div><dt>{"Still open"}</dt><dd className={"n-open" if game.open_holes > 0 else ""}>{str(game.open_holes)}</dd></div>
        <div><dt>{"App checks"}</dt><dd className={"n-fixed" if game.health_ok else "n-found"}>{"Passing" if game.health_ok else "Failing"}</dd></div>
    </dl>
}
