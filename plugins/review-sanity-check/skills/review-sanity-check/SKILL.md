---
name: review-sanity-check
description: Run before opening a pull request, before pushing a branch for review, when reviewing someone else's PR, or whenever asked to "self review", "sanity check my changes", "is this ready for PR", or to confirm review comments are addressed. Checks the diff for bypassed commit hooks, comment noise, missing identification props, unsafe property access, prop drilling, misleading names, and duplication — each verified by running a command, not by reading the code. Verifies every review thread has a code change or a reply behind it, and ends in a READY / NOT READY verdict.
---

# Review sanity check

A review pass over a branch, run **before** anyone else is asked to look at it — or when you are the one asked to look.

The rule that makes this skill worth anything: **every check below ends in a command you run and read the output of.** A check you performed by eye is not a check. Most of these failures are invisible on a read-through and obvious in one `git diff` or `ast-grep`.

The second rule: **the skill ends in a verdict, not a summary** (see Report). A branch where every check passes but a reviewer's thread is unanswered is not ready. Do not describe a branch as being in good shape while any NOT READY condition holds.

## Step 0 — establish the diff

```bash
git fetch origin <target-branch>
TIP=HEAD                                                      # your own branch, checked out
# TIP=pr-<n>; git fetch origin pull/<n>/head:$TIP             # someone else's PR, no checkout needed
BASE=$(git merge-base origin/<target-branch> $TIP)
T=$(mktemp -d)
git diff $BASE $TIP > "$T/branch.diff"
git diff $BASE $TIP --stat
```

Fetch first. Without it `origin/<target-branch>` is whatever you last pulled, and the diff silently includes or omits other people's work. If you cannot name the target branch, ask.

Two derived files every later step uses — the changed lines, and a copy of each changed source file as it is at `$TIP` (so structural checks work without checking the branch out):

```bash
git diff -U0 $BASE $TIP --diff-filter=d | awk '
  /^\+\+\+ b\// { f = substr($0, 7) }
  /^@@/ { split($3, a, ","); s = substr(a[1], 2); n = (a[2] == "" ? 1 : a[2])
          for (i = 0; i < n; i++) print f ":" s + i }
' > "$T/changed"
for f in $(git diff $BASE $TIP --name-only --diff-filter=d | rg '\.(js|jsx|ts|tsx)$'); do
  mkdir -p "$T/head/$(dirname "$f")" && git show "$TIP:$f" > "$T/head/$f"
done
```

In zsh, a command stored in a variable (`D="git diff $BASE"; $D`) does not word-split and fails with "command not found". Write output to a file, as above, instead.

**What is in scope.** Changed lines are the floor, not the ceiling:

- A finding on a changed line is yours.
- A finding elsewhere in a touched file is yours when a changed line *uses* it — renders the component, passes the prop, references the name. Rewriting the call site of a badly named or over-propped component is the moment to fix it.
- Anything a reviewer asked for is in scope, wherever it is.
- Pre-existing debt that the branch neither touches nor uses is not yours. Widening the diff to fix it makes review harder.

## Step 1 — no bypassed hooks

`--no-verify` skips the checks the team agreed to run. If a hook is failing, fix the failure or fix the hook.

```bash
git log $BASE..$TIP --format='%h %an | %s' | cat
git log $BASE..$TIP --format='%h %B' | rg -i 'no.?verify' || echo "clean"
```

You cannot detect `--no-verify` from the commit object itself. What you *can* do is re-run the hooks over the final state and see whether they pass.

First find which runner the repo uses — run only that one, and do not suppress its output. A failing hook exits non-zero; chaining runners with `||` turns that failure into "try the next runner" and hides it.

```bash
ls .husky .pre-commit-config.yaml lefthook.yml 2>/dev/null
rg -n '"lint-staged"' package.json
```

Pre-commit checks, over the whole branch — only when `$TIP` is checked out. Start from a clean tree: these runners apply their fixers (`--fix`, `--write`), so any file they modify is code that would not have passed the hook as committed.

```bash
git status --short                                         # must be empty before you start
npx --no-install lint-staged --diff="$BASE...HEAD"         # lint-staged repos
prek run --from-ref "$BASE" --to-ref HEAD                  # pre-commit / prek repos
git status --short                                         # anything listed now = the hook changed it
```

Commit-message checks, per commit. The commit-msg hook is the one `--no-verify` skips most often, and the pre-commit re-run above does not cover it:

