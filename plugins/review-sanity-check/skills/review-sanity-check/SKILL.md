---
name: review-sanity-check
description: Run before opening a pull request, before pushing a branch for review, when reviewing someone else's PR, or whenever asked to "review this PR", "self review", "sanity check my changes", "is this ready for PR", or to confirm review comments are addressed. Checks the branch against the repo's own standards and guardrails, runs detectors for runtime crashes and production risks (missing exports and keys, leaks, non-production hosts, hardcoded strings, dead code), and walks every changed file through a role checklist (saga races and guards, persistence, selector defaults, test sensitivity). Also checks bypassed hooks, comments, identification props, unsafe access, prop drilling, naming, duplication and review threads. Ends in a READY / NOT READY verdict with a per-check table.
---

# Review sanity check

A review pass over a branch, run **before** anyone else is asked to look at it — or when you are the one asked to look.

It answers one question: **does this branch do things the way this repo does them, and will it hold up in production?** Three sources of "the way this repo does them", in order: the repo's own enforced tooling and written rules (Step 2), its recorded guardrails (Step 3), and the shared production-risk checks in this skill (Steps 4–5).

The rule that makes this skill worth anything: **every check below ends in a command you run and read the output of.** A check you performed by eye is not a check. Most of these failures are invisible on a read-through and obvious in one `git diff` or `ast-grep`.

The second rule: **the skill ends in a verdict, not a summary** (see Report). A branch where every check passes but a reviewer's thread is unanswered is not ready. Do not describe a branch as being in good shape while any NOT READY condition holds.

## Step 0 — establish the diff

```bash
git fetch origin <target-branch>
TIP=HEAD                                                      # your own branch, checked out
# TIP=pr-<n>; git fetch origin pull/<n>/head:$TIP             # someone else's PR, no checkout needed
BASE=$(git merge-base origin/<target-branch> $TIP)
N=$(gh pr view --json number --jq .number 2>/dev/null)       # your branch's PR; for someone else's: N=<n>
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
for f in $(git diff $BASE $TIP --name-only --diff-filter=d | grep -E '\.(js|jsx|ts|tsx)$'); do
  mkdir -p "$T/head/$(dirname "$f")" && git show "$TIP:$f" > "$T/head/$f"
done
```

