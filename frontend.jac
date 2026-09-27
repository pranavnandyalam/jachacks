"""red-queen - Client-Side UI: the live match dashboard."""

import from .components.AuditDashboard { AuditDashboard }

def:pub app -> JsxElement {
    <AuditDashboard/>
}
