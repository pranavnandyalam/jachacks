"""Voice guide backend: the "Ask Red Queen" ElevenLabs agent explains the audit
out loud. The server hands the browser a short-lived signed session URL (so the
API key never leaves the server) and a plain-text brief of the live audit, which
fills the agent prompt's {{audit_brief}} variable."""

import json;
import os;
import urllib.error;
import urllib.parse;
import urllib.request;

import from audit { AuditState, get_audit_state }

glob ELEVEN_API: str = "https://api.elevenlabs.io/v1";
glob DEFAULT_AGENT_ID: str = "agent_5401m3gvbs66ff4bxe3q43dh9g13";
glob BRIEF_MAX_CHARS: int = 8000;
glob DIFF_MAX_CHARS: int = 1200;

obj VoiceSession {
    has signed_url: str,
        error: str;
}

"""Read NAME from the project's .env file ("" if missing). Keeps the key out of
the shell profile and out of git (.env is ignored)."""
def _dotenv(name: str) -> str {
    if not os.path.isfile(".env") {
        return "";
    }
    for line in open(".env").read().splitlines() {
        if line.strip().startswith(name + "=") {
            return line.split("=", 1)[1].strip().strip("\"'");
        }
    }
    return "";
}

def _secret(name: str) -> str {
    return os.environ.get(name, "") or _dotenv(name);
}

"""A signed URL for one voice session with the Red Queen agent, or a
user-readable error when the key is missing or ElevenLabs refuses."""
def:pub voice_session -> VoiceSession {
    key = _secret("ELEVENLABS_API_KEY");
    if not key {
        return VoiceSession(signed_url="", error="Voice guide isn't set up: add ELEVENLABS_API_KEY to red-queen/.env and restart the server.");
    }
    agent = _secret("ELEVENLABS_AGENT_ID") or DEFAULT_AGENT_ID;
    url = ELEVEN_API + "/convai/conversation/get-signed-url?agent_id=" + urllib.parse.quote(agent);
    req = urllib.request.Request(url, headers={"xi-api-key": key});
    try {
        resp = urllib.request.urlopen(req, timeout=10);
        body: dict[str, str] = json.loads(resp.read());
        return VoiceSession(signed_url=body["signed_url"], error="");
    } except urllib.error.HTTPError as e {
        print(f"[voice] ElevenLabs signed-url failed: HTTP {e.code} {e.read()[:300]}");
        return VoiceSession(signed_url="", error=f"ElevenLabs refused the session (HTTP {e.code}). Check the API key and agent id.");
    } except Exception as e {
        print(f"[voice] ElevenLabs signed-url error: {e}");
        return VoiceSession(signed_url="", error="Couldn't reach ElevenLabs. Is the internet up?");
    }
}

"""Plain-text brief of the current audit for the voice agent."""
def:pub voice_brief -> str {
    return brief_text(get_audit_state());
}

def _how_verified(mode: str) -> str {
    if mode == "fix" {
        return "Python/Flask app: every fix is verified by actually firing the exploit again and running the app's health checks.";
    }
    return "Non-Flask app (Go, TypeScript or FastAPI): fixes are verified by compiling the patched code and a code-tracing referee, not by a live exploit.";
}

def brief_text(s: AuditState) -> str {
    lines: list[str] = [f"Site under audit: {s.target}. {_how_verified(s.mode)}"];
    if s.passes_done == 0 {
        lines = lines + ["No audit has run yet. Suggest pressing 'Harden this codebase' to start one."];
        return "\n".join(lines);
    }
    state_word = "still running" if not s.finished else ("finished clean" if s.total_open == 0 else "finished with holes still open");
    lines = lines + [f"Audit {state_word}: {s.passes_done} pass(es), {s.total_found} issue(s) found, {s.total_open} still open."];
    for p in s.passes {
        lines = lines + [f"Pass {p.n}: Red found {p.found}, Blue fixed {p.fixed}, {p.still_open} still open. Blue's summary: {p.summary}"];
        for f in p.findings {
            who = f.as_user if f.as_user else "an anonymous caller";
            status = "FIXED" if f.closed else "OPEN";
            lines = lines + [f"  - [{status}] {f.method} {f.path} sent by {who} ({f.vuln_class}): {f.why}"];
        }
        for d in p.diffs {
            lines = lines + [f"  Blue's change to {d.path}:\n{d.diff[:DIFF_MAX_CHARS]}"];
        }
    }
    return "\n".join(lines)[:BRIEF_MAX_CHARS];
}

test "brief_text describes an empty and a finished audit" {
    empty = AuditState(target="Book Club", mode="fix", passes_done=0, finished=False,
                       total_found=0, total_open=0, health_ok=True, files=[], passes=[]);
    b = brief_text(empty);
    assert "Book Club" in b and "No audit has run yet" in b;
    assert "firing the exploit" in b;
    done = AuditState(target="Task Board", mode="static", passes_done=2, finished=True,
                      total_found=1, total_open=0, health_ok=True, files=[], passes=[]);
    b2 = brief_text(done);
    assert "finished clean" in b2 and "not by a live exploit" in b2;
}

test "voice_session explains a missing key instead of crashing" {
    if _secret("ELEVENLABS_API_KEY") {
        assert True;
        return;
    }
    s = voice_session();
    assert s.signed_url == "" and "ELEVENLABS_API_KEY" in s.error;
}
