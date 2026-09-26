"""Blue -- the defender agent. It rewrites the target's SOURCE CODE to close a
hole Red just exploited.

Unlike v1 (which flipped a policy field), Blue here returns a full patched copy
of the file as a typed `by llm` value. The file is small, so a full rewrite is
more reliable than a diff. Blue never touches the game engine -- only the target
source string -- and every patch is gated by the deterministic referee, so a bad
rewrite is caught and reverted, never shipped.
"""

import from jaclang.byllm.lib { Model }

glob patcher: Model = Model(model_name="gemini/gemini-3.5-flash");

obj ExploitBrief {
    has vuln_class: str,
        method: str,
        path: str,
        as_user: str,
        evidence: str;
}
sem ExploitBrief = "A single confirmed exploit Blue must close by editing the code.";
sem ExploitBrief.vuln_class = "The vulnerability class Red reported (e.g. IDOR, BROKEN_ACCESS, DEBUG_LEAK).";
sem ExploitBrief.method = "HTTP method of the request that breached.";
sem ExploitBrief.path = "URL path that leaked protected data.";
sem ExploitBrief.as_user = "The identity Red used (a low-privilege user, or empty for anonymous).";
sem ExploitBrief.evidence = "One line on what leaked -- the flag was returned where it should not be.";

obj Patch {
    has new_source: str,
        summary: str;
}
sem Patch = "The full rewritten source file plus a one-line summary of the fix.";
sem Patch.new_source = "The COMPLETE contents of the fixed Python file -- every line, ready to save and run. Fix ONLY the one endpoint named in the exploit; do NOT modify, harden, or touch any other route or handler even if it also looks insecure -- those are out of scope this turn. Keep the module docstring and all other behavior byte-for-byte identical so legitimate requests still work. Do not wrap it in markdown fences.";
sem Patch.summary = "One sentence naming the fix, e.g. 'Enforce owner check on GET /invoices/<id>'.";

sem write_patch = "You are Blue, a secure-coding agent. You are given the full source of a small Flask app and ONE confirmed exploit against ONE endpoint. Make the smallest correct change that closes exactly that one endpoint's hole (add the missing authorization or ownership check, disable the debug leak, etc.). Do NOT fix or harden any other endpoint, even if you notice it is also vulnerable -- fixing only what was exploited is the point, so the attacker must find each hole separately. Keep every legitimate request working: users must still read their OWN data, and admins must still read everything. Return the complete fixed file.";
sem write_patch.source = "The current full source of the target Flask app.";
sem write_patch.exploit = "The confirmed exploit to close.";
sem write_patch.feedback = "Empty on the first try. If a previous attempt was rejected, this explains why (e.g. it broke a health check or left the hole open) -- fix accordingly.";
def write_patch(source: str, exploit: ExploitBrief, feedback: str) -> Patch by patcher(temperature=0.1);
