"""Three-part explainer so a first-time viewer can read the match."""

def:pub HowItWorks -> JsxElement {
    <div className="how">
        <div className="how-item red">
            <span className="tag tag-red">RED</span>
            <p>{"Attacker agent. Reads the app's source code, picks one HTTP request it thinks will leak the secret flag, and fires it. If the flag comes back, that's a breach."}</p>
        </div>
        <div className="how-item blue">
            <span className="tag tag-blue">BLUE</span>
            <p>{"Defender agent. Rewrites the code of the one endpoint Red just broke. Edits anywhere else are discarded."}</p>
        </div>
        <div className="how-item ref">
            <span className="tag tag-ref">REFEREE</span>
            <p>{"No AI, fully deterministic. Re-runs Red's exploit, every earlier exploit, and 8 normal-user checks in a sandbox. A patch ships only if all of them pass."}</p>
        </div>
    </div>
}
