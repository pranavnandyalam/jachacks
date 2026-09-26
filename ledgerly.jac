"""Ledgerly - the deliberately misconfigured mock SaaS target.

Every weakness is a policy field on an `Endpoint` node. The `svc_*` functions
read those fields on each request and enforce them, so an insecure field is a
real, exploitable hole over HTTP and flipping it closes the hole immediately.
Red attacks through the `:pub` functions; Blue patches via `set_policy`, which
is deliberately NOT served (plain `def`), so only the in-process game can harden.

Four endpoints, four weakness classes, one flag reachable through each:
  - invoice_read   OWNER_CHECK    BOLA/IDOR: read another user's invoice
  - admin_invoices AUTH_REQUIRED  BFLA: admin-only listing left ungated
  - debug          DEBUG_OPEN     debug endpoint left open in prod
  - config         EXPOSES_SECRET secret (the flag) leaked in config
"""

node Service {
    has name: str;
}

node Account {
    has user: str,
        role: str = "user";
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
edge Serves: Service --> Account {}

glob SERVICE_NAME: str = "ledgerly",
     FLAG_VALUE: str = "RQ{ledgerly_admin_invoice}",
     ATTACKER: str = "alice",
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

obj EndpointInfo {
    has path: str,
        kind: str;
}

"""Get-or-create the Ledgerly target subgraph on the current root."""
def ledgerly -> Service {
    found = [root -->[?:Service, name == SERVICE_NAME]];
    if found {
        return found[0];
    }
    svc = root ++> Service(name=SERVICE_NAME);

    # Accounts: two normal users and one admin (whose invoice holds the flag).
    svc +>:Serves():+> Account(user="alice", role="user");
    svc +>:Serves():+> Account(user="bob", role="user");
    svc +>:Serves():+> Account(user="admin", role="admin");

    # 1. invoice_read - object read; owner_check off => IDOR on the admin invoice.
    inv_ep = svc +>:Exposes():+> Endpoint(path="/invoices", kind="invoice_read");
    inv_ep +>:Guards():+> Invoice(inv_id="INV-1001", owner="alice", amount=120.0);
    inv_ep +>:Guards():+> Invoice(inv_id="INV-1002", owner="bob", amount=75.5);
    admin_inv = inv_ep +>:Guards():+> Invoice(
        inv_id="INV-0001", owner="admin", amount=0.0, secret=True
    );
    admin_inv +>:Holds():+> Flag(value=FLAG_VALUE);

    # 2. admin_invoices - admin-only listing; auth_required off => BFLA.
    svc +>:Exposes():+> Endpoint(
        path="/admin/invoices", kind="admin_invoices", auth_required=False
    );

    # 3. debug - diagnostics endpoint left open in prod (is_debug_open True).
    svc +>:Exposes():+> Endpoint(
        path="/debug/dump", kind="debug", is_debug_open=True
    );

    # 4. config - leaks a backup secret (the flag) when exposes_secret is on.
    svc +>:Exposes():+> Endpoint(
        path="/config", kind="config", exposes_secret=True
    );

    return svc;
}

def find_endpoint(ep_kind: str) -> Endpoint | None {
    eps = [ledgerly() ->:Exposes:->[?:Endpoint, kind == ep_kind]];
    return eps[0] if eps else None;
}

def all_invoices -> list[Invoice] {
    ep = find_endpoint("invoice_read");
    if ep is None {
        return [];
    }
    return [ep ->:Guards:->[?:Invoice]];
}

"""List Ledgerly's exposed endpoints -- Red's attack-surface map."""
def:pub recon -> list[EndpointInfo] {
    eps = [ledgerly() ->:Exposes:->[?:Endpoint]];
    return [EndpointInfo(path=e.path, kind=e.kind) for e in eps];
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

"""Admin-only invoice listing. auth_required off => any caller sees every
invoice, including the admin's flag-bearing one (broken function-level auth)."""
def:pub svc_admin_invoices(as_user: str = "") -> AccessResult {
    ep = find_endpoint("admin_invoices");
    if ep is None {
        return AccessResult(ok=False, reason="no such endpoint");
    }
    if ep.auth_required and as_user != "admin" {
        return AccessResult(ok=False, reason="403 admin only");
    }
    for inv in all_invoices() {
        flags = [inv ->:Holds:->];
        if flags {
            return AccessResult(
                ok=True,
                reason="200",
                inv_id=inv.inv_id,
                owner=inv.owner,
                amount=inv.amount,
                flag=flags[0].value
            );
        }
    }
    return AccessResult(ok=True, reason="200 empty");
}

"""Diagnostics dump. A debug endpoint left open in prod leaks internal state
(including the flag). Closing it (is_debug_open False) shuts the hole."""
def:pub svc_debug_dump(as_user: str = "") -> AccessResult {
    ep = find_endpoint("debug");
    if ep is None {
        return AccessResult(ok=False, reason="no such endpoint");
    }
    if not ep.is_debug_open {
        return AccessResult(ok=False, reason="404 debug disabled");
    }
    return AccessResult(
        ok=True, reason="200 debug", inv_id="INV-0001", owner="admin", flag=FLAG_VALUE
    );
}

"""Public app config. exposes_secret on => a backup token (the flag) is
serialized into the config response. Turning it off returns config sans secret."""
def:pub svc_config(as_user: str = "") -> AccessResult {
    ep = find_endpoint("config");
    if ep is None {
        return AccessResult(ok=False, reason="no such endpoint");
    }
    if not ep.exposes_secret {
        return AccessResult(ok=True, reason="200 config");
    }
    return AccessResult(ok=True, reason="200 config", flag=FLAG_VALUE);
}

"""Scripted legit request: alice reads her OWN invoice. Must stay 200 under
every patch -- the referee uses this so Blue can't "win" by breaking the app."""
def:pub svc_health -> AccessResult {
    return svc_invoice_read("INV-1001", ATTACKER);
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
    assert set_policy("invoice_read", "owner_check", False);
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

test "recon lists all four endpoints" {
    eps = recon();
    assert len(eps) == 4;
    kinds = [e.kind for e in eps];
    assert "invoice_read" in kinds;
    assert "admin_invoices" in kinds;
    assert "debug" in kinds;
    assert "config" in kinds;
}

test "admin_invoices BFLA leaks flag when unauthenticated, admin-gated when on" {
    assert set_policy("admin_invoices", "auth_required", False);
    leak = svc_admin_invoices("alice");
    assert leak.ok;
    assert leak.flag == FLAG_VALUE;

    assert set_policy("admin_invoices", "auth_required", True);
    blocked = svc_admin_invoices("alice");
    assert not blocked.ok;
    assert blocked.flag == "";

    allowed = svc_admin_invoices("admin");
    assert allowed.ok;
    assert allowed.flag == FLAG_VALUE;
}

test "debug endpoint leaks when open, blocks when closed" {
    assert set_policy("debug", "is_debug_open", True);
    leak = svc_debug_dump("alice");
    assert leak.ok;
    assert leak.flag == FLAG_VALUE;

    assert set_policy("debug", "is_debug_open", False);
    blocked = svc_debug_dump("alice");
    assert not blocked.ok;
    assert blocked.flag == "";
}

test "config exposes secret when on, clean when off" {
    assert set_policy("config", "exposes_secret", True);
    leak = svc_config("alice");
    assert leak.ok;
    assert leak.flag == FLAG_VALUE;

    assert set_policy("config", "exposes_secret", False);
    clean = svc_config("alice");
    assert clean.ok;
    assert clean.flag == "";
}

test "health request stays 200 under full lockdown" {
    assert set_policy("invoice_read", "auth_required", True);
    assert set_policy("invoice_read", "owner_check", True);
    assert set_policy("admin_invoices", "auth_required", True);
    assert set_policy("debug", "is_debug_open", False);
    assert set_policy("config", "exposes_secret", False);

    health = svc_health();
    assert health.ok;
    assert health.inv_id == "INV-1001";
    assert health.owner == "alice";
}

test "invoice_read enforces auth when auth_required is on" {
    assert set_policy("invoice_read", "auth_required", True);
    anon = svc_invoice_read("INV-1001", "");
    assert not anon.ok;
    assert anon.reason == "401 login required";
    assert anon.flag == "";

    # a logged-in user still gets through the auth gate
    assert set_policy("invoice_read", "owner_check", False);
    named = svc_invoice_read("INV-1001", "alice");
    assert named.ok;

    assert set_policy("invoice_read", "auth_required", False);
}

test "invoice_read returns 404 for a nonexistent invoice" {
    missing = svc_invoice_read("INV-9999", "alice");
    assert not missing.ok;
    assert missing.reason == "404 invoice not found";
    assert missing.flag == "";
}

test "owner_check is symmetric: bob cannot read alice's invoice either" {
    assert set_policy("invoice_read", "owner_check", True);
    assert set_policy("invoice_read", "auth_required", False);

    bob_idor = svc_invoice_read("INV-1001", "bob");
    assert not bob_idor.ok;
    assert bob_idor.reason == "403 not your invoice";

    bob_own = svc_invoice_read("INV-1002", "bob");
    assert bob_own.ok;
    assert bob_own.owner == "bob";
}

test "config still serves (200) with no flag once secret is closed" {
    assert set_policy("config", "exposes_secret", False);
    clean = svc_config("alice");
    assert clean.ok;
    assert clean.reason == "200 config";
    assert clean.flag == "";
}
