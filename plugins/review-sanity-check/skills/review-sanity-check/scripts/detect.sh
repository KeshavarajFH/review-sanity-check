#!/usr/bin/env bash
# Heuristic detectors for production-risk patterns on the lines a branch adds.
# Usage (inside the repo): detect.sh <base> <tip>
# Output: one "RULE path:line — detail" per hit. Hits are leads for the reviewer to confirm,
# not verdicts: each RULE maps to a question in references/role-checklists.md.
set -euo pipefail

base=$1
tip=$2
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

is_test='(__tests__|__mocks__|\.test\.|\.spec\.|Test\.(js|jsx|ts|tsx)$)'
git diff --name-only --diff-filter=d "$base" "$tip" | grep -E '\.(js|jsx|ts|tsx)$' > "$work/files" || true
grep -v -E "$is_test" "$work/files" > "$work/src" || true
src=()
while IFS= read -r line; do src+=("$line"); done < "$work/src"
reducers=()
while IFS= read -r line; do reducers+=("$line"); done < <(grep -E 'Reducer\.(js|ts)$' "$work/src" || true)

# Added lines as "path:line<TAB>text", source files only.
git diff -U0 --diff-filter=d "$base" "$tip" -- ${src[@]+"${src[@]}"} | awk '
  /^\+\+\+ b\// { f = substr($0, 7); next }
  /^@@/ { split($3, a, ","); n = substr(a[1], 2); next }
  /^\+/ { print f ":" n "\t" substr($0, 2); n++ }
' > "$work/added"

hit() { RULE="$1" RE="$2" awk -F'\t' '$2 ~ ENVIRON["RE"] { rule = ENVIRON["RULE"]; t = $2; sub(/^[ \t]+/, "", t); print rule, $1, "—", substr(t, 1, 140) }' "$work/added"; }

# Leftover logging in production paths.
hit CONSOLE 'console\.(log|warn|error|info|debug)\('

# Non-production hosts baked into code.
hit NONPROD-HOST 'https?://[^"'"'"'` ]*(stage|staging|sit[-.]|uat|qa[-.]|dev[-.]|localhost|127\.0\.0\.1|ngrok)'

# Defaults that fall back to a non-production environment.
hit NONPROD-DEFAULT '(\|\||\?\?|default[^:]*:).*["'"'"'](qa|QA|sit|SIT|stage|STAGE|staging|dev|DEV|uat|UAT|test|TEST)["'"'"']'

# Window size read once at module load: stale after rotation or resize.
hit MODULE-SCOPE-DIMENSIONS '^(const|let|var) .*Dimensions\.get\('

# Text below a legible size.
awk -F'\t' '{ if (match($2, /(setFont\(|fontSize: *)[0-9]+/)) { v = substr($2, RSTART, RLENGTH); gsub(/[^0-9]/, "", v); if (v + 0 < 10) print "SMALL-FONT", $1, "— size", v } }' "$work/added"

# Machine-local artifacts committed.
git diff --name-only --diff-filter=A "$base" "$tip" \
  | grep -E '(^|/)(\.build|build|DerivedData|xcuserdata|Pods|node_modules|coverage|\.expo)/|\.DS_Store$|\.log$|\.orig$' \
  | sed 's/^/ARTIFACT /; s/$/:1 — machine-local file committed/' || true

# Started-but-never-stopped work, per file at the tip, when the branch adds a starter.
while read -r f; do
  grep -q -E "^$f:" "$work/added" || continue
  git show "$tip:$f" > "$work/cur" 2>/dev/null || continue
  awk -F'\t' -v f="$f" '$1 ~ "^" f ":"' "$work/added" > "$work/fadded"
  pair() { # rule start-regex stop-regex
    local starts stops
    starts=$(grep -c -E "$2" "$work/fadded" || true)
    [ "$starts" -gt 0 ] || return 0
    stops=$(grep -c -E "$3" "$work/cur" || true)
    total=$(grep -c -E "$2" "$work/cur" || true)
    [ "$stops" -ge "$total" ] || echo "$1 $f:$(grep -n -E "$2" "$work/cur" | head -1 | cut -d: -f1) — $total started, $stops stopped/cleared in file"
    return 0
  }
  pair UNSTOPPED-ANIMATION 'Animated\.loop\(' '\.stop\(\)|stopAnimation\('
  pair UNCLEARED-INTERVAL 'setInterval\(' 'clearInterval\('
  pair UNCLEARED-TIMEOUT 'setTimeout\(' 'clearTimeout\('
  pair UNREMOVED-LISTENER 'addEventListener\(' 'removeEventListener\(|\.remove\(\)'
