"""Live progress of the round in flight, kept in server memory so every viewer
(any tab, a projector) sees the same truth while Red or Blue is working: the
phase, the round, which draft Blue is on, and each referee ruling as it lands.

This is process memory, not graph state: it describes work in progress, and it
must be readable by a concurrent request while the round's own request is still
running (graph writes only become visible when that request finishes)."""

import time;

obj LiveInfo {
    has phase: str,
        round_n: int,
        draft: int,
        elapsed_s: int,
        events: list[str];
}

glob LIVE: dict[str, any] = {
    "phase": "idle", "round_n": 0, "draft": 0, "started": 0.0, "events": []
};

def live_begin(phase: str, round_n: int) {
    LIVE["phase"] = phase;
    LIVE["round_n"] = round_n;
    LIVE["draft"] = 0;
    LIVE["started"] = time.time();
    LIVE["events"] = [];
}

def live_draft(n: int) {
    LIVE["draft"] = n;
}

def live_event(msg: str) {
    LIVE["events"] = LIVE["events"] + [msg];
}

def live_end {
    LIVE["phase"] = "idle";
    LIVE["draft"] = 0;
}

"""What is happening right now. phase is idle | red | blue."""
def:pub get_live -> LiveInfo {
    elapsed = 0;
    if LIVE["phase"] != "idle" {
        elapsed = int(time.time() - LIVE["started"]);
    }
    return LiveInfo(
        phase=LIVE["phase"], round_n=LIVE["round_n"], draft=LIVE["draft"],
        elapsed_s=elapsed, events=LIVE["events"]
    );
}

test "live progress tracks a phase, drafts and events, then goes idle" {
    live_begin("blue", 3);
    live_draft(1);
    live_event("draft 1 rejected: still breaches");
    live_draft(2);
    li = get_live();
    assert li.phase == "blue";
    assert li.round_n == 3;
    assert li.draft == 2;
    assert len(li.events) == 1;
    live_end();
    assert get_live().phase == "idle";
    live_begin("red", 4);
    assert len(get_live().events) == 0;
    live_end();
}