```bash
HOOK="$(git config core.hooksPath || echo "$(git rev-parse --git-dir)/hooks")/commit-msg"
ls "$HOOK"                                                 # no hook → skip; every line would FAIL
MSG=$(mktemp)
for c in $(git rev-list $BASE..$TIP); do
  git log -1 --format=%B "$c" > "$MSG"
  "$HOOK" "$MSG" >/dev/null 2>&1 && echo "ok   $(git log -1 --format='%h %s' "$c")" \
                                 || echo "FAIL $(git log -1 --format='%h %s' "$c")"
done
```

A `FAIL` line is a commit that could only have landed with the hook bypassed. It is a NOT READY condition: reword the commits (on an unshared branch) or say why they cannot be.

## Step 2 — no inline comments

**An added comment line is a finding by default.** The reasoning behind a change belongs in the commit message or the PR description, where the reviewer reads it and where it cannot drift out of date with the code. A comment explaining *what* a line does is a naming problem: rename the thing.

The exceptions are narrow — a lint or type directive with its reason, a ticket reference, a one-line pointer to an external constraint the code cannot express (a spec link, a measured limit). The command below already excludes those:

```bash
awk '
  /^\+\+\+ b\// { f = substr($0, 7); code = (f ~ /\.(js|jsx|ts|tsx|py|sh|rb|go|rs|java|kt|swift)$/) }
  code && /^\+[[:space:]]*(\/\/|\/\*|\*|\{\/\*|#)/ && !/eslint-|@ts-|prettier-ignore|[A-Z][A-Z0-9]+-[0-9]+/ { n[f]++; t++ }
  END { for (k in n) print n[k] "\t" k; print t + 0 "\tTOTAL" }
' "$T/branch.diff" | sort -rn
```

Report the total and every file in it. A non-zero total is a finding; list the lines (`rg -n '^\+\s*(//|/\*|\*|\{/\*)' "$T/branch.diff"`) and either delete each one or move its content into the PR description. JSDoc blocks on internal functions count — a long docblock explaining a saga's behaviour is a PR description that got committed.

## Step 3 — component identification props

**Project-specific — edit this section for your codebase, or delete it.**

Many codebases require every rendered component to carry identification props for test automation (`data-testid`, `screenName`/`id`, `accessibilityIdentifier`). These are easy to forget and silently render as `undefined`, which breaks automation without breaking the build.

**Do not use the lint rule as the check.** Rules of this kind exempt elements they consider structural (plain layout wrappers), while reviewers usually do not. Check every element directly with `ast-grep`, then keep the ones on changed lines:

```bash
cat > "$T/ids.yml" <<'EOF'
id: missing-id
language: javascript
rule:
  all:
    - any: [{ kind: jsx_opening_element }, { kind: jsx_self_closing_element }]
    - has: { field: name, regex: "^T2S" }
    - any:
        - not: { has: { kind: jsx_attribute, regex: "^id\\s*=" } }
        - not: { has: { kind: jsx_attribute, regex: "^screenName\\s*=" } }
---
id: raw-primitive
language: javascript
rule:
  any: [{ kind: jsx_opening_element }, { kind: jsx_self_closing_element }]
  has: { field: name, regex: "^(View|Text|TouchableOpacity|Pressable|Image|ScrollView|FlatList|Animated\\.\\w+)$" }
  not: { has: { kind: jsx_expression, has: { kind: spread_element, regex: "setTestId" } } }
EOF
sed 's/language: javascript/language: tsx/' "$T/ids.yml" > "$T/ids-tsx.yml"
(cd "$T/head" && ast-grep scan -r "$T/ids.yml" --json=stream . ; ast-grep scan -r "$T/ids-tsx.yml" --json=stream .) \
  | jq -r '"\(.file | ltrimstr("./")):\(.range.start.line + 1)\t\(.ruleId)\t\(.text | split("\n")[0] | .[0:60])"' \
  | awk -F'\t' 'NR==FNR { c[$0]; next } ($1 in c)' "$T/changed" -
```

Adjust the `^T2S` prefix and the attribute names to your convention. Each `missing-id` hit needs both props; each `raw-primitive` hit needs converting, or a `setTestId` spread plus a stated reason it cannot convert (a ref a library grabs, a native-driver animation).

Then run the lint rule as well, filtered to changed lines — it catches what the structural check does not. `--stdin-filename` lets it lint the `$TIP` copy with the repo's own config:

```bash
: > "$T/lint"
for f in $(git diff $BASE $TIP --name-only --diff-filter=d | rg '\.(ts|tsx|js|jsx)$'); do
  git show "$TIP:$f" | npx --no-install eslint --stdin --stdin-filename "$f" --format json \
    | jq -r --arg f "$f" '.[] | .messages[] | "\($f):\(.line)\t\(.ruleId) \(.message)"' >> "$T/lint"
done
wc -l < "$T/lint"                                          # 0 here can also mean the pipeline broke
awk -F'\t' 'NR==FNR { c[$0]; next } ($1 in c)' "$T/changed" "$T/lint"
```

