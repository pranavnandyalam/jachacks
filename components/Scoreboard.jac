"""Running tallies for the match, straight from get_game_state."""

import from ..arena { GameState }

def:pub Scoreboard(game: GameState, rejectedCount: int) -> JsxElement {
    <div className="score">
        <Stat label="Rounds" value={str(game.rounds_played)} tone=""/>
        <Stat label="Breaches (Red)" value={str(game.breaches)} tone="red"/>
        <Stat label="Patched (Blue)" value={str(game.patches_accepted)} tone="blue"/>
        <Stat label="Open holes" value={str(game.open_holes)} tone={"red" if game.open_holes > 0 else "green"}/>
        <Stat label="Code version" value={"v" + str(game.current_version)} tone=""/>
        <Stat label="App health" value={"OK" if game.health_ok else "BROKEN"} tone={"green" if game.health_ok else "red"}/>
        <Stat label="Drafts rejected" value={str(rejectedCount)} tone=""/>
    </div>
}

def:pub Stat(label: str, value: str, tone: str) -> JsxElement {
    <div className={"stat " + tone}>
        <div className="stat-v">{value}</div>
        <div className="stat-l">{label}</div>
    </div>
}
