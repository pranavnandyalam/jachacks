"""Ask Red Queen: a voice button that opens a live ElevenLabs conversation with
an agent that explains the audit on screen. It starts with a brief of the
current audit and gets a fresh brief pushed in whenever a pass lands, so it can
talk about what just happened."""

import from "react" { useEffect }
import from "@elevenlabs/react" { ConversationProvider, useConversation }
import from ..voice { VoiceSession, voice_session, voice_brief }

"""`stamp` changes whenever the audit moves (site + pass count); a live session
gets the new brief then."""
def:pub VoiceGuide(stamp: str) -> JsxElement {
    <ConversationProvider>
        <VoiceButton stamp={stamp}/>
    </ConversationProvider>
}

def:pub VoiceButton(stamp: str) -> JsxElement {
    has err: str = "",
        starting: bool = False;

    conv = useConversation({
        "onError": lambda (m: any) { err = "Voice error: " + String(m); }
    });
    live: bool = conv.status == "connected";

    async def start {
        starting = True;
        err = "";
        try {
            s: VoiceSession = await voice_session();
            if s.error {
                err = s.error;
            } else {
                brief: str = await voice_brief();
                conv.startSession({"signedUrl": s.signed_url, "dynamicVariables": {"audit_brief": brief}});
            }
        } except Exception as e {
            err = "Couldn't start voice: " + String(e);
        }
        starting = False;
    }

    def stop {
        conv.endSession();
    }

    async def push_update {
        try {
            brief: str = await voice_brief();
            conv.sendContextualUpdate("The audit on screen just changed. Current state:\n" + brief);
        } except Exception {
            err = "";
        }
    }

    useEffect(lambda {
        if conv.status == "connected" {
            push_update();
        }
    }, [stamp]);

    label: str = "Ask Red Queen";
    if starting or conv.status == "connecting" {
        label = "Connecting...";
    } elif live {
        label = "Speaking... (end)" if conv.isSpeaking else "Listening... (end)";
    }

    <span className="voice">
        <button type="button"
            className={"btn voice-btn" + (" is-live" if live else "")}
            disabled={starting or conv.status == "connecting"}
            onClick={stop if live else start}
            title="Ask the Red Queen about any vulnerability on screen">
            <span className={"voice-dot" + (" is-speaking" if live and conv.isSpeaking else "")} aria-hidden="true"></span>
            {label}
        </button>
        {if err {
            <span className="voice-err" role="alert">{err}</span>
        }}
    </span>
}