When `$TIP` is not checked out, `import/no-unresolved` hits on new files are false: the resolver looks at your working tree. Confirm each with `git cat-file -e "$TIP:<path>"` before reporting it.

Two traps worth knowing:
- Rules of this kind usually check **prop presence, not value**. `id={VIEW_ID.SOMETHING}` passes and renders `undefined` if the key does not exist. Confirm every added key resolves in the constants file it is imported from.
- An element with a spread (`{...props}`) is typically skipped by static analysis entirely. Those need reading by hand.

## Step 4 — destructuring and safety checks

Unsafe property access on data that crosses a boundary — an API response, route params, redux state — is the most common runtime crash in a diff that reviews cleanly.

```bash
rg '^\+.*\w+\.\w+\.\w+' "$T/branch.diff" | rg -v '\?\.' | head -30
```

For each hit, ask where the object came from. Local object you just built: fine. Anything from a network response, navigation params, or a selector: it can be `undefined`, and the chain throws. Trace it to the point it enters the code — a normaliser that always returns an array makes the access safe; say which one.

Destructure at the top of the function with defaults, so the shape the function needs is stated once:

```js
const { items = [], store } = response ?? {};
const { id = null } = store ?? {};
```

Destructuring defaults apply only to `undefined`, not `null`. A nested pattern like `store: { id } = {}` still throws when the API sends `store: null`, so guard each nullable level with `?? {}`.

Also check array access. `items?.[0]` and `items?.map(...)` protect against a missing array, but not an empty one: `items[0]` on `[]` is `undefined`, and the next `.name` throws.

```bash
rg '^\+.*\[0\]|^\+.*\.map\(|^\+.*\.filter\(' "$T/branch.diff" | head -20
```

## Step 5 — read state where it is used, not through props

A child that needs state should subscribe to it, not receive it through a chain of parents. Long prop lists are the symptom; the cost is that every intermediate component re-renders on changes it does not care about, and adding one field means editing every file in the chain.

The check is the **call site**, not the component definition — so a component that predates the branch is in scope the moment the branch rewrites the place it is rendered:

```bash
cat > "$T/props.yml" <<'EOF'
id: call-site
language: javascript
rule:
  any: [{ kind: jsx_opening_element }, { kind: jsx_self_closing_element }]
  all:
    - has: { field: name, regex: "^[A-Z]" }
    - not: { has: { field: name, regex: "^T2S" } }
EOF
(cd "$T/head" && ast-grep scan -r "$T/props.yml" --json=stream .) \
  | jq -r '(.text | [scan("[\\s][a-zA-Z]+=")] | length) as $n | select($n > 6)
           | "\(.file | ltrimstr("./")):\(.range.start.line + 1)\t\($n) props\t\(.text | split("\n")[0] | .[0:50])"' \
  | awk -F'\t' 'NR==FNR { c[$0]; next } ($1 in c)' "$T/changed" -
```

The count includes props of JSX passed *as* a prop, so a step component wrapping another over-propped component scores high — that is intended.

For each hit, list which props are data the parent itself got from `useSelector`, a hook, or the store. Those are findings: the child should select them. The exception is what is genuinely the parent's to decide — a callback, a variant, a layout flag, a rendered slot. The test is whether the value is *state the child could look up itself* or *a decision the parent is making*.

## Step 6 — names do not collide with the codebase's vocabulary

A name that means something else in this codebase misleads every later reader. In a Redux codebase `*Selector` means a reselect selector; a component or a JSX-holding variable named `dateSelector` reads as state access.

Find the reserved suffixes (`Selector`, `Saga`, `Reducer`, `Action`, `Helper`, …) — `git ls-files '*.js' '*.ts' | rg -o '[A-Z][a-z]+\.(js|ts)$' | sort | uniq -c | sort -rn | head` — then check names that hold JSX or are components:

```bash
cat > "$T/names.yml" <<'EOF'
id: jsx-named-selector
language: javascript
rule:
  kind: variable_declarator
  all:
    - has: { field: name, regex: "Selector$" }
    - has: { field: value, stopBy: end, any: [{ kind: jsx_element }, { kind: jsx_self_closing_element }] }
EOF
(cd "$T/head" && ast-grep scan -r "$T/names.yml" --json=stream .) | jq -r '.text | capture("^(?<n>\\w+)").n' | sort -u > "$T/names"
git diff $BASE $TIP --name-only --diff-filter=d | rg -o '/View/.*/(\w+Selector)\.(js|jsx|tsx)$' -r '$1' >> "$T/names"
sort -u "$T/names" | while read -r n; do rg -q "^\+.*\b$n\b" "$T/branch.diff" && echo "used on a changed line: $n"; done
```

