# Role checklists

Every changed file gets the questions for its role. A file can have several roles (a saga file that also exports selectors). Answer each question with evidence — `file:line`, a command and its output — or `n/a` with the reason. "Looks fine" is not an answer.

The questions come from findings human reviewers caught and automated checks missed. Most are about **what happens around the changed line**: who else writes the same state, what runs after a reset, what the data looks like on the next app launch. Reading only the diff does not answer them — open the files the question points at.

Order of work on a large diff: sagas, reducers and selectors first (they produced most of the high-severity findings), then network, config, components, tests.

## Saga / side-effect files

**S1 — Inputs guarded before they leave.** For every network call the changed code makes, list each parameter and where it comes from. Is each required value checked before the call? A guard of `if (!userId) return` that lets `itemId: undefined` through sends a malformed request. Fail when any required value can be missing at the call.

**S2 — Concurrent watchers on the same state.** For each action this saga handles, note its effect (`takeLatest`, `takeEvery`, `takeLeading`, `take` loop). Then find every *other* watcher whose handler writes the same state fields:
```bash
git grep -n -E 'take(Latest|Every|Leading)?\(' $TIP -- <saga-dir>        # all watchers
git grep -n -E '<STATE_FIELD>' $TIP -- '*Reducer*'                      # who writes the field
```
If two independent watchers act on the same entity (apply and remove, add and cancel), write out the interleaving: start A, start B, A's response lands, B's response lands. Fail when the final state can disagree with what the user last did. `takeLatest` cancels the generator, not the request already sent or its effect on the server.

**S3 — Optimistic writes.** Does the reducer change state on the *request* action, before the server answers? Then: who reverts it on failure, and does the *success* handler overwrite unconditionally — clobbering a newer user action taken while the request was in flight? Then find every *reader* of the optimistically written field — payload builders, other sagas, selectors: each one treats an unconfirmed value as confirmed and can send it to the server. Fail when there is no revert path, success can overwrite newer state, or another request is built from the unconfirmed value. An in-flight marker (request id, busy flag) checked on success is the usual fix.

**S4 — Ordering against resets.** Do this as a procedure, not a read-through:
1. List the reset actions in the repo that clear state this saga reads — `git grep -n -E 'RESET|LOGOUT|ORDER_PLACED|CLEAR' <reducer of that state>` and the reducer cases that return the initial state.
2. In the saga that triggers this work, write down the order of every `put` of those resets and every `call`/`fork`/`spawn` of this work.
3. For each piece of work after a reset: which fields does it `select`? Were they cleared by the reset? A comment that says "taken as a snapshot before reset" is a claim — check that every field read later is in the snapshot.
Fail when work reads state that a reset has already cleared (it finds nothing and silently does nothing), or writes stale state into a fresh entity.

**S5 — Silent substitution.** When the thing the user picked is no longer available, does the code quietly use a different one (`list[0]`, "first available") or continue with a default? Fail when the user's choice is replaced without telling them.

**S6 — Crash containment.** Does every worker that calls the network or parses a response catch its errors? Find how the root saga handles an uncaught error in this repo (restart, log, die) and state the consequence for this saga. Errors go through the repo's logger, not `console.*`.

**S7 — Duplicate triggers.** How many places dispatch the action that starts this saga?
```bash
git grep -n -E '<actionCreator>\(|<ACTION_TYPE>' $TIP -- . ':!*__tests__*'
```
Fail when the same screen or mount path dispatches it more than once — each dispatch is a network call.

**S9 — Matching the right identity.** Where code decides "is this the same thing" — removing a line, finding the applied item, matching a response to a request — which id does it compare: a line/instance id, or a product/type id? Two lines of the same product share a product id. Fail when a product-level id is used to pick one instance (removing one of two identical items removes the wrong one, or both).

**S10 — Reusing a saga mid-flow.** When the change calls an existing saga or worker from inside another flow, read the callee to the end: does it finish its own flow — clear a loader, fork a follow-up, navigate, dispatch success — that the caller has not finished yet? Fail when the callee's finalisation runs in the middle of the caller's flow.

**S8 — Cross-module contracts.** Does the saga `take` or `put` another module's action types, or change the payload of one that other modules take? Check against `guardrails/modules/*.md` when present; otherwise list the consumers (`take*(<TYPE>.` outside the module).

## Reducer / state files

**R1 — Persistence of each new field.** For every field added to a slice (detector `NEW-STATE-FIELD`), find the slice's persist config. With a blacklist, every new field persists by default. Classify each field: *durable* (the user expects it after restart) or *transient* (loading and busy flags, popup visibility, in-flight ids, per-order or per-session ids). Fail when a transient field is persisted — it rehydrates into a state no request will clear — or a durable one is not.

**R2 — Reset coverage.** For each new field, list the actions that end the entity it belongs to — logout, order placed, cart reset, *and the entity's id changing*. Open each of those reducer cases and check whether the field is cleared, and whether anything reads the field afterwards (payload builders especially). Fail when a field tied to one order or session survives into the next — e.g. a cancelled-discount id sent with every request for the next order.

**R3 — Reading the right state in transitions.** In a guard that compares old and new state (id change, status change), is each value read from the correct side — `state` (before) or the computed next state? Resets that return `...INITIAL_STATE` lose fields the guard reads from "next".

**R4 — Written but never read.** For each new field, is any selector or component reading it? A field written and blacklisted but never read is dead state.

**R5 — Storing too much.** Does the reducer store a whole response object where the consumers read one or two fields? Larger persisted state, and personal data persisted that did not need to be.

