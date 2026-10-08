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
BASE=$(git merge-base origin/<target-branch> HEAD)
git diff $BASE --stat
```

Use `$BASE` for every check. If you cannot name the target branch, ask — guessing produces a diff that includes other people's work.

## Step 1 — no bypassed hooks

`--no-verify` skips the checks the team agreed to run. If a hook is failing, fix the failure or fix the hook.

```bash
git log $BASE..HEAD --format='%h %s' | cat
git log $BASE..HEAD --format='%H' | xargs -I{} git show --format='%h %B' -s {} | rg -i 'no.?verify' || echo "clean"
```

You cannot detect `--no-verify` from the commit object itself. What you *can* do is re-run the hooks over the final state:

```bash
npx lint-staged --diff="$BASE...HEAD" 2>/dev/null || npx prek run --from-ref "$BASE" --to-ref HEAD 2>/dev/null || echo "no hook runner configured"
```

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

If your project has a lint rule for it, that rule is the check — run it and read the output rather than eyeballing:

```bash
npx eslint $(git diff $BASE --name-only --diff-filter=d | rg '\.(ts|tsx|js|jsx)$')
```

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
const { items = [], store: { id = null } = {} } = response ?? {};
```

Also check array access, which optional chaining does not protect:

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

```bash
gh pr view --json number --jq .number
gh api repos/<owner>/<repo>/pulls/<n>/comments --paginate \
  --jq '.[] | "\(.id) \(.path):\(.line) \(.user.login): \(.body | gsub("\n";" ") | .[0:100])"'
```

For every thread, before replying:

1. Name the file and line you changed. If you cannot, you have not fixed it.
2. Re-run the check that would have caught it — the lint rule, the test, the app itself.
3. If you decided *not* to change it, say so plainly and give the reason. A reasoned refusal is a legitimate answer; silence is not.

Then confirm the branch actually carries the work:

```bash
git status --short                      # nothing important left uncommitted
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