Tools that resolve imports or read other files (lint, the reference checker, the repo's own scripts) need a real checkout of `$TIP`. When it is not checked out, make a temporary worktree and link the dependencies; remove it at the end:

```bash
WT=$PWD
if [ "$TIP" != HEAD ]; then
  git worktree add -q --detach "$T/wt" $TIP && ln -s "$PWD/node_modules" "$T/wt/node_modules"
  WT="$T/wt"
fi
# ... at the end of the review:
[ "$TIP" != HEAD ] && git worktree remove --force "$T/wt"
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

## Step 2 — the repo's own standards

The repo's rules come first: they are what its reviewers will hold the branch to. Find them before running anything of your own.

```bash
ls CLAUDE.md AGENTS.md CONTRIBUTING.md .cursor/rules docs/*standard* docs/*guideline* 2>/dev/null
ls guardrails/RULES.md 2>/dev/null                         # rules recorded by the architecture-guardrails skill
ls scripts/ 2>/dev/null | grep -i -E 'check|lint|standard|guard'
jq -r '.scripts | to_entries[] | select(.key | test("lint|check|standard|guard")) | "\(.key): \(.value)"' package.json
```

Read the written rules. For each rule in `guardrails/RULES.md` marked approved, run its detector. Treat written rules as checks: a rule the branch breaks is a finding with the rule's own wording.

Run every standards script the repo has **over the whole branch**, not just staged files — commits made with `--no-verify` never ran them. Many accept a base ref (`--base`, `--from-ref`, `--diff`); read the script's usage line and pass `$BASE`. Run them in `$WT`:

```bash
(cd "$WT" && node scripts/<check-script>.js --base "$BASE")   # each one you found
```

Lint over the changed files in `$WT`, keeping only findings on changed lines. ESLint's own warnings go to a file so they do not bury the findings:

```bash
FILES=$(git diff $BASE $TIP --name-only --diff-filter=d | grep -E '\.(ts|tsx|js|jsx)$')
ROOT="$(cd "$WT" && pwd -P)/"
[ -n "$FILES" ] && (cd "$WT" && npx --no-install eslint --format json $(echo $FILES) 2> "$T/lint.err") \
  | jq -r --arg root "$ROOT" '.[] | (.filePath | ltrimstr($root)) as $f
      | .messages[] | "\($f):\(.line)\t\(.ruleId) \(.message)"' > "$T/lint"
wc -l < "$T/lint"                                          # 0 can also mean a config error — read $T/lint.err
awk -F'\t' 'NR==FNR { c[$0]; next } ($1 in c)' "$T/changed" "$T/lint"
```

Where a repo script already enforces something later steps also check (comments, identification props, prop counts, duplication), its result is the answer for that step; the later step only covers what the script does not.

## Step 3 — guardrails

If the repo has a `guardrails/` record (from the architecture-guardrails skill), check the branch against it:

```bash
ls guardrails/APP.md guardrails/modules/ 2>/dev/null
(cd "$WT" && bash guardrails/verify.sh guardrails/APP.md guardrails/modules/*.md)
```

Every `FAIL` is a guarded contract this branch changes: a storage driver, a persist key, a route, an action type another module's saga takes. That is allowed only with a `## Guardrail change` section in the PR description naming the ID and covering migration and rollback:

```bash
gh pr view "$N" --json body --jq .body | grep -A8 '## Guardrail change'
```

A failed guardrail without that section is a NOT READY finding, whatever the size of the diff — the incident this exists for was three lines in a storage facade. A section that names the ID but does not answer "existing data / callers" is a finding too.

No `guardrails/` directory: say so in the report, and apply S8 and R1 (Step 5) with extra care — they are the checks closest to it.

## Step 4 — detectors

Two scripts ship with this skill. Run both; every hit is a lead to confirm or dismiss, with a reason, in the report.

```bash
SKILL=<path to this skill's directory>
(cd "$WT" && node "$SKILL/scripts/check-references.js" "$T/changed" $(echo $FILES))
bash "$SKILL/scripts/detect.sh" "$BASE" "$TIP"
```

`check-references.js` reports references that are `undefined` at runtime: an imported name the module does not export, `CONST.KEY` where the constants object has no such key, a localisation key missing from the default language table. These crash or render `undefined` and pass lint. Treat each as confirmed unless the module builds the object dynamically.

`detect.sh` prints one `RULE path:line — detail` per hit:

| Rule | Lead | Confirm with |
|---|---|---|
| `CONSOLE` | logging left in a production path | always a finding outside tests |
| `NONPROD-HOST` | stage/SIT/QA/localhost URL in code | a finding unless it is an environment-map entry |
| `NONPROD-DEFAULT` | fallback to a non-production value | CFG1 |
| `RAW-FETCH`, `RARE-IMPORT` | an API or SDK the repo almost never uses directly | N1, C7 — the detail names the existing facade |
| `UNSTOPPED-ANIMATION`, `UNCLEARED-*`, `UNREMOVED-LISTENER` | work started with fewer stops than starts | C3 |
| `MODULE-SCOPE-DIMENSIONS` | window size read once at load | C6 |
| `JSX-LITERAL`, `REPEATED-LITERAL` | user-visible English; a string repeated 3+ times | C5; a repeated *domain* value (a type, status or field name) is a finding — a missing constant |
| `SMALL-FONT` | text under 10 pt | C5 |
| `UNREAD-EXPORT`, `UNIMPORTED-FILE`, `UNUSED-STYLE` | dead code | X3 |
| `NEW-STATE-FIELD` | a field added to a reducer | R1, R2, R4 for each one |
| `UNREAD-STATE-FIELD` | a new field no file outside the reducer reads | R4 — a finding unless a reader is added elsewhere |
| `ARTIFACT` | machine-local file committed | always a finding |

## Step 5 — role pass

Read `references/role-checklists.md` (in this skill's directory). Give every changed file a role — saga, reducer, selector, network, config, component, test — and answer each of that role's questions with evidence, or `n/a` with the reason. Sagas, reducers and selectors first.

This is where most high-severity problems are found: races between watchers, optimistic writes that never revert, work that runs after a reset, selectors that default a feature to on, transient state that persists. None of them is visible on the changed line alone — each question names what else to open.

Record every answer. A question you did not answer is reported as not checked, never as passed.

## Step 6 — no inline comments

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

## Step 7 — component identification props

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
  | jq -r --arg base "<base-component-dir>/" '
      select(.ruleId != "raw-primitive" or (.file | ltrimstr("./") | startswith($base) | not))
      | "\(.file | ltrimstr("./")):\(.range.start.line + 1)\t\(.ruleId)\t\(.text | split("\n")[0] | .[0:60])"' \
  | awk -F'\t' 'NR==FNR { c[$0]; next } ($1 in c)' "$T/changed" -
```

Adjust the `^T2S` prefix, the attribute names and `<base-component-dir>` (where the wrapped components are defined — `raw-primitive` skips it, because the wrappers are where raw primitives are meant to live) to your convention. Each `missing-id` hit needs both props; each `raw-primitive` hit needs converting, or a `setTestId` spread plus a stated reason it cannot convert (a ref a library grabs, a native-driver animation).

The lint run in Step 2 covers the identification rule; this structural check catches what it exempts.

Changes to the directory that defines the wrapped components themselves are a separate finding — those components are shared by every screen:

```bash
git diff $BASE $TIP --name-status -- <base-component-dir> | cat
```

Any line here needs the component owners' approval. Read each changed component too: a wrapper copied from elsewhere can carry that file's bugs (a `propType` typo that silently disables prop validation).

Two traps worth knowing:
- Rules of this kind usually check **prop presence, not value**. `id={VIEW_ID.SOMETHING}` passes and renders `undefined` if the key does not exist. Confirm every added key resolves in the constants file it is imported from.
- An element with a spread (`{...props}`) is typically skipped by static analysis entirely. Those need reading by hand.

## Step 8 — destructuring and safety checks

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

## Step 9 — read state where it is used, not through props

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

## Step 10 — names do not collide with the codebase's vocabulary

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

## Step 11 — no duplicated code

New duplication is what this catches; pre-existing duplication is a separate job.

```bash
rg '^\+' "$T/branch.diff" | rg -v '^\+\+\+' | sed 's/^+//' | sed 's/^[[:space:]]*//' \
  | rg -v '^\s*$|^[})\];,]+$' | sort | uniq -c | sort -rn | head -20
