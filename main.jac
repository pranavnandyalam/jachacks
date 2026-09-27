"""red-queen - Entry Point.

Serves the v2 co-evolution game (Red finds vulns in the target's source, Blue
rewrites the code to fix them, a referee gates every patch) plus the client UI.
"""

import from audit { run_audit, audit_step, reset_audit, run_audit_loop, get_audit_state, scan_target }
import from config { list_targets, set_active_target }
import from arena { run_game, step_round, red_turn, blue_turn, get_game_state, reset_game, get_rejected_patches, get_current_source, get_line_origins }
import from live { get_live }
import from voice { voice_session, voice_brief }

# Client-side UI

import "./assets/dashboard.css";

import from .frontend { app as ClientApp }

def:pub app -> JsxElement {
    <ClientApp/>
}
