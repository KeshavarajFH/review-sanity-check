# <Module> guardrails

Verified at `<sha>` on <YYYY-MM-DD>. Module root: `<path>`. App-level contracts live in `../APP.md`; the change protocol there applies here too.

Depended on by <N> files outside this module.

## Index

| ID | Area | Contract | Basis |
|---|---|---|---|

## Cross-module action contracts

Actions defined here and used by other modules (a rename compiles and breaks them silently), and actions from other modules this module depends on.

### GR-<MODULE>-ACTION-001 — <action type or creator>

- **Contract:** `<ACTION_TYPE>` = `'<string value>'`, payload `{ <fields> }`
- **Where:** `<file>:<line>`
- **Consumers:** `<file>:<line>` (dispatches | takes)
- **Why guarded:** <which flow in which module breaks>
- **Basis:** measured | judged (<why it counts as public>)
- **Check:**
  ```bash
  <command>
  ```
  Expected:
  ```
  <exact output>
  ```
- **To change:** rename in every consumer in the same PR, listed in the Guardrail change section

## Persisted state

## Routes owned

## Selectors, helpers and constants used outside

## Endpoints

## Automation identifiers

## Areas with nothing found

| Area | Command run | Result |
|---|---|---|