```

Repeated lines are a weak signal, so read the hits rather than trusting the count. The real question is whether you wrote the same *decision* twice. Copying a block and changing one value is the shape to look for.

Resist extracting on the second occurrence — two call sites rarely reveal the right abstraction, and a premature one is harder to unpick than the duplication. On the third, extract.

## Step 12 — every review thread has a change or a reply behind it

Each review comment needs either a code change or a reply stating why it was not changed. Replying "fixed" without a corresponding diff is the single fastest way to lose a reviewer's trust; not replying at all is a close second.

Feedback lives in three places, and the REST `pulls/<n>/comments` endpoint returns only the first, with no resolved flag. Use GraphQL for inline threads, with the comment count so unanswered threads show:

```bash
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

## Step 13 — the diff contains only what you meant

```bash
git diff $BASE $TIP --stat
git diff $BASE $TIP --name-only | rg -i 'config|env|\.json$|lock'
```

Look specifically for local-only changes that crept in: a host or endpoint pointed at your machine, a feature flag flipped for testing, a debug log, a timeout raised while you were poking at something. These pass review precisely because they look deliberate. For removed keys (translations, config), confirm nothing still references them.

## Report

Start with the verdict.

**NOT READY** if any of these hold:
- a commit fails the commit-msg hook, or the pre-commit re-run fails or modifies files (Step 1);
- a repo standards script or written rule fails on the branch (Step 2);
- a guardrail check fails without a matching `## Guardrail change` section (Step 3);
- a detector hit is confirmed (Step 4), or a role question fails (Step 5);
- any finding from Steps 6–11 is in scope by Step 0's rules;
- a review thread is unaddressed — no change behind it and no reply (Step 12);
- the PR's review decision is `CHANGES_REQUESTED` and the requested changes are not all made or answered.

**READY** only when none hold.

Then a table of **every check**, so a reader can see what was and was not looked at:

| Check | Result | Evidence |
|---|---|---|
| Step 1 commit-msg hook | fail | 3 of 8 commits: `abc123`, … |
| Step 2 `scripts/check-changed-lines.js --base` | pass | exit 0 |
| Step 3 GR-APP-STORAGE-001 | fail | driver line changed; no Guardrail change section |
| Step 4 MISSING-KEY | fail | `Screen.js:162` `SCREEN_NAME.X` |
| Step 5 S2 concurrent watchers (`CartSaga.js`) | fail | apply/remove interleaving, see finding 3 |
| Step 5 SEL1 (`CartSelectors.js`) | n/a | no selector returns a new object |
| Step 5 T4 sensitivity | not checked | no test run in this review |

Then the findings, highest severity first, each with `file:line`, what is wrong, why it matters in production, and the check that found it. Where a check found nothing, say so — "0 comment lines added" is information. Where you judged rather than measured, say which. Do not report a check as passed if you did not run it, and do not soften a NOT READY verdict with "the code is in good shape": if the code were in good shape, the verdict would say so.

End with the findings as JSON, so runs can be compared over time:

```json
{"verdict": "NOT READY", "findings": [{"file": "path", "line": 1, "check": "Step 5 S2", "severity": "high", "summary": "..."}]}
```

Remove the worktree from Step 0 if you made one.
