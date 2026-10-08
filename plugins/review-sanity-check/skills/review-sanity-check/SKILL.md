---
name: review-sanity-check
description: Run before opening a pull request, before pushing a branch for review, or whenever asked to "self review", "sanity check my changes", "is this ready for PR", or to confirm review comments are addressed. Checks the diff for bypassed commit hooks, comment noise, unsafe property access, prop drilling, and duplication — each verified by running a command, not by reading the code. Also verifies every unresolved review comment has a real code change behind it before you claim it is fixed.
---

# Review sanity check

A self-review pass over your own diff, run **before** anyone else is asked to look at it.

The rule that makes this skill worth anything: **every check below ends in a command you run and read the output of.** A check you performed by eye is not a check. Most of these failures are invisible on a read-through and obvious in one `git diff` or `grep`.

## Step 0 — establish the diff

Everything is scoped to *what this branch changes*, not what the files contain. A file you touched may be full of pre-existing debt; that is not yours to answer for, and widening the diff to fix it makes review harder.

```bash
git fetch origin <target-branch>
BASE=$(git merge-base origin/<target-branch> HEAD)
git diff $BASE --stat
```

Fetch first. Without it `origin/<target-branch>` is whatever you last pulled, and the diff silently includes or omits other people's work.

Use `$BASE` for every check. If you cannot name the target branch, ask — guessing produces a diff that includes other people's work.

## Step 1 — no bypassed hooks

`--no-verify` skips the checks the team agreed to run. If a hook is failing, fix the failure or fix the hook.

```bash
git log $BASE..HEAD --format='%h %s' | cat
git log $BASE..HEAD --format='%H' | xargs -I{} git show --format='%h %B' -s {} | rg -i 'no.?verify' || echo "clean"
```

You cannot detect `--no-verify` from the commit object itself. What you *can* do is re-run the hooks over the final state and see whether they pass.

First find which runner the repo uses — run only that one, and do not suppress its output. A failing hook exits non-zero; chaining runners with `||` turns that failure into "try the next runner" and hides it.

```bash
ls .husky .pre-commit-config.yaml lefthook.yml 2>/dev/null
rg -n '"lint-staged"' package.json
```

Pre-commit checks, over the whole branch. Start from a clean tree: these runners apply their fixers (`--fix`, `--write`), so any file they modify is code that would not have passed the hook as committed.

```bash
git status --short                                         # must be empty before you start
npx --no-install lint-staged --diff="$BASE...HEAD"         # lint-staged repos
prek run --from-ref "$BASE" --to-ref HEAD                  # pre-commit / prek repos
git status --short                                         # anything listed now = the hook changed it
```

Commit-message checks, per commit. The commit-msg hook is the one `--no-verify` skips most often, and the pre-commit re-run above does not cover it:

```bash
HOOK="$(git config core.hooksPath || echo "$(git rev-parse --git-dir)/hooks")/commit-msg"
MSG=$(mktemp)
for c in $(git rev-list $BASE..HEAD); do
  git log -1 --format=%B "$c" > "$MSG"
  "$HOOK" "$MSG" >/dev/null 2>&1 && echo "ok   $(git log -1 --format='%h %s' "$c")" \
                                 || echo "FAIL $(git log -1 --format='%h %s' "$c")"
done
```

A `FAIL` line is a commit that could only have landed with the hook bypassed. If the repo has no commit-msg hook, `$HOOK` does not exist and every line fails — check `ls "$HOOK"` before reading the result.

## Step 2 — no unnecessary inline comments

Count what the branch *adds*, not what the files contain:

```bash
git diff $BASE | rg -c '^\+\s*(//|\*|/\*|#)' || echo 0
git diff $BASE | rg '^\+\s*(//|\*|/\*|#)' | head -40
```

Delete a comment when it restates the code. Keep it only when it records something unrecoverable from reading the code: a ticket reference, a measured number, a failure mode that caused the line to exist.

