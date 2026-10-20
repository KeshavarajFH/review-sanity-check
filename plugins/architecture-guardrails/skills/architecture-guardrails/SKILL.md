---
name: architecture-guardrails
description: Build or refresh a repo's guardrail record — the app-level and module-level contracts that must not change casually (storage and persistence drivers, persisted state keys and versions, token storage, navigation routes, cross-module saga/action contracts, network setup, platform facades). Writes guardrails/APP.md and guardrails/modules/<Module>.md, each entry with its current value, file:line, why it is guarded, a check command with expected output, and what a PR must include to change it. Use when asked to "record guardrails", "map architecture constraints", "what must not change", "build GUARDRAILS", or after an incident caused by changing one of these surfaces.
---

# Architecture guardrails

Records, in one place, the things in a codebase that look like ordinary code but behave like contracts: change them and data written by older app versions, other modules, deep links or automation silently breaks.

The motivating failure: a feature branch switched the web persistence driver from IndexedDB to localStorage. Nothing failed in review — the diff was three lines in a storage facade — but every existing user's persisted session was left behind in the old store. A guardrail record would have named that file, said why it is dangerous, and required the PR to explain the migration.

## Output

```
guardrails/
  APP.md                 # app-level: one file
  modules/<Module>.md    # module-level: one file per module
```

Every entry has the same shape (templates in `templates/`):

| Field | Content |
|---|---|
| ID | `GR-APP-<AREA>-NNN` or `GR-<MODULE>-<AREA>-NNN`, stable across regenerations |
| Contract | The current value, stated as a fact: `persist key 'root', version 2` — not "persistence should be stable" |
| Where | `file:line` for every place the value is defined |
| Why guarded | The concrete failure if it changes, and any past incident (commit or PR) |
| Check | A command whose output proves the contract still holds, plus the exact expected output |
| To change | What a PR touching it must contain in its `## Guardrail change` section |

**The rule that makes the record worth anything: every entry is measured from the code, not written from memory or intent.** If you cannot point at a file and line and show the command output, it is not a guardrail entry. If a value is your judgement rather than a measurement (for example, "this action type is part of the public contract"), mark the entry `judged` and say what you based it on. Write the Contract line, then run the check and compare: when they disagree, the Contract line is what is wrong.

### Writing checks

Discovery commands (the `rg` searches below) are for you; **check commands are for whatever runs them later** — a CI job, a hook, another engineer's shell. So checks follow stricter rules:

- **Print values, never line numbers.** No `rg -n`, no `sed -n '101,107p'`. A check whose output shifts when someone adds a line above it fails on harmless edits, and people learn to ignore it.
- **Use `git grep`, `awk`, `sed`, `sort`, `shasum`** — present wherever git is. `rg` is often not installed on CI, and in some agent shells it is a function that a script cannot see. `git grep` also searches only tracked files, which is what a contract is about.
- **Small facades: print every code line.** For a storage, token or SDK facade under ~30 lines, `git grep -h -v -E '^[[:space:]]*(//|/?\*)|^[[:space:]]*$' -- <file>`. Extracting only "the interesting parts" misses the condition that decides who gets them — a check that printed the `setDriver(...)` call but not the `if` around it passed when the driver was switched for every browser.
- **Long lists: count plus hash.** For 100+ route names, print `wc -l` and `sort -u | shasum | cut -c1-12`, and say in the entry how to print the list.
- **Exclude tests** with `':!<path>/__tests__'` pathspecs, so a test fixture does not become part of the contract.

## Step 0 — orient

```bash
git rev-parse --short HEAD                     # recorded in each file header as "verified at"
git ls-files | rg -c '\.(js|jsx|ts|tsx)$'      # JS/TS? The commands below assume it; adapt for other stacks
```

Find the entry points and the module roots. Module roots are the directories whose children are features — `src/modules/*`, `src/features/*`, `packages/*`, `AppModules/*`:

