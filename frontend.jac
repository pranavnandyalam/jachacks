"""red-queen - Client-Side UI: the live match dashboard."""

import from .components.Dashboard { Dashboard }

def:pub app -> JsxElement {
    <Dashboard/>
}