A comment explaining *what* a line does is a naming problem. Rename the thing and the comment disappears — that is a strictly better fix than deleting the comment and leaving the bad name.

## Step 3 — component identification props

**Project-specific — edit this section for your codebase, or delete it.**

Many codebases require every rendered component to carry identification props for test automation (`data-testid`, `screenName`/`viewId`, `accessibilityIdentifier`). These are easy to forget and silently render as `undefined`, which breaks automation without breaking the build.

Find the convention, then check the added lines against it:

```bash
rg -n 'screenName|data-testid|testID' --glob '!*test*' <your-source-dir> | head -5   # learn the convention
git diff $BASE | rg '^\+.*<[A-Z]' | head -40                                          # components you added
```

If your project has a lint rule for it, that rule is the check — run it and read the output rather than eyeballing. Linting whole files reports every pre-existing error in them too, which Step 0 says is not yours to answer for, so keep only findings on lines this branch changed. Run from the repo root:

```bash
T=$(mktemp -d)
git diff -U0 $BASE --diff-filter=d | awk '
  /^\+\+\+ b\// { f = substr($0, 7) }
  /^@@/ { split($3, a, ","); s = substr(a[1], 2); n = (a[2] == "" ? 1 : a[2])
          for (i = 0; i < n; i++) print f ":" s + i }
' > "$T/changed"
FILES=$(git diff $BASE --name-only --diff-filter=d | rg '\.(ts|tsx|js|jsx)$')
[ -n "$FILES" ] && npx --no-install eslint --format json $FILES \
  | jq -r --arg root "$PWD/" '.[] | (.filePath | ltrimstr($root)) as $f
      | .messages[] | "\($f):\(.line)\t\(.ruleId) \(.message)"' > "$T/all"
awk -F'\t' 'NR==FNR { c[$0]; next } ($1 in c)' "$T/changed" "$T/all"
```

The `[ -n "$FILES" ]` guard matters: with no matching files, a bare `npx eslint` lints the entire working directory. Use `--format json`; the `unix` and `compact` formatters were removed from ESLint 9.

An empty result could also mean the pipeline broke, so check `wc -l "$T/all"` — it counts every finding in the changed files, including ones the filter dropped.

Two traps worth knowing:
- Rules of this kind usually check **prop presence, not value**. `id={someUndefinedConstant}` passes lint and renders `undefined` at runtime. Confirm the value resolves, by grepping the constants file it is imported from.
- An element with a spread (`{...props}`) is typically skipped by static analysis entirely. Those need reading by hand.

## Step 4 — destructuring and safety checks

Unsafe property access on data that crosses a boundary — an API response, route params, redux state — is the most common runtime crash in a diff that reviews cleanly.

```bash
git diff $BASE | rg '^\+.*\w+\.\w+\.\w+' | rg -v '\?\.' | head -30
```

For each hit, ask where the object came from. Local object you just built: fine. Anything from a network response, navigation params, or a selector: it can be `undefined`, and the chain throws.

Destructure at the top of the function with defaults, so the shape the function needs is stated once:

```js
const { items = [], store } = response ?? {};
const { id = null } = store ?? {};
```

Destructuring defaults apply only to `undefined`, not `null`. A nested pattern like `store: { id } = {}` still throws when the API sends `store: null`, so guard each nullable level with `?? {}`.

Also check array access. `items?.[0]` and `items?.map(...)` protect against a missing array, but not an empty one: `items[0]` on `[]` is `undefined`, and the next `.name` throws.

```bash
git diff $BASE | rg '^\+.*\[0\]|^\+.*\.map\(|^\+.*\.filter\(' | head -20
```

## Step 5 — read state where it is used, not through props

A child that needs state should subscribe to it, not receive it through a chain of parents. Long prop lists are the symptom; the cost is that every intermediate component re-renders on changes it does not care about, and adding one field means editing every file in the chain.

