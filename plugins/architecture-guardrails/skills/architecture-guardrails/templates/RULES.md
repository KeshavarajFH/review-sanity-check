# Rules

Mined at `<sha>` on <YYYY-MM-DD> by the `architecture-guardrails` skill. These are how this repo does things — the patterns a reviewer expects a PR to follow. Guardrails (`APP.md`, `modules/`) are values that must not change; rules are ways of writing code.

**Every rule starts as `draft`.** A rule applies to reviews only once someone on the team changes its Status to `approved (<name>, <date>)` — in a PR, so the approval is reviewed too. `rejected (<name>, <reason>)` keeps a rejected candidate from being mined again.

Run the approved detectors over a branch with:

```bash
bash guardrails/check-rules.sh <base> <tip>              # approved rules
bash guardrails/check-rules.sh --drafts <base> <tip>     # include drafts, e.g. while reviewing them
```

## Index

| ID | Rule | Status | Detector | Backed by |
|---|---|---|---|---|
| RULE-NET-001 | <one line> | draft | yes | docs, pattern 41/42, 3 PRs / 2 reviewers |

## Network

### RULE-NET-001 — <imperative statement of the rule>

- **Status:** draft
- **Rule:** <what to do, and what not to do, in one or two sentences>
- **Why:** <the concrete failure when it is broken — what a user or another team sees>
- **Sources:**
  - written: `<file>:<line>` — "<quoted sentence>"
  - enforced: `<lint rule or script>` — or "not enforced"
  - pattern: <N of M> <things> follow it, measured with `<command>`; outliers: `<file>`, …
  - reviews: <K> comments in <P> PRs by <R> reviewers — <links to two or three>
- **Counter-evidence:** <measurements that cut against the rule — e.g. "old code still does it the other way in 2150 places"; "none" if none>
- **Example:** `<file>:<line>` — the repo doing it right
- **Detector:**
  ```bash
  awk -F'\t' '$2 ~ /<pattern>/ { print $1, "—", substr($2, 1, 80) }' "$ADDED" || true
  ```
- **Proven on:** PR #<n> at `<commit>` — the detector printed `<path>:<line>`, where the reviewer flagged it; on PR #<m>, merged without this problem, it printed nothing.
- **Severity:** high | medium | low

<!-- A rule no command can check uses this line instead of Detector and Proven on; a rule can also have both:
- **Review question:** <the question a reviewer answers for each changed file it applies to>
A rule the repo's tools already enforce replaces Detector with:
- **Detector:** none — enforced by <tool> (<local hook | CI>)
-->

## Rejected candidates

| Candidate | Source | Rejected by | Reason |
|---|---|---|---|
