# App-level guardrails

Verified at `<sha>` on <YYYY-MM-DD>. Regenerate with the `architecture-guardrails` skill; on a refresh, IDs are kept and retired entries stay with `Status: retired`. Check every entry with `bash guardrails/verify.sh guardrails/APP.md guardrails/modules/*.md` from the repo root.

These are contracts, not preferences: changing one breaks data, users or callers that this diff cannot see. Changing one is allowed — follow the change protocol.

## Change protocol

A PR that changes a guarded value includes this section in its description, and updates the entry below (value, Where, expected check output) in the same PR:

```markdown
## Guardrail change

- **IDs:** GR-APP-...
- **What changes:** old value → new value
- **Why:** the reason the contract has to move
- **Existing data / callers:** migration, dual-read, or why none is needed
- **Rollback:** what happens if this ships and is reverted
```

## Index

| ID | Area | Contract | Basis |
|---|---|---|---|
| GR-APP-STORAGE-001 | Storage | <one line> | measured |

## Storage and persistence

### GR-APP-STORAGE-001 — <short name>

- **Contract:** <the current value, as a fact>
- **Where:** `<file>:<line>`
- **Why guarded:** <what breaks if it changes, for whom>. Incident: <commit/PR, or "none recorded">
- **Basis:** measured | judged (<what the judgement rests on>)
- **Check:**
  ```bash
  <command>
  ```
  Expected:
  ```
  <exact output>
  ```
- **To change:** <what the Guardrail change section must cover for this entry specifically, e.g. "a migration that reads the IndexedDB store and writes the new driver before rehydration">

## Auth and token storage

## Navigation

## State wiring

## Network

## Platform facades and SDKs

## Build, environment and brand config

## Areas with nothing found

| Area | Command run | Result |
|---|---|---|
