"""red-queen - Entry Point.

Combines server-side endpoints with the client-side UI.
"""

import from endpoints { Message, PostMessage, ListMessages }
import from ledgerly { svc_invoice_read }
import from red { run_red_turn, run_red_campaign, reset_red }
import from game { run_game, get_game_state, reset_game }

# Client-side UI

import from .frontend { app as ClientApp }

def:pub app -> JsxElement {
    <ClientApp/>
}
