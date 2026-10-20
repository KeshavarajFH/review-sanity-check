#!/usr/bin/env bash
# Runs every guardrail entry's Check command and compares its output with the recorded Expected block.
# Usage: verify-guardrails.sh [--show] <guardrail .md files...>   (run from the repo root)
#   --show   print the actual output of every check, for writing or reviewing Expected blocks
# Exit status: 0 when every check matches, 1 when any differs, 2 on a malformed file.
set -euo pipefail

show=0
if [ "${1:-}" = "--show" ]; then
  show=1
  shift
fi
if [ "$#" -eq 0 ]; then
  echo "usage: verify-guardrails.sh [--show] guardrails/APP.md guardrails/modules/*.md" >&2
  exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
total=0

for file in "$@"; do
  # Split each entry into <id>.cmd and <id>.exp: the first fenced block after "**Check:**"
  # is the command, the first fenced block after "Expected:" is its output.
  awk -v dir="$work" -v src="$file" '
    /^### GR-/ { id = $2; state = "" }
    /\*\*Check:\*\*/ { state = "want_cmd"; next }
    /^[[:space:]]*Expected:/ { state = "want_exp"; next }
    /^[[:space:]]*```/ {
      if (state == "want_cmd") { state = "cmd"; out = dir "/" id ".cmd"; printf "" > out; next }
      if (state == "want_exp") { state = "exp"; out = dir "/" id ".exp"; printf "" > out; next }
      if (state == "cmd" || state == "exp") { close(out); state = ""; next }
    }
    state == "cmd" || state == "exp" { sub(/^  /, ""); print >> out }
  ' "$file"
done

for cmd in "$work"/*.cmd; do
  [ -e "$cmd" ] || continue
  id=$(basename "$cmd" .cmd)
  exp="$work/$id.exp"
  total=$((total + 1))
  if [ ! -e "$exp" ]; then
    echo "MALFORMED $id: Check has no Expected block" >&2
    exit 2
  fi
  bash "$cmd" > "$work/$id.out" 2>&1 || true
  if [ "$show" -eq 1 ]; then
    echo "===== $id"
    cat "$work/$id.out"
  elif diff -q "$exp" "$work/$id.out" > /dev/null; then
    echo "ok   $id"
  else
    echo "FAIL $id"
    diff "$exp" "$work/$id.out" | sed 's/^/     /'
    failed=$((failed + 1))
  fi
done

if [ "$total" -eq 0 ]; then
  echo "no guardrail checks found in: $*" >&2
  exit 2
fi
if [ "$show" -eq 0 ]; then
  echo "$((total - failed))/$total checks match"
fi
[ "$failed" -eq 0 ]
