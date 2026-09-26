#!/usr/bin/env bash
# PostToolUse hook: after Claude edits a .jac file, type-check it with the real
# compiler. Errors are fed back to Claude (exit 2) so it fixes them immediately;
# warnings are passed through as a non-blocking note.
set -uo pipefail

payload="$(cat)"
file="$(printf '%s' "$payload" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("tool_input") or {}).get("file_path",""))' 2>/dev/null)"

[[ "$file" == *.jac ]] || exit 0
[[ -f "$file" ]] || exit 0

JAC="$(command -v jac || echo "$HOME/.local/bin/jac")"
[[ -x "$JAC" ]] || { echo "jac-check hook: jac not installed (curl -fsSL https://raw.githubusercontent.com/jaseci-labs/jaseci/main/scripts/install.sh | bash)" >&2; exit 0; }

# Annexes (.impl.jac / .test.jac) belong to a base module; check the base.
target="$file"
case "$file" in
  *.impl.jac) base="${file%.impl.jac}.jac"; [[ -f "$base" ]] && target="$base" ;;
  *.test.jac) base="${file%.test.jac}.jac"; [[ -f "$base" ]] && target="$base" ;;
esac

# Run from the nearest jac.toml so project-root imports resolve.
dir="$(dirname "$target")"
root="$dir"
while [[ "$root" != "/" && ! -f "$root/jac.toml" ]]; do root="$(dirname "$root")"; done
[[ -f "$root/jac.toml" ]] || root="$dir"

out="$(cd "$root" && "$JAC" check "$target" 2>&1)"
status=$?

# Keep only the diagnostic header + location + help lines (the full render is noisy),
# and drop two known false-positive warnings jac 0.37.23 emits even on a pristine
# `jac create --kind web-app` scaffold: W2001 on JSX HTML tag names and W2003 on
# the generated React `setX` state setters. Real undefined names (e.g. `false`)
# are NOT tag names, so they still surface.
TAGS='a|abbr|article|aside|audio|b|blockquote|body|br|button|canvas|code|dd|details|div|dl|dt|em|fieldset|figure|footer|form|h1|h2|h3|h4|h5|h6|header|hr|i|iframe|img|input|label|legend|li|main|nav|ol|option|p|pre|section|select|small|span|strong|sub|summary|sup|svg|path|table|tbody|td|textarea|th|thead|tr|u|ul|video'
summary="$(printf '%s\n' "$out" \
  | grep -E 'error\[|warning\[|^\s*-->|^help:' \
  | awk -v tags="^($TAGS)\$" '
      /warning\[W2001\]: Name / { n=$0; sub(/.*Name \x27/,"",n); sub(/\x27.*/,"",n); if (n ~ tags) { skip=2; next } }
      /warning\[W2003\]: \x27set[A-Z]/ { skip=2; next }
      skip > 0 && /^\s*-->/ { skip--; next }
      skip > 0 && /^help:/ { next }
      { skip=0; print }' \
  | head -60)"

# Stale-pattern reminders the compiler does not flag.
notes=""
if grep -qE '(walker|def):priv' "$target" 2>/dev/null; then
  notes+=$'\n- NOTE: `:priv` walkers/defs are NOT served as endpoints (jac >= 0.37.22). Use `:protect` for authenticated per-user endpoints, `:pub` for anonymous.'
fi

if [[ $status -ne 0 ]]; then
  {
    echo "jac check FAILED for ${target#$root/} — fix these before continuing:"
    echo "$summary"
    echo "$notes"
    echo "(Follow the 'jac guide <name>' hints; run 'jac check ${target#$root/}' for the full render.)"
  } >&2
  exit 2
fi

warnings="$(printf '%s\n' "$summary" | grep -E 'warning\[' -A1 | grep -v '^--$' | head -20)"
if [[ -n "$warnings" || -n "$notes" ]]; then
  # Non-blocking: surface warnings (unused names W2003 etc.) without stopping work.
  {
    echo "jac check passed with warnings for ${target#$root/}:"
    [[ -n "$warnings" ]] && echo "$warnings"
    [[ -n "$notes" ]] && echo "$notes"
  } >&2
fi
exit 0
