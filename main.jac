"""red-queen - Entry Point.

Serves the v2 co-evolution game (Red finds vulns in the target's source, Blue
rewrites the code to fix them, a referee gates every patch) plus the client UI.
"""

import from arena { run_game, step_round, get_game_state, reset_game, get_rejected_patches }

# Client-side UI

import from .frontend { app as ClientApp }

def:pub app -> JsxElement {
    <ClientApp/>
}
