"""red-queen - Entry Point.

Combines server-side endpoints with the client-side UI.
"""

import from endpoints { Message, PostMessage, ListMessages }
import from ledgerly { svc_invoice_read }

# Client-side UI

import from .frontend { app as ClientApp }

def:pub app -> JsxElement {
    <ClientApp/>
}
