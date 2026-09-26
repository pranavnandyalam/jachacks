#!/usr/bin/env bash
# jac-install-safe.sh [--dev] [pkg ...]
#
# `jac install` with a fallback for a bug in the jac 0.37.23 macOS-arm64 binary:
# its bundled python3.14 cannot import `_posixsubprocess` ("symbol not found in
# flat namespace '_PyBytes_AsString'"), so creating `.jac/venv` fails and PyPI
# deps (litellm for by llm(), etc.) never install. npm installs are unaffected.
#
# Fallback: build .jac/venv with a real CPython 3.14 (same minor as jac's runtime)
# and install exactly the packages jac resolved (`jac install --plan --json`).
# Run from the project root (the directory holding jac.toml).
set -uo pipefail

JAC="$(command -v jac || echo "$HOME/.local/bin/jac")"
dev=0
pkgs=()
for a in "$@"; do
  case "$a" in
    --dev|-d) dev=1 ;;
    *) pkgs+=("$a") ;;
  esac
done

[[ -f jac.toml ]] || { echo "jac-install-safe: run from the project root (no jac.toml here)" >&2; exit 1; }

log="$(mktemp)"
if [[ ${#pkgs[@]} -gt 0 ]]; then
  "$JAC" install "${pkgs[@]}" $([[ $dev == 1 ]] && echo --dev) 2>&1 | tee "$log"
else
  "$JAC" install $([[ $dev == 1 ]] && echo --dev) 2>&1 | tee "$log"
fi
status=${PIPESTATUS[0]}

if [[ $status -eq 0 ]] && ! grep -q "Error executing 'install'" "$log"; then
  rm -f "$log"; exit 0
fi
if ! grep -q "_posixsubprocess" "$log"; then
  echo "jac-install-safe: jac install failed for a different reason (see above); not applying the venv fallback." >&2
  rm -f "$log"; exit 1
fi
rm -f "$log"

echo ""
echo "jac-install-safe: hit the bundled-runtime venv bug -> building .jac/venv with system CPython 3.14"

# Find a CPython 3.14.
py=""
if command -v uv >/dev/null 2>&1; then
  py="$(uv python find 3.14 2>/dev/null || true)"
  [[ -n "$py" ]] || { uv python install 3.14 >/dev/null 2>&1 && py="$(uv python find 3.14 2>/dev/null || true)"; }
fi
for c in "$py" /opt/homebrew/bin/python3.14 /usr/local/bin/python3.14 "$(command -v python3.14 2>/dev/null)"; do
  [[ -n "$c" && -x "$c" ]] && { py="$c"; break; }
done
[[ -n "$py" ]] || { echo "jac-install-safe: need Python 3.14 (brew install python@3.14, or install uv)" >&2; exit 1; }

# Resolved plan -> pip specs (python ecosystem; dev deps only with --dev).
parser="$(mktemp)"
cat > "$parser" <<'PY'
import json, sys
dev = sys.argv[1] == "1"
for d in json.load(sys.stdin):
    if d.get("ecosystem") != "python" or (d.get("dev") and not dev):
        continue
    url = d.get("url") or ""
    if d.get("source") == "git" and url:
        print("git+" + url)
        continue
    v = d.get("version") or ""
    if v and v[0] not in "<>=!~":
        v = "==" + v
    print(d["name"] + v)
PY
plan="$("$JAC" install --plan --json 2>/dev/null)" || { echo "jac-install-safe: 'jac install --plan --json' failed" >&2; exit 1; }
specs="$(printf '%s' "$plan" | "$py" "$parser" "$dev")" || { echo "jac-install-safe: could not parse the install plan" >&2; rm -f "$parser"; exit 1; }
rm -f "$parser"

rm -rf .jac/venv
"$py" -m venv .jac/venv || exit 1
if [[ -z "$specs" ]]; then
  echo "jac-install-safe: no Python packages in the plan; venv created."
else
  echo "Installing:"; echo "$specs" | sed 's/^/  /'
  if command -v uv >/dev/null 2>&1; then
    echo "$specs" | xargs uv pip install --python .jac/venv/bin/python || exit 1
  else
    echo "$specs" | xargs .jac/venv/bin/python -m pip install -q || exit 1
  fi
fi

if grep -q '^\[dependencies\.npm' jac.toml; then
  echo "Installing npm dependencies (unaffected by the bug)..."
  "$JAC" install --npm || exit 1
fi
echo "jac-install-safe: done."