```bash
git diff $BASE | rg '^\+\s+\w+=\{' | head -40                 # props being passed
git diff $BASE --name-only | xargs rg -l 'useSelector|useStore|useContext' 2>/dev/null
```

If a component you added takes more than ~6 props and several are plain data, have it select what it needs instead.

The exception: props that are genuinely the parent's to decide — a callback, a variant, a layout flag — belong as props. The test is whether the value is *state the child could look up itself* or *a decision the parent is making*.

## Step 6 — no duplicated code

New duplication is what this catches; pre-existing duplication is a separate job.

```bash
git diff $BASE | rg '^\+' | rg -v '^\+\+\+' | sed 's/^+//' | sed 's/^[[:space:]]*//' \
  | rg -v '^\s*$|^[})\];,]+$' | sort | uniq -c | sort -rn | head -20
```

Repeated lines are a weak signal, so read the hits rather than trusting the count. The real question is whether you wrote the same *decision* twice. Copying a block and changing one value is the shape to look for.

Resist extracting on the second occurrence — two call sites rarely reveal the right abstraction, and a premature one is harder to unpick than the duplication. On the third, extract.

## Step 7 — review comments must have a change behind them

If the PR already has review comments, each one needs either a code change or a stated reason it was not changed. Replying "fixed" without a corresponding diff is the single fastest way to lose a reviewer's trust.

Feedback lives in three places, and the REST `pulls/<n>/comments` endpoint returns only the first, with no resolved flag. Use GraphQL for inline threads so you can filter to unresolved ones:

```bash
N=$(gh pr view --json number --jq .number)
gh api graphql -F owner='{owner}' -F repo='{repo}' -F n="$N" -f query='
  query($owner: String!, $repo: String!, $n: Int!) {
    repository(owner: $owner, name: $repo) { pullRequest(number: $n) {
      reviewThreads(first: 100) { nodes { isResolved path line originalLine
        comments(first: 1) { nodes { author { login } body } } } } } } }' \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)
        | .comments.nodes[0] as $c
        | "\(.path):\(.line // .originalLine) \($c.author.login): \($c.body | gsub("\n";" ") | .[0:100])"'
```

`line` is `null` on outdated threads (the code moved), so the query falls back to `originalLine`. Outdated does not mean addressed. It caps at 100 threads; if you get exactly 100 back, page with `after:`.

Review summaries and general PR comments have no resolved state. Read them all:

```bash
gh pr view "$N" --json reviews,comments --jq '
  (.reviews[] | select(.body != "") | "review \(.author.login) \(.state): \(.body | gsub("\n";" ") | .[0:100])"),
  (.comments[] | "comment \(.author.login): \(.body | gsub("\n";" ") | .[0:100])")'
```

For every thread, before replying:

1. Name the file and line you changed. If you cannot, you have not fixed it.
2. Re-run the check that would have caught it — the lint rule, the test, the app itself.
3. If you decided *not* to change it, say so plainly and give the reason. A reasoned refusal is a legitimate answer; silence is not.

Then confirm the branch actually carries the work:

```bash
git status --short                      # nothing important left uncommitted
git fetch origin <branch>
git rev-list --left-right --count origin/<branch>...HEAD   # nothing left unpushed
```

An unpushed fix is not a fix. Check this before you reply, not after.

## Step 8 — the diff contains only what you meant

```bash
git diff $BASE --stat
git diff $BASE --name-only | rg -i 'config|env|\.json$|lock'
```

Look specifically for local-only changes that crept in: a host or endpoint pointed at your machine, a feature flag flipped for testing, a debug log, a timeout raised while you were poking at something. These pass review precisely because they look deliberate.

## Report

State what you ran and what it returned. Where a check found nothing, say so — "0 comment lines added" is information. Where you judged rather than measured, say which. Do not report a check as passed if you did not run its command.