```bash
git ls-files | rg '/(index|App|main)\.(js|jsx|ts|tsx)$' | head -20
git ls-files | rg -o '^(.*?/(modules|features|AppModules|packages))/[^/]+/' -r '$1' | sort | uniq -c | sort -rn | head
```

If the repo has its own architecture notes (`CLAUDE.md`, `AGENTS.md`, `docs/architecture*`), read them first — they often name the surfaces that matter. Treat them as leads to verify, not facts to copy.

**Scope the module pass.** A large app can have 50+ modules. Ask which modules to cover if the user did not say; offer "all", "the N most imported by other modules" (command in Step 2), or a named list. Always do the app level in full.

If `guardrails/` already exists, this is a refresh: keep every existing ID, update values and `verified at`, and list entries whose check no longer matches — those are contract changes someone made, and they belong in your report.

## Step 1 — app-level surfaces

Work through each area. For each, find where the contract is defined, record the value, and write the check. Skip an area only after its discovery command returns nothing, and say so in the file.

### 1.1 Storage and persistence

The highest-risk area: persisted data outlives the code that wrote it.

```bash
rg -n --glob '!**/__tests__/**' "from '(localforage|@react-native-async-storage/async-storage|react-native-mmkv|idb-keyval|idb|redux-persist[^']*)'" | head -40
rg -n --glob '!**/__tests__/**' '\.setDriver\(|\.createInstance\(|\b(localStorage|sessionStorage|indexedDB)\b|new MMKV|MMKVLoader' | head -40
rg -n --glob '!**/__tests__/**' 'persistReducer\(|persistStore\(|createMigrate\(' | head -40
```

Record, per platform (native, web, SSR):
- **The storage engine and driver** for persisted state, including any per-browser or per-platform selection. A driver switch orphans existing data unless a migration copies it.
- **Every persist config**: `key`, `keyPrefix`, `version`, `storage`, `whitelist`/`blacklist`, `migrate`, `transforms`, and nested configs. Renaming a `key` or `keyPrefix` orphans that slice; bumping `version` without a migration drops or mis-reads it; adding a slice to a blacklist silently stops persisting it.
- **Migrations**: the highest version handled, and whether it matches `version`.
- **Other stores** written outside redux-persist (direct `localStorage` keys, MMKV instances, consent or chat outboxes) and their keys.

Checks print the exact values, so a change shows up as a diff in the output:

```bash
git grep -h -o -E "key: '[A-Za-z]+'" -- <persist-config-file> | sort
git grep -h -v -E '^[[:space:]]*(//|/?\*)|^[[:space:]]*$' -- <storage-facade-file>
awk '/const [A-Za-z]+ = \{/ { match($0, /const [A-Za-z]+/); n = substr($0, RSTART + 6, RLENGTH - 6) } /version: [0-9]+/ { match($0, /[0-9]+/); print n, "version", substr($0, RSTART, RLENGTH) }' <persist-config-file>
```

Also record which files import each storage SDK. If only facades do, that is a contract of its own: a feature importing the SDK directly is how a driver change reaches part of the app and not the rest.

### 1.2 Auth and token storage

```bash
rg -n --glob '!**/__tests__/**' -i 'access_?token|refresh_?token|setTokens|getTokens|Keychain|SecureStore|encryptedStorage' -l | head -30
```

Record where tokens are written and read on each platform, the storage key names, whether it is secure storage or plain, and which code path owns refresh. Changing a key name logs every user out; moving a token from secure to plain storage is a security change, not a refactor.

### 1.3 Navigation

```bash
rg -n --glob '!**/__tests__/**' 'route_name|createNativeStackNavigator|createStackNavigator|<Stack\.Screen|linking\s*=|prefixes:' -l | head -20
```

Record the route-name registry (count, and where it lives), the deep-link / linking config, the initial route, and the navigation library major version. A renamed or removed route breaks deep links, push-notification targets, and saved web URLs that are not in this repo. For large registries, record the check as a count plus a sorted list file, not 200 entries inline:

