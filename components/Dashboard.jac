"""Red Queen live dashboard. Everything shown comes from the running engine.
Red and Blue are separate server calls (red_turn, blue_turn), and the server
publishes live progress (get_live: phase, round, Blue's draft number, each
referee ruling), so every viewer sees the round in flight, not a spinner."""

import from "react" { useEffect }
import from ..arena {
    GameState, RoundInfo, RejectedInfo,
    red_turn, blue_turn, reset_game, get_game_state,
    get_rejected_patches, get_current_source, get_line_origins
}
import from ..live { LiveInfo, get_live }
import from .RoundCard { RoundCard }
import from .CodeView { CodeView }
import from .Scoreboard { Scoreboard }
import from .HowItWorks { HowItWorks }

glob _seq: int = 0;
glob _lastLivePhase: str = "idle";
glob NET_ERR: str = "Can't reach the engine: ";

def by_n(r: RoundInfo) -> int {
    return r.n;
}

def:pub Dashboard -> JsxElement {
    has game: GameState | None = None,
        rejected: list[RejectedInfo] = [],
        source: str = "",
        origins: list[int] = [],
        live: LiveInfo | None = None,
        phase: str = "idle",
        auto: bool = False,
        err: str = "";

    # Every refresh takes a ticket; a response is applied only if no newer refresh
    # started meanwhile, so a slow poll can never overwrite fresher state (e.g. a
    # poll launched before a reset landing after it).
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

    # Live progress, polled every second. When the server finishes a phase that
    # someone else started (another tab), pull the new state right away.
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

    """One full round, as two real server calls: Red attacks, then (only if it
    breached) Blue patches under the referee."""
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
            err = label + " failed: " + str(e);
            phase = "idle";
            auto = False;
        }
    }

    """Reset the match on the server. False if the engine refused because Blue is
    still patching (e.g. a round started in another tab)."""
    async def do_reset -> bool {
        phase = "reset";
        n: int = -1;
        try {
            n = await reset_game();
        } except Exception as e {
            err = "Reset failed: " + str(e);
        }
        await refresh();
        phase = "idle";
        if n < 0 {
            if not err {
                err = "Blue is still patching a round (maybe from another tab). Try again in a few seconds.";
            }
            return False;
        }
        return True;
    }

    async def run_until_done {
        auto = True;
        while auto and game and not game.finished {
            await guarded("Round", play_round);
        }
        auto = False;
    }

    async def on_new_match {
        if phase != "idle" {
            return;
        }
        if not await do_reset() {
            return;
        }
        await run_until_done();
    }

    async def on_step {
        if phase != "idle" or (game and game.finished) {
            return;
        }
        await guarded("Round", play_round);
    }

    async def on_resume {
        if phase != "idle" {
            return;
        }
        await run_until_done();
    }

    def on_pause(e: MouseEvent) {
        auto = False;
    }

    async def on_reset {
        if phase != "idle" {
            return;
        }
        auto = False;
        await do_reset();
    }

    async can with entry {
        await refresh();
        await poll_live();
    }

    # State poll every 3s while idle (catches matches driven from elsewhere) and
    # the live-progress poll every 1s.
    useEffect(lambda {
        poll = setInterval(lambda { if phase == "idle" { refresh(); } }, 3000);
        livePoll = setInterval(lambda { poll_live(); }, 1000);
        return lambda { clearInterval(poll); clearInterval(livePoll); };
    }, []);

    rounds: list[RoundInfo] = sorted(game.rounds, key=by_n, reverse=True) if game else [];
    serverBusy: bool = bool(live and live.phase != "idle");
    busy: bool = phase != "idle" or serverBusy;
    finished: bool = bool(game and game.finished);
    liveBlue: bool = bool(live and live.phase == "blue");
    liveRound: int = live.round_n if live else 0;
    liveEvents: list[str] = live.events if live and live.phase == "blue" else [];

    <div className="dash">
        <header className="top">
            <div>
                <h1 className="title">RED QUEEN</h1>
                <p className="sub">Two AI agents fight over a real web app's source code. Security evolves one exploit at a time.</p>
            </div>
            <div className="controls">
                <button className="btn primary" disabled={busy} onClick={on_new_match}>{"New match"}</button>
                <button className="btn" disabled={busy or finished} onClick={on_step}>{"Next round"}</button>
                {if auto {
                    <button className="btn" onClick={on_pause}>{"Pause after this round"}</button>
                } else {
                    <button className="btn" disabled={busy or finished or not game or len(rounds) == 0} onClick={on_resume}>{"Resume"}</button>
                }}
                <button className="btn ghost" disabled={busy} onClick={on_reset}>{"Reset"}</button>
                <a className="btn ghost" href="/graph" target="_blank" rel="noreferrer">{"Jac graph ↗"}</a>
            </div>
        </header>
        <HowItWorks/>
        {if err {
            <div className="err">{err}</div>
        }}
        <StatusBar phase={phase} live={live} game={game}/>
        {if game {
            <Scoreboard game={game} rejectedCount={len(rejected) + len([ev for ev in liveEvents if "ACCEPTED" not in ev])}/>
        }}
        <main className="grid">
            <section className="feed">
                <h2 className="h2">{"Match feed"}</h2>
                {if len(rounds) == 0 {
                    <p className="empty">{"No rounds yet. Press New match: Red reads the code and attacks first."}</p>
                }}
                {for r in rounds {
                    <RoundCard
                        key={str(r.n)}
                        r={r}
                        blueBusy={phase == "blue" or (liveBlue and liveRound == r.n)}
                        rejections={len([x for x in rejected if x.round_n == r.n])}
                        liveEvents={liveEvents if liveRound == r.n else []}
                    />
                }}
            </section>
            <section className="side">
                <CodeView source={source} version={game.current_version if game else 0} origins={origins}/>
                {if len(rejected) > 0 {
                    <RejectedList items={rejected}/>
                }}
            </section>
        </main>
    </div>
}