A name is a finding when a changed line uses it (Step 0). Rename it to say what it is: `DatePicker`, `dateField`, `TableFloorPicker`.

## Step 7 — no duplicated code

New duplication is what this catches; pre-existing duplication is a separate job.

```bash
rg '^\+' "$T/branch.diff" | rg -v '^\+\+\+' | sed 's/^+//' | sed 's/^[[:space:]]*//' \
  | rg -v '^\s*$|^[})\];,]+$' | sort | uniq -c | sort -rn | head -20
```

Repeated lines are a weak signal, so read the hits rather than trusting the count. The real question is whether you wrote the same *decision* twice. Copying a block and changing one value is the shape to look for.

Resist extracting on the second occurrence — two call sites rarely reveal the right abstraction, and a premature one is harder to unpick than the duplication. On the third, extract.

## Step 8 — every review thread has a change or a reply behind it

Each review comment needs either a code change or a reply stating why it was not changed. Replying "fixed" without a corresponding diff is the single fastest way to lose a reviewer's trust; not replying at all is a close second.

Feedback lives in three places, and the REST `pulls/<n>/comments` endpoint returns only the first, with no resolved flag. Use GraphQL for inline threads, with the comment count so unanswered threads show:

```bash
N=$(gh pr view --json number --jq .number)                  # or the PR number you are reviewing
gh pr view "$N" --json reviewDecision --jq .reviewDecision
gh api graphql -F owner='{owner}' -F repo='{repo}' -F n="$N" -f query='
  query($owner: String!, $repo: String!, $n: Int!) {
    repository(owner: $owner, name: $repo) { pullRequest(number: $n) {
      reviewThreads(first: 100) { nodes { isResolved isOutdated path line originalLine
        comments(first: 20) { totalCount nodes { author { login } body } } } } } } }' \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)
        | .comments.nodes[0] as $c
        | "\(if .comments.totalCount == 1 then "UNANSWERED" else "replied   " end) \(if .isOutdated then "outdated" else "current " end) \(.path):\(.line // .originalLine) \($c.author.login): \($c.body | gsub("\n";" ") | .[0:100])"'
```

`line` is `null` on outdated threads, so the query falls back to `originalLine`. **Outdated means the code under the comment moved, not that the comment was addressed** — check each one against `$TIP`. If you get exactly 100 threads back, page with `after:`.

Review summaries and general PR comments have no resolved state. Read them all:

```bash
gh pr view "$N" --json reviews,comments --jq '
  (.reviews[] | select(.body != "") | "review \(.author.login) \(.state): \(.body | gsub("\n";" ") | .[0:100])"),
  (.comments[] | "comment \(.author.login): \(.body | gsub("\n";" ") | .[0:100])")'
```

For every thread:

1. **Generalise it.** A comment that states a rule — "remove inline comments in all the files", "T2S components must have screen name and id" — is a check across the whole branch, not a fix on one line. Re-run the matching step and report its result, not just the line the comment sat on.
2. Name the file and line that changed in response. If you cannot, it has not been fixed.
3. If the answer is *not* to change it — the suggestion does not apply, or the current code is deliberate — that needs a reply on the thread saying so. A reasoned refusal is a legitimate answer; silence is not.

Then confirm the branch actually carries the work:

```bash
git status --short                      # nothing important left uncommitted
git fetch origin <branch>
git rev-list --left-right --count origin/<branch>...HEAD   # nothing left unpushed
```

An unpushed fix is not a fix. Check this before you reply, not after.

## Step 9 — the diff contains only what you meant

```bash
git diff $BASE $TIP --stat
git diff $BASE $TIP --name-only | rg -i 'config|env|\.json$|lock'
```

Look specifically for local-only changes that crept in: a host or endpoint pointed at your machine, a feature flag flipped for testing, a debug log, a timeout raised while you were poking at something. These pass review precisely because they look deliberate. For removed keys (translations, config), confirm nothing still references them.

## Report

Start with the verdict.

**NOT READY** if any of these hold:
- a commit fails the commit-msg hook, or the pre-commit re-run fails or modifies files (Step 1);
- any finding from Steps 2–7 is in scope by Step 0's rules;
- a review thread is unaddressed — no change behind it and no reply (Step 8);
- the PR's review decision is `CHANGES_REQUESTED` and the requested changes are not all made or answered.

**READY** only when none hold.

Then list findings by step, each with `file:line` and the command that produced it. Where a check found nothing, say so — "0 comment lines added" is information. Where you judged rather than measured, say which. Do not report a check as passed if you did not run its command, and do not soften a NOT READY verdict with "the code is in good shape": if the code were in good shape, the verdict would say so.