## Selector files

**SEL1 — New identity on every call.** Does a selector return a new array or object (`.filter`, `.map`, `{...}`) without memoisation? Every subscriber re-renders on every store update. Fail unless memoised (`createSelector` or equivalent) or called only outside render.

**SEL2 — Value before data loads.** What does the selector return while its source is `null` or not yet fetched? A feature selector that returns `true` when config is missing turns the feature on for everyone until (and if) config arrives. Fail unless the pre-load value is the safe one — normally "off".

**SEL3 — Selection logic duplicated.** For each selector the PR adds, search for the same state path read inline — `select((state) => state.<slice>.<field>)` in sagas, `useSelector((state) => …)` in components — and the same filter written by hand. Fail on each inline copy: they drift from the selector.

**SEL4 — Guessing the data shape.** Does the code try several field names or shapes "in case"? That hides an unknown API contract; ask for the contract instead.

## Network files

**N1 — The repo's request layer.** Does the call go through the layer every other network module uses (auth headers, token refresh, logging, base URL)? Detector `RAW-FETCH` flags direct `fetch`; also check for new axios instances. Fail on a bypass without a stated reason.

**N2 — Consistent contract.** Header and parameter names: are they spelled the same way as existing calls to the same backend (`clientId` vs `X-Client-Id` vs `x-client-id`)? Fail on a third spelling.

**N3 — Hosts and environments.** Every host comes from the environment config. Detector `NONPROD-HOST` flags literals; a stage or SIT host in shipped code is a production incident.

**N4 — Failure paths.** Timeout, non-2xx and malformed body: what does the caller see for each?

## Config, flags and defaults

**CFG1 — Missing value defaults to production-safe.** When an environment value, flag or remote config is absent, what is the fallback? Environment must fall back to production, not QA; a feature flag to off. Detector `NONPROD-DEFAULT` flags literal fallbacks; also read new `?? / ||` defaults by hand.

**CFG2 — Shipped defaults.** Does a bundled default config turn the new feature on? Combined with SEL2, that is on-for-everyone.

## Components / views

**C1 — Logic in the view.** Business decisions (eligibility, price, which reward) computed in the component instead of a selector or saga. The repo's rules usually say views render only.

**C2 — Layout fixed to a count the API controls.** A fixed 2×5 grid for a count the server sends (`itemsRequired`) breaks for any other value. Fail when an API-driven size is laid out with fixed numbers.

**C3 — Cleanup.** Every animation loop, interval, timeout, listener and subscription started here is stopped in the effect cleanup or unmount. Detectors `UNSTOPPED-ANIMATION`, `UNCLEARED-*`, `UNREMOVED-LISTENER` point at files; confirm each start has a stop.

**C4 — Mounted for everyone.** Is the component mounted at app root or on a shared screen without the gate its feature uses elsewhere? Ungated, it runs its hooks, effects and listeners for every user and brand.

**C5 — Text and accessibility.** User-visible text is localised (detector `JSX-LITERAL`). Font sizes legible (`SMALL-FONT`). Native-only props (`adjustsFontSizeToFit`, `minimumFontScale`) do nothing on web — check the web rendering.

**C6 — Window size at module load.** `Dimensions.get` outside a component is stale after rotation or resize (detector `MODULE-SCOPE-DIMENSIONS`); use the hook.

**C7 — Repo UI primitives and facades.** Raw primitives where the repo wraps them, SDKs imported past their facade (detector `RARE-IMPORT`). The repo's own rules and lint cover most of this; this question catches what they do not.

## Tests

**T1 — Every effect stubbed.** This is answerable without running tests. For each saga under test, list every `call`, `fork` and `spawn` it can reach (including inside forked sagas), then list the test's stubs (`provide`, `jest.spyOn`, `mockImplementation`). Fail on any reachable effect with no stub — it runs real code, real network, or depends on timing.

**T2 — Assertions that always run.** Assertions inside `if`, `forEach` over a possibly empty list, or after an early return may never execute. Fail when the key assertion can be skipped.

**T3 — Stubs that match what they claim.** A catch-all stub (`call: () => undefined`, a provider matching any `call`) makes "it called the API" true for any call. For each assertion that a specific call happened, check the stub and the assertion name the function *and* the arguments that matter. Fail when the stub would also satisfy a wrong call.

**T4 — Sensitivity.** Pick the line the test claims to cover — the flag set, the guard, the payload field — break it, and run the test. It must fail. If it passes, the test does not cover that line.

## Across files

**X1 — Removed behaviour.** For every condition, constant or rule the diff *removes*, is the removal asked for (ticket, review thread, PR description)? Rules that vanish in a refactor are regressions nobody reviews.

**X2 — Pending states.** Does a new loading state hide or block more of the screen, for longer, than the data it waits for? A whole form behind a skeleton for an 8 s timeout is a regression even when the data arrives.

**X3 — Dead code.** Detectors `UNREAD-EXPORT`, `UNIMPORTED-FILE`, `UNUSED-STYLE` list candidates; confirm each and report the confirmed ones.

**X5 — Code in the file its role says.** Parsing in an action file, an exported helper living in a saga file, a reducer reaching into another slice, a display suffix baked into data that the view also decorates. Each makes the next change touch the wrong file. Fail when new code lands in a file whose role does not fit it.

**X4 — The same decision twice.** Two functions that extract the same thing (`extractItems` here, `toItemIds` there) drift apart; the repo's duplicate-code check catches identical tokens, not the same logic written differently.
