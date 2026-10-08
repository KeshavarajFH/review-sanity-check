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

## Licence

MIT
