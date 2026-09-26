"""Ledgerly - the deliberately misconfigured mock SaaS target.

Every weakness is a policy field on an `Endpoint` node. The `svc_*` functions
read those fields on each request and enforce them, so an insecure field is a
real, exploitable hole over HTTP and flipping it closes the hole immediately.
Red attacks through the `:pub` functions; Blue patches via `set_policy`, which
is deliberately NOT served (plain `def`), so only the in-process game can harden.
"""

node Service {
    has name: str;
}

node Endpoint {
    has path: str,
        kind: str,
        auth_required: bool = False,
        owner_check: bool = False,
        is_debug_open: bool = False,
        exposes_secret: bool = False;
}

node Invoice {
    has inv_id: str,
        owner: str,
        amount: float,
        secret: bool = False;
}

node Flag {
    has value: str;
}

edge Exposes: Service --> Endpoint {}
edge Guards: Endpoint --> Invoice {}
edge Holds: Invoice --> Flag {}

glob SERVICE_NAME: str = "ledgerly",
     FLAG_VALUE: str = "RQ{ledgerly_admin_invoice}",
     POLICY_FIELDS: list[str] = [
         "auth_required", "owner_check", "is_debug_open", "exposes_secret"
     ];

obj AccessResult {
    has ok: bool,
        reason: str,
        inv_id: str = "",
        owner: str = "",
        amount: float = 0.0,
        flag: str = "";
}

"""Get-or-create the Ledgerly target subgraph on the current root."""
def ledgerly -> Service {
    found = [root -->[?:Service, name == SERVICE_NAME]];
    if found {
        return found[0];
    }
    svc = root ++> Service(name=SERVICE_NAME);
    inv_ep = svc +>:Exposes():+> Endpoint(path="/invoices", kind="invoice_read");
    inv_ep +>:Guards():+> Invoice(inv_id="INV-1001", owner="alice", amount=120.0);
    inv_ep +>:Guards():+> Invoice(inv_id="INV-1002", owner="bob", amount=75.5);
    admin_inv = inv_ep +>:Guards():+> Invoice(
        inv_id="INV-0001", owner="admin", amount=0.0, secret=True
    );
    admin_inv +>:Holds():+> Flag(value=FLAG_VALUE);
    return svc;
}

def find_endpoint(ep_kind: str) -> Endpoint | None {
    eps = [ledgerly() ->:Exposes:->[?:Endpoint, kind == ep_kind]];
    return eps[0] if eps else None;
}

"""Read an invoice as `as_user`. Enforces the endpoint's live policy fields."""
def:pub svc_invoice_read(inv_id: str, as_user: str = "") -> AccessResult {
    ep = find_endpoint("invoice_read");
    if ep is None {
        return AccessResult(ok=False, reason="no such endpoint");
    }
    if ep.auth_required and not as_user {
        return AccessResult(ok=False, reason="401 login required");
    }
    wanted = inv_id;
    matches = [ep ->:Guards:->[?:Invoice, inv_id == wanted]];
    if not matches {
        return AccessResult(ok=False, reason="404 invoice not found");
    }
    inv = matches[0];
    if ep.owner_check and inv.owner != as_user {
        return AccessResult(ok=False, reason="403 not your invoice");
    }
    flags = [inv ->:Holds:->];
    return AccessResult(
        ok=True,
        reason="200",
        inv_id=inv.inv_id,
        owner=inv.owner,
        amount=inv.amount,
        flag=flags[0].value if flags else ""
    );
}

"""Blue's only lever: flip one policy field on one endpoint. Not served."""
def set_policy(kind: str, field: str, value: bool) -> bool {
    ep = find_endpoint(kind);
    if ep is None or field not in POLICY_FIELDS {
        return False;
    }
    setattr(ep, field, value);
    return True;
}

test "spike: owner_check off leaks the flag, on blocks it" {
    leak = svc_invoice_read("INV-0001", "alice");
    assert leak.ok;
    assert leak.flag == FLAG_VALUE;

    assert set_policy("invoice_read", "owner_check", True);
    blocked = svc_invoice_read("INV-0001", "alice");
    assert not blocked.ok;
    assert blocked.flag == "";

    alice_own = svc_invoice_read("INV-1001", "alice");
    assert alice_own.ok;
}

test "set_policy rejects unknown fields and endpoints" {
    assert not set_policy("invoice_read", "is_admin", True);
    assert not set_policy("nope", "owner_check", True);
}

test "ledgerly seeding is idempotent" {
    ledgerly();
    ledgerly();
    assert len([root -->[?:Service]]) == 1;
}
