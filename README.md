# review-sanity-check

A Claude Code skill that runs a self-review pass over your own diff before you open a pull request.

It checks for bypassed commit hooks, comment noise, unsafe property access, prop drilling, duplicated
code, and local-only changes that crept into the branch — and, if the PR already has review comments,
that each one has a real code change behind it before you reply "fixed".

Every check ends in a command whose output you read. A check done by eye is not a check.

## Install

```
/plugin marketplace add KeshavarajFH/review-sanity-check
/plugin install review-sanity-check@review-sanity-check
```

## Use

It triggers on its own before a PR, or ask for it:

```
sanity check my changes
is this ready for PR?
```

## Adapting it

Step 3 (component identification props) is project-specific — point it at your own convention or
delete the section. Everything else is codebase-agnostic.

## architecture-guardrails

A second plugin in this marketplace. It records the contracts in a codebase that must not change casually — storage
and persistence drivers, persisted state keys and versions, token storage, navigation routes, cross-module action
contracts, network setup, platform facades — in one place:

```
guardrails/APP.md               # app level
guardrails/modules/<Module>.md  # one file per module
```

Each entry carries the current value, its `file:line`, why it is guarded (with any past incident), a check command with
its expected output, and what a PR must include in a `## Guardrail change` section to change it.

```
/plugin install architecture-guardrails@review-sanity-check
```

Then ask for it: "record the architecture guardrails for this repo", or "refresh the guardrails". On a refresh it reports
every contract whose value changed since the last run.

## Licence

MIT