done < "$work/src"

# A pattern the repo almost never uses directly: facade or network-layer bypass.
{ git grep -l -E '\bfetch\(' "$base" -- . ':!*__tests__*' 2>/dev/null || true; } | wc -l | tr -d ' ' > "$work/fetchcount"
if [ "$(cat "$work/fetchcount")" -le 2 ]; then
  hit RAW-FETCH '(^|[^.A-Za-z_])fetch\(' | sed "s/\$/ (the repo has $(cat "$work/fetchcount") file(s) calling fetch at base)/"
fi
# Third-party packages = dependency names in any package.json at the tip (aliases are not in there).
git ls-tree -r --name-only "$tip" | grep -E '(^|/)package\.json$' | grep -v node_modules \
  | while read -r p; do git show "$tip:$p" | jq -r '(.dependencies // {}) + (.devDependencies // {}) | keys[]' 2>/dev/null || true; done \
  | sort -u > "$work/deps"
awk -F'\t' '{ if (match($2, /(require\(|from )["'"'"'][^."'"'"'][^"'"'"']*["'"'"']/)) { p = substr($2, RSTART, RLENGTH); sub(/^(require\(|from )["'"'"']/, "", p); sub(/["'"'"']$/, "", p); print $1 "\t" p } }' "$work/added" \
  | while IFS=$'\t' read -r loc pkg; do
      case "$pkg" in
        @*) root=$(echo "$pkg" | cut -d/ -f1-2) ;;
        *) root=${pkg%%/*} ;;
      esac
      grep -q -x -F "$root" "$work/deps" || continue
      case "$root" in react | react-native | prop-types) continue ;; esac
      users=$(git grep -l -E "(from |require\()['\"]$root(/[^'\"]*)?['\"]" "$base" -- . ':!*__tests__*' 2>/dev/null | sed "s/^$base://" || true)
      n=$(printf '%s' "$users" | grep -c . || true)
      if [ "$n" -le 2 ]; then
        echo "RARE-IMPORT $loc — '$root' imported by $n file(s) at base: $(echo "$users" | tr '\n' ' ')— facade bypass?"
      fi
    done

# The same string literal added three or more times: a missing constant.
awk -F'\t' '$1 !~ /[Ss]tyles?\.(js|ts)/ && $2 !~ /(import |require\(|from |console\.)/ && $2 !~ /^[ \t]*[a-zA-Z]+: *'"'"'[a-z-]+'"'"',?$/ { s = $2; while (match(s, /'"'"'[A-Za-z_][A-Za-z0-9_ ]{2,}'"'"'/)) { print substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH) } }' "$work/added" \
  | grep -v -x -E "'(string|object|undefined|number|boolean|function|true|false)'" \
  | sort | uniq -c | awk '$1 >= 3 { c = $1; $1 = ""; print "REPEATED-LITERAL" $0, "— added", c, "times" }'

# New exports nobody reads.
grep -E $'\texport (const|function|class) [A-Za-z_]+' "$work/added" | while IFS=$'\t' read -r loc text; do
  name=$(echo "$text" | sed -E 's/^export (const|function|class) ([A-Za-z_]+).*/\2/')
  f=${loc%%:*}
  readers=$(git grep -l -w "$name" "$tip" -- . 2>/dev/null | sed "s/^$tip://" | grep -v -x "$f" | grep -v -c -E "$is_test" || true)
  if [ "$readers" -eq 0 ]; then echo "UNREAD-EXPORT $loc — $name has no reader outside its file"; fi
done || true

# New files nothing imports.
git diff --name-only --diff-filter=A "$base" "$tip" | grep -E '\.(js|jsx|ts|tsx)$' | grep -v -E "$is_test" | while read -r f; do
  stem=$(basename "$f" | sed -E 's/\.(web|native|ios|android)?\.?(js|jsx|ts|tsx)$//; s/\.styles$//')
  importers=$(git grep -l -E "['\"/]${stem}['\"]" "$tip" -- . 2>/dev/null | sed "s/^$tip://" | grep -v -F "$f" | grep -c -v -E "$is_test" || true)
  if [ "$importers" -eq 0 ]; then echo "UNIMPORTED-FILE $f:1 — no file imports $stem"; fi
done || true

# Style keys defined on changed lines that nothing in the same directory reads.
grep -E '[Ss]tyles?\.(js|ts)$' "$work/src" | while read -r f; do
  git show "$tip:$f" 2>/dev/null | awk -v f="$f" '/^    [A-Za-z0-9_]+: [{(]/ { k = $1; sub(/:$/, "", k); print f ":" NR "\t" k }' > "$work/keys"
  dir=$(dirname "$f")
  git grep -h "" "$tip" -- "$dir" ':!*tyles.js' ':!*tyles.ts' 2>/dev/null > "$work/dirsrc" || true
  while IFS=$'\t' read -r loc key; do
    grep -q -x -F "$loc" <(cut -f1 "$work/added") || continue
    if ! grep -q -E "\b$key\b" "$work/dirsrc"; then echo "UNUSED-STYLE $loc — style key $key is not read in $dir"; fi
  done < "$work/keys"
done || true

# User-visible English in JSX instead of localisation (needs ast-grep).
if command -v ast-grep > /dev/null; then
  mkdir -p "$work/head"
  while read -r f; do
    case "$f" in *.jsx | *.tsx | */View/* | */Views/* | */MicroComponents/* | */components/* | */Components/*) ;; *) continue ;; esac
    mkdir -p "$work/head/$(dirname "$f")" && git show "$tip:$f" > "$work/head/$f" 2>/dev/null || true
  done < "$work/src"
  cat > "$work/jsx.yml" <<'RULES'
id: jsx-text
language: javascript
rule:
  any:
    - { kind: jsx_text, regex: "[A-Za-z]{2,}" }
    - kind: string_fragment
      regex: "^[A-Z][A-Za-z]+( [A-Za-z]+)+$|^[A-Z]{2,}( [A-Z]{2,})+$"
      inside: { kind: jsx_expression, stopBy: end }
RULES
  sed 's/language: javascript/language: tsx/' "$work/jsx.yml" > "$work/jsx-tsx.yml"
  (cd "$work/head" && { ast-grep scan -r "$work/jsx.yml" --json=stream . 2> /dev/null; ast-grep scan -r "$work/jsx-tsx.yml" --json=stream . 2> /dev/null; } || true) \
    | jq -r '"\(.file | ltrimstr("./")):\(.range.start.line + 1)\t\(.text | gsub("\\s+"; " ") | .[0:60])"' \
    | while IFS=$'\t' read -r loc text; do
        if grep -q -x -F "$loc" <(cut -f1 "$work/added"); then echo "JSX-LITERAL $loc — \"$text\""; fi
      done
else
  echo "SKIPPED JSX-LITERAL — ast-grep not installed" >&2
fi

# New state fields: each needs a persistence decision (see the PERSIST questions).
[ ${#reducers[@]} -eq 0 ] || git diff -U0 --diff-filter=d "$base" "$tip" -- "${reducers[@]}" \
  | awk '/^\+\+\+ b\// { f = substr($0, 7) } /^@@/ { split($3, a, ","); n = substr(a[1], 2) - 1 } /^[+ ]/ && !/^\+\+\+/ { n++ } /^\+    [A-Za-z_]+: / { k = $2; sub(/:.*/, "", k); print "NEW-STATE-FIELD", f ":" n, "—", k }' > "$work/fields" || true
cat "$work/fields"

# New state fields nothing outside the reducer reads. A quoted mention ('field' in a persist list) is not a read.
while read -r _ loc _ field; do
  f=${loc%%:*}
  readers=$( { git grep -n -w "$field" "$tip" -- . 2>/dev/null || true; } | sed "s/^$tip://" \
    | grep -v -E "^$f:|$is_test" | grep -c -v -E "['\"]${field}['\"]" || true)
  if [ "$readers" -eq 0 ]; then echo "UNREAD-STATE-FIELD $loc — $field is written but nothing outside the reducer reads it"; fi
done < "$work/fields"
