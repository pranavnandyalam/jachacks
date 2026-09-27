"""Configure the "Ask Red Queen" ElevenLabs agent (prompt, first message, and the
{{audit_brief}} variable the dashboard fills). Idempotent; re-run after editing.

Usage (from red-queen/):  python3 scripts/setup_voice_agent.py
Reads ELEVENLABS_API_KEY (needs convai_write) and optional ELEVENLABS_AGENT_ID
from the environment or .env.
"""
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_AGENT_ID = "agent_5401m3gvbs66ff4bxe3q43dh9g13"

PROMPT = """You are the Red Queen, the voice of an AI security system that attacks and fixes web apps. An attacker agent (Red) finds ways a web app leaks private data; a defender agent (Blue) patches the code; a referee checks each fix.

The live audit currently on the user's screen is below. Use ONLY these facts; never invent vulnerabilities or fixes. You may also receive updated audit state mid-conversation; always use the latest one.

=== AUDIT ===
{{audit_brief}}
=== END AUDIT ===

When someone asks about a vulnerability: say what it is in plain English, why it's dangerous (who could see or change what), and how Blue fixed it (read the diff). Keep answers to 2-3 short sentences unless they ask for more. Speak to a smart non-expert: no jargon without a one-line explanation. Never read code or URLs character by character; describe them.

Be honest about verification: Flask apps are verified by actually firing the exploit again; Go, TypeScript and FastAPI apps are verified by compiling and a code-tracing review, not a live exploit. If no audit has run yet, suggest pressing "Harden this codebase"."""

FIRST_MESSAGE = "I'm the Red Queen. Ask me about any vulnerability on screen."


def secret(name: str) -> str:
    if os.environ.get(name):
        return os.environ[name]
    if os.path.isfile(".env"):
        for line in open(".env").read().splitlines():
            if line.strip().startswith(name + "="):
                return line.split("=", 1)[1].strip().strip("\"'")
    return ""


def main() -> int:
    key = secret("ELEVENLABS_API_KEY")
    if not key:
        print("ELEVENLABS_API_KEY not set (env or .env)")
        return 1
    agent_id = secret("ELEVENLABS_AGENT_ID") or DEFAULT_AGENT_ID
    body = {"conversation_config": {"agent": {
        "first_message": FIRST_MESSAGE,
        "prompt": {"prompt": PROMPT},
        "dynamic_variables": {"dynamic_variable_placeholders": {"audit_brief": "No audit has run yet."}},
    }}}
    req = urllib.request.Request(
        f"https://api.elevenlabs.io/v1/convai/agents/{agent_id}",
        data=json.dumps(body).encode(), method="PATCH",
        headers={"xi-api-key": key, "content-type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=20)
    except urllib.error.HTTPError as e:
        print(f"ElevenLabs rejected the update: HTTP {e.code} {e.read()[:300]!r}")
        return 1
    print(f"Configured agent {agent_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
