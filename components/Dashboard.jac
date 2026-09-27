"""Red Queen live dashboard. Everything shown comes from the running engine:
Red and Blue are separate server calls (red_turn, blue_turn), so the page shows
Red's hit the moment it lands and Blue's patch when the referee rules on it.
Nothing is simulated client-side; the only local value is the elapsed timer."""

import from "react" { useEffect }
import from ..arena {
    GameState, RoundInfo, RejectedInfo,
    red_turn, blue_turn, reset_game, get_game_state,
    get_rejected_patches, get_current_source
}
import from .RoundCard { RoundCard }
import from .CodeView { CodeView }
import from .Scoreboard { Scoreboard }

glob _seq: int = 0;
glob NET_ERR: str = "Can't reach the engine: ";

def by_n(r: RoundInfo) -> int {
    return r.n;
}

def:pub Dashboard -> JsxElement {
    has game: GameState | None = None,
        rejected: list[RejectedInfo] = [],
        source: str = "",
        phase: str = "idle",
        auto: bool = False,
        err: str = "",
        phaseStart: float = 0.0,
        now: float = 0.0;

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
            if ticket == _seq {
                game = g;
                rejected = rj;
                source = src;
                if err.startswith(NET_ERR) {
                    err = "";
                }
            }
        } except Exception as e {
            err = NET_ERR + str(e);
        }
    }

    def start_phase(p: str) {
        phase = p;
        phaseStart = Date.now();
        now = phaseStart;
    }

    """One full round, as two real server calls: Red attacks, then (only if it
    breached) Blue patches under the referee."""
    async def play_round {
        start_phase("red");
        r = await red_turn();
        await refresh();
        if r.red_breached and r.blue_attempts == 0 {
            start_phase("blue");
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
    }

    # Poll the engine while idle, so the page also reflects matches driven from
    # elsewhere (another tab, the check-in script). Plus a 1s tick for the timer.
    useEffect(lambda {
        poll = setInterval(lambda { if phase == "idle" { refresh(); } }, 3000);
        tick = setInterval(lambda { now = Date.now(); }, 1000);
        return lambda { clearInterval(poll); clearInterval(tick); };
    }, []);

    rounds: list[RoundInfo] = sorted(game.rounds, key=by_n, reverse=True) if game else [];
    last_diff: str = "";
    for r in rounds {
        if r.diff and not last_diff {
            last_diff = r.diff;
        }
    }
    busy: bool = phase != "idle";
    finished: bool = bool(game and game.finished);
    secs: int = int((now - phaseStart) / 1000) if busy else 0;

    <div className="dash">
        <header className="top">
            <div>
                <h1 className="title">RED QUEEN</h1>
                <p className="sub">An AI attacker and an AI defender fight over a real Flask app's source code. A deterministic referee decides every patch.</p>
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
            </div>
        </header>
        {if err {
            <div className="err">{err}</div>
        }}
        <StatusBar phase={phase} secs={secs} game={game} rounds={rounds}/>
        {if game {
            <Scoreboard game={game} rejectedCount={len(rejected)}/>
        }}
        <main className="grid">
            <section className="feed">
                <h2 className="h2">{"Match feed"}</h2>
                {if len(rounds) == 0 {
                    <p className="empty">{"No rounds yet. Press New match: Red reads the code and attacks first."}</p>
                }}
                {for r in rounds {
                    <RoundCard key={str(r.n)} r={r} blueBusy={phase == "blue"} rejections={len([x for x in rejected if x.round_n == r.n])}/>
                }}
            </section>
            <section className="side">
                <CodeView source={source} version={game.current_version if game else 0} lastDiff={last_diff}/>
                {if len(rejected) > 0 {
                    <RejectedList items={rejected}/>
                }}
            </section>
        </main>
    </div>
}

def:pub StatusBar(phase: str, secs: int, game: GameState | None, rounds: list[RoundInfo]) -> JsxElement {
    cur: RoundInfo | None = rounds[0] if len(rounds) > 0 else None;
    n: int = (game.rounds_played if game else 0);
    msg: str = "Ready. Press New match to start.";
    cls: str = "status idle";
    if phase == "red" {
        msg = "Round " + str(n + 1) + ": Red is reading the source code and choosing an attack (" + str(secs) + "s)";
        cls = "status red";
    } elif phase == "blue" and cur {
        msg = "Round " + str(cur.n) + ": Red leaked the flag via " + cur.red_method + " " + cur.red_path + ". Blue is rewriting the code; the referee re-attacks every draft (" + str(secs) + "s)";
        cls = "status blue";
    } elif game and game.finished {
        msg = "Match over after " + str(game.rounds_played) + " rounds: Red found " + str(game.breaches) + " hole(s), Blue closed " + str(game.patches_accepted) + ". Code went v0 → v" + str(game.current_version) + ".";
        cls = "status done";
    } elif phase == "reset" {
        msg = "Resetting: code back to v0, Red's memory and the referee's exploit suite wiped.";
    } elif game and game.blue_pending {
        msg = "Red's last breach is still waiting for Blue. Press Next round.";
    } elif game and game.rounds_played > 0 {
        msg = "Paused after round " + str(game.rounds_played) + ". Press Next round or Resume.";
    }
    <div className={cls}>
        {if phase == "red" or phase == "blue" {
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
