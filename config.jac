"""Single source of truth for which app the game runs against. Everything
app-specific (source path, manifest path, the attacker's login, the secret hint
Red is given) is read from here, so a new target is a drop-in: put app.py +
manifest.json in a folder and point TARGET_DIR at it."""

import os;
import json;

# The default target when nothing has been picked (env or "target").
glob TARGET_DIR: str = os.environ.get("RQ_TARGET_DIR", "target");

# The picked target persists on the graph so the dashboard can switch sites at
# runtime; falls back to TARGET_DIR when nothing is picked yet.
node TargetChoice {
    has dir: str;
}

def active_dir -> str {
    found = [root -->[?:TargetChoice]];
    if found {
        return found[0].dir;
    }
    return TARGET_DIR;
}

"""Switch the active target to `name` (a folder with a manifest.json). Returns
False if there's no such target."""
def:pub set_active_target(name: str) -> bool {
    if not os.path.isfile(os.path.join(name, "manifest.json")) {
        return False;
    }
    found = [root -->[?:TargetChoice]];
    if found {
        found[0].dir = name;
    } else {
        root ++> TargetChoice(dir=name);
    }
    return True;
}

obj TargetInfo {
    has dir: str,
        name: str,
        mode: str,
        files: int,
        active: bool;
}

"""Every example site available to pick: `target/` plus each folder under
`targets/` that has a manifest. mode is 'fix' (full harden loop, single-file
Flask we can run) or 'scan' (find-only, e.g. other languages)."""
def:pub list_targets -> list[TargetInfo] {
    dirs: list[str] = [];
    if os.path.isfile(os.path.join("target", "manifest.json")) {
        dirs = dirs + ["target"];
    }
    for base in ["targets", "testsites/apps"] {
        if os.path.isdir(base) {
            for d in sorted(os.listdir(base)) {
                full = os.path.join(base, d);
                if os.path.isfile(os.path.join(full, "manifest.json")) {
                    dirs = dirs + [full];
                }
            }
        }
    }
    cur = active_dir();
    out: list[TargetInfo] = [];
    for d in dirs {
        m: dict[str, any] = json.loads(open(os.path.join(d, "manifest.json")).read());
        nfiles = len(m.get("files", [m.get("entry", "app.py")]));
        out = out + [TargetInfo(
            dir=d, name=m.get("name", d), mode=m.get("mode", "fix"),
            files=nfiles, active=(d == cur)
        )];
    }
    return out;
}

def target_source_path -> str {
    return os.path.join(active_dir(), "app.py");
}

def target_manifest_path -> str {
    return os.path.join(active_dir(), "manifest.json");
}

def read_manifest -> dict[str, any] {
    parsed: dict[str, any] = json.loads(open(target_manifest_path()).read());
    return parsed;
}

"""The login Red attacks as (a low-privilege user), from the manifest."""
def attacker_user -> str {
    m = read_manifest();
    return m.get("attacker", "");
}

"""The display name of the target app, from the manifest."""
def target_name -> str {
    m = read_manifest();
    return m.get("name", TARGET_DIR);
}

"""One line telling Red what secret to try to leak and who it is. Kept in the
manifest, NOT in the agent's prompt, so swapping the target swaps the hint --
and a manifest can give only a vague hint for a genuine unseen-code test."""
def secret_hint -> str {
    m = read_manifest();
    who = m.get("attacker", "a low-privilege user");
    hint = m.get("secret_hint", "A secret value exists that only privileged users should be able to read.");
    return "You are logged in only as '" + who + "'. " + hint;
}