```bash
git grep -h -o -E "route_name: '[^']+'" -- <routes-file> | sort -u | wc -l | tr -d ' '
git grep -h -o -E "route_name: '[^']+'" -- <routes-file> | sort -u | shasum | cut -c1-12
```

On web, the route-to-URL mapping is a separate contract from the route names — the URLs are public (bookmarks, search indexes, shared links). Record it separately.

### 1.4 State wiring

```bash
rg -n --glob '!**/__tests__/**' 'combineReducers\(|configureStore\(|createStore\(|runSaga|sagaMiddleware\.run|injectReducer|injectSaga' | head -20
```

Record the root reducer's slice keys (a renamed slice key is a renamed persist key), how sagas are registered (root saga, injectors), and any global registries modules use to reach the store.

### 1.5 Network

```bash
rg -n --glob '!**/__tests__/**' 'baseURL|BASE_URL|axios\.create|interceptors\.(request|response)|fetch\(' -l | head -20
```

Record base-URL selection per environment, interceptors and what they add (auth headers, client-type headers, retries), and timeouts. Header names the backend keys on are contracts with another team.

### 1.6 Platform facades and third-party SDKs

```bash
git ls-files | rg '\.(web|native|ios|android)\.(js|jsx|ts|tsx)$' | sed -E 's/\.(web|native|ios|android)\./\./' | sort | uniq -c | sort -rn | head -30
```

Record each facade (the base file and its platform variants) and, where the codebase has a "only the facade imports the SDK" rule, the check that proves it:

```bash
rg -l "from '<sdk>'" | rg -v '<facade-file>'          # expected: no output
```

### 1.7 Build, environment and brand config

Record env-file variants, brand or white-label switches, and feature-flag defaults that are read at build time. A flipped default ships to everyone.

### 1.8 Incident history

Past incidents are the strongest "why guarded" evidence. For every file you recorded above:

```bash
git log --format='%h %ad %an | %s' --date=short -- <file> | head -10
git log -S'<distinctive value>' --format='%h %ad | %s' --date=short -- <file>
git log --all --format='%h %s' | rg -i 'revert|hotfix|p1|incident|rollback' | head -20
```

Link the commit or PR that introduced a risky value, and any revert or hotfix that touched it.

## Step 2 — module-level surfaces

Rank modules by how much the rest of the app depends on them, so the scoping question in Step 0 has data behind it:

```bash
for m in <module-root>/*/; do
  n=$(basename "$m")
  c=$(rg -l "[/'\"]$n/" --glob '!'"$m"'**' --glob '!**/__tests__/**' | wc -l)
  echo "$c $n"
done | sort -rn | head -20
```

The `[/'"]` before the name matters: without it, `BaseModule/` also counts every import of `T2SBaseModule/`.

For each module in scope, record:

1. **Cross-module action contracts (saga callers).** An import list is the wrong measure — a large module can have 70 importing files, most of them harmless. What breaks silently is another module's saga *reacting to* or *writing through* this module's action types. Find the module's type object name (`git grep -h -o -E 'export const [A-Z_]+_TYPES?' -- <module>`), then:
   ```bash
   # actions other modules' sagas take — rename one and their takeLatest gets undefined
   git grep -o -E 'take(Latest|Every|Leading)?\( *<PREFIX>_TYPE\.[A-Z_]+' -- <source-root> ':!<module>' ':!<source-root>/__tests__' \
     | sed -E 's/:take(Latest|Every|Leading)?\( */ /' | awk '{ print $2, $1 }' | sort -u
   # actions other modules dispatch by type — the reducer must keep handling them
   git grep -h -o -E 'put\(\{ *type: *<PREFIX>_TYPE\.[A-Z_]+' -- <source-root> ':!<module>' ':!<source-root>/__tests__' \
     | grep -o -E '<PREFIX>_TYPE\.[A-Z_]+' | sort | uniq -c | awk '{ print $1, $2 }'
   ```
   These commands are already in check form; use them as the entry checks. Then note the reverse — which other modules' types this module's sagas take — and point at those modules' entries rather than duplicating them.
