#!/usr/bin/env bash
# Runs the Detector of every rule in RULES.md over the lines a branch adds.
# Usage (from the repo root): check-rules.sh [--drafts] [--rule ID] <base> <tip> [rules-file]
#   --drafts   also run rules whose Status is draft (default: approved only)
#   --rule ID  run only this rule
# Each Detector is bash run with these set:
#   BASE, TIP  the two refs
#   ADDED      a file of "path:line<TAB>text" for every line the branch adds (deleted files excluded)
# and prints one "path:line — text" per violation. Output: "RULE-ID path:line — text".
# A detector must exit 0 (end searches with `|| true`); a non-zero exit is a broken detector.
# Exit status: 0 no violations, 1 violations, 2 usage error, malformed file or broken detector.
set -euo pipefail

drafts=0
only=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --drafts) drafts=1; shift ;;
    --rule) only=$2; shift 2 ;;
    *) break ;;
  esac
done
if [ "$#" -lt 2 ]; then
  echo "usage: check-rules.sh [--drafts] [--rule ID] <base> <tip> [rules-file]" >&2
  exit 2
fi
BASE=$1
TIP=$2
rules=${3:-guardrails/RULES.md}
[ -f "$rules" ] || { echo "check-rules: $rules not found" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ADDED="$work/added"
git diff -U0 --diff-filter=d "$BASE" "$TIP" | awk '
  /^\+\+\+ b\// { f = substr($0, 7); next }
  /^@@/ { split($3, a, ","); n = substr(a[1], 2); next }
  /^\+/ { print f ":" n "\t" substr($0, 2); n++ }
' > "$ADDED"
export BASE TIP ADDED

# Split RULES.md into <id>.sh (the Detector block) and <id>.status.
awk -v dir="$work" '
  /^### RULE-/ { id = $2; state = "" }
  /^- \*\*Status:\*\*/ { s = $0; sub(/^- \*\*Status:\*\* */, "", s); split(s, w, /[ (]/); print w[1] > (dir "/" id ".status"); close(dir "/" id ".status") }
  /\*\*Detector:\*\*/ { state = "want"; next }
  /^[[:space:]]*```/ {
    if (state == "want") { state = "in"; out = dir "/" id ".sh"; printf "" > out; next }
    if (state == "in") { close(out); state = ""; next }
  }
  state == "in" { sub(/^  /, ""); print >> out }
' "$rules"

found=0
broken=0
ran=0
for detector in "$work"/RULE-*.sh; do
  [ -e "$detector" ] || continue
  id=$(basename "$detector" .sh)
  [ -z "$only" ] || [ "$id" = "$only" ] || continue
  status=$(cat "$work/$id.status" 2>/dev/null || echo missing)
  case "$status" in
    approved) ;;
    draft) [ "$drafts" -eq 1 ] || continue ;;
    *) continue ;;
  esac
  ran=$((ran + 1))
  if ! out=$(bash "$detector" 2> "$work/err"); then
    echo "check-rules: $id detector exited non-zero: $(head -1 "$work/err")" >&2
    broken=1
  fi
  if [ -n "$out" ]; then
    while IFS= read -r line; do echo "$id $line"; done <<< "$out"
    found=1
  fi
done
echo "check-rules: ran $ran detector(s) from $rules" >&2
[ "$broken" -eq 0 ] || exit 2
[ "$found" -eq 0 ]