"""What is happening right now. Prefers the server's live progress (true for
every viewer); falls back to this tab's own phase for the instant between a
click and the server picking the work up."""
def:pub StatusBar(phase: str, live: LiveInfo | None, game: GameState | None) -> JsxElement {
    sp: str = live.phase if live else "idle";
    eff: str = sp if sp != "idle" else phase;
    secs: int = live.elapsed_s if live and sp != "idle" else 0;
    played: int = game.rounds_played if game else 0;
    # Before the server reports progress: Red works on the NEXT round, Blue on the
    # round Red just played.
    n: int = live.round_n if live and sp != "idle" else (played if eff == "blue" else played + 1);
    draft: int = live.draft if live else 0;
    msg: str = "Ready. Press New match to start.";
    cls: str = "status idle";
    if eff == "red" {
        msg = "Round " + str(n) + ": Red is reading the source code and choosing an attack (" + str(secs) + "s)";
        cls = "status red";
    } elif eff == "blue" {
        dtxt: str = (" Draft " + str(draft) + ".") if draft > 0 else "";
        msg = "Round " + str(n) + ": Red leaked the flag. Blue is rewriting the code; the referee re-attacks every draft." + dtxt + " (" + str(secs) + "s)";
        cls = "status blue";
    } elif eff == "reset" {
        msg = "Resetting: code back to v0, Red's memory and the referee's exploit suite wiped.";
    } elif game and game.finished {
        msg = "Match over after " + str(game.rounds_played) + " rounds: Red found " + str(game.breaches) + " hole(s), Blue closed " + str(game.patches_accepted) + ". Code went v0 → v" + str(game.current_version) + ".";
        cls = "status done";
    } elif game and game.blue_pending {
        msg = "Red's last breach is still waiting for Blue. Press Next round.";
    } elif game and game.rounds_played > 0 {
        msg = "Paused after round " + str(game.rounds_played) + ". Press Next round or Resume.";
    }
    <div className={cls}>
        {if eff == "red" or eff == "blue" {
            <span className="pulse"></span>
        }}
        <span>{msg}</span>
    </div>
}

def:pub RejectedList(items: list[RejectedInfo]) -> JsxElement {
    <div className="rej">
        <h2 className="h2">{"Bad patches the referee caught"}</h2>
        {for (i, x) in enumerate(items) {
            <div key={str(i)} className="rej-item">
                <span className="rej-meta">{"R" + str(x.round_n) + " · " + x.path + " · draft " + str(x.attempt)}</span>
                <span className="rej-reason">{x.reason}</span>
            </div>
        }}
    </div>
}