2. **Persisted state.** The module's slice key, its persist config (from 1.1), and which fields are persisted or excluded. A field rename or type change needs a migration; with a blacklist, every new field is persisted by default.
3. **Routes owned.** Find where screens are registered — the navigator file, or a lazy-loading wrapper that maps routes to module views — and grep it for the module's view paths. A moved view file breaks a lazy import at runtime, not at build time.
4. **Selectors, helpers and constants used outside the module.** Same import search with `Selector|Helper|Constants`.
5. **Endpoints.** First find the module's request-definition shape (`url:` objects, `axios.get(`, a generated client), then list method + path. A count plus hash is the check; the endpoint list goes in the entry body for readers. Backend contract.
6. **Automation identifiers**, when the project has them (test IDs, screen-name constants): renaming one breaks test automation outside this repo.

Skip any of these that returns nothing, and write "none found" with the command — an empty section is information.

## Step 3 — write the files

Use `templates/APP.md` and `templates/MODULE.md`. Each file starts with:

- `Verified at <sha> on <date>` and how to regenerate (this skill).
- **The change protocol** (below), verbatim, so a reader who only opens one file knows it.

Number IDs per area. On a refresh, never renumber: removed contracts get `Status: retired (<sha>)`, not a deleted entry.

### Change protocol

A PR that changes a guarded value is allowed, but it must say so. The PR description contains:

```markdown
## Guardrail change

- **IDs:** GR-APP-STORAGE-001
- **What changes:** old value → new value
- **Why:** the reason the contract has to move
- **Existing data / callers:** how data written by the old version, or callers in other modules, are handled — migration, dual-read, or why none is needed
- **Rollback:** what happens if this ships and is reverted
```

and updates the guardrail entry (value, `Where`, expected check output) in the same PR. A PR that changes a guarded value without this section is a review finding. How that is enforced — reviewer, review skill, CI — is the repo's choice; this skill only makes the contracts and their checks explicit.

## Step 4 — verify the record

Copy `scripts/verify-guardrails.sh` from this skill into the repo (`guardrails/verify.sh`), so the record carries its own checker. It extracts every entry's Check block, runs it from the repo root, and diffs the output against the Expected block:

```bash
bash guardrails/verify.sh --show guardrails/APP.md guardrails/modules/*.md   # actual output of every check
bash guardrails/verify.sh guardrails/APP.md guardrails/modules/*.md          # ok / FAIL with diff; exit 1 on any FAIL
```

Fill Expected blocks from `--show`, then read each output against its Contract line — the output must *say* what the Contract claims. A disagreement means the Contract line is wrong, not the check. Every check must match before you finish.

### Prove the high-risk checks fail

A check that matches today proves the record is accurate, not that it would catch anything. For every storage, persistence and auth entry at least, make the change the entry guards against and confirm the check fails. Do it in a throwaway copy, never in the user's working tree:

```bash
T=$(mktemp -d)
git archive HEAD | tar -x -C "$T" && cd "$T" && git init -q && git add -A && git commit -qm base --no-verify
# edit the guarded value (switch a storage driver, rename a persist key, rename a consumed action type)
git commit -qam mutation --no-verify
bash <path-to>/verify.sh <path-to>/guardrails/APP.md <path-to>/guardrails/modules/*.md    # must show FAIL for that entry
```

Also make one harmless edit — a comment, a line added above the guarded code — and confirm everything still passes. A check that fails on harmless edits gets ignored.

Report each mutation and its result. A guarded change that passes all checks is a gap in the record: fix the check, re-fill its Expected block, and repeat the mutation.

## Report

State which areas and modules you covered and which you did not, the number of entries in each file, the verifier result (`N/N checks match`), each mutation you ran and whether its check failed, which areas returned nothing (with the command), which entries are `judged` rather than measured, and — on a refresh — every entry whose value changed since the last `verified at`. Changed contracts are the headline: someone moved one without the protocol.

Contract lines you had to correct after running their check are worth listing too: they are the places the team's mental model of the code is out of date.
