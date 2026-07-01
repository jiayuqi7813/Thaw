# Plan 003: Fix unreachable `enableExperimentalOverflowPrevention` URI key and update `URI_SCHEMES.md`

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- Thaw/Utilities/SettingsURIHandler.swift docs/URI_SCHEMES.md`
> If either in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug (code) + docs
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

Commit `cb9b5166` ("feat(settings): expose new advanced settings in URI
handler") added `enableExperimentalOverflowPrevention` to the URI handler's
`keyMapping` but NOT to `supportedBooleanKeys`. The validation function
`isValidSettingsKey` checks only `supportedBooleanKeys`/`doubleKeys`/`enumKeys`/`perDisplayKeys`
— so `enableExperimentalOverflowPrevention` is mapped but unreachable: any
`thaw://set?key=enableExperimentalOverflowPrevention&value=true` from an
authorized automation tool is rejected as "Invalid key" before reaching the
mapping. The commit promised support the code doesn't deliver.

Separately, `docs/URI_SCHEMES.md` is missing five keys the handler actually
accepts: `tempShowInterval` (added on this branch) and four pre-existing
booleans (`enableMenuBarItemOverflow`, `searchIncludeVisible`,
`searchIncludeHidden`, `searchIncludeAlwaysHidden`). The doc is the
explicit reference for automation users (Raycast/Alfred/Bash); drift in a
security-sensitive URI surface is the worst place for it.

## Current state

`Thaw/Utilities/SettingsURIHandler.swift`:

- Lines 19-43 — `supportedBooleanKeys` (the list `isValidSettingsKey`
  checks). `enableExperimentalOverflowPrevention` is **absent**.
- Line 89 — `keyMapping` has `"enableExperimentalOverflowPrevention": .enableExperimentalOverflowPrevention`.
- Lines 46-52 — `doubleKeys` includes `"tempShowInterval"` (line 49).
- Lines 102-108 — `doubleRanges` has `"tempShowInterval": (0, 30)` (line 105).
- Lines 312-317 — `isValidSettingsKey` returns
  `supportedBooleanKeys.contains(key) || doubleKeys.contains(key) || enumKeys.contains(key) || perDisplayKeys.contains(key)`.
  So a key must be in one of those four lists to pass; `keyMapping` alone is
  not enough.

`docs/URI_SCHEMES.md:149-156` (Double settings table) lists only
`rehideInterval`, `showOnHoverDelay`, `tooltipDelay`, `iconRefreshInterval`
— missing `tempShowInterval`. `docs/URI_SCHEMES.md:128-147` (Boolean
settings table) is missing `enableMenuBarItemOverflow`,
`searchIncludeVisible`, `searchIncludeHidden`, `searchIncludeAlwaysHidden`,
and `enableExperimentalOverflowPrevention`.

**Decision point (resolve in Step 1):** the branch deliberately labels
these `enableExperimental*` (see `Thaw/Utilities/Defaults.swift:185-187`
and `Thaw/Settings/SettingsSearchIndex.swift:61-67` where
`enableExperimentalWindowHiding` is excluded from settings search). The
maintainer may prefer to keep experimental keys OUT of the URI surface
until graduated (see `plans/028-experimental-flags-graduation.md`). This
plan's default is: **make the code match the commit's promise** — add the
key to `supportedBooleanKeys` so it works as intended. If the maintainer
prefers the opposite (remove it from `keyMapping`), Step 1 has the
alternative.

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |
| XCStrings validate (CI runs this on changed .xcstrings; not needed here, but be aware) | — | — |

## Scope

**In scope**:
- `Thaw/Utilities/SettingsURIHandler.swift`
- `docs/URI_SCHEMES.md`
- `ThawTests/SettingsURIHandlerTests.swift` (add cases — check it exists first; if absent, see STOP condition)

**Out of scope**:
- Do NOT change `Defaults.swift` or `SettingsSearchIndex.swift` (the
  `nonSearchableProperties` exclusion is a separate concern, covered by
  plan 028).
- Do NOT add `enableExperimentalWindowHiding` or
  `enableExperimentalSystemItemHiding` to the URI surface (out of scope for
  this fix; only `enableExperimentalOverflowPrevention` was promised by
  commit `cb9b5166`).
- Do NOT touch other URI handler logic.

## Git workflow

- Branch: `advisor/003-uri-handler-unreachable-key`
- Commit style: `fix(settings): make enableExperimentalOverflowPrevention reachable via URI and document missing keys`

## Steps

### Step 1: Add `enableExperimentalOverflowPrevention` to `supportedBooleanKeys`

In `Thaw/Utilities/SettingsURIHandler.swift`, add `"enableExperimentalOverflowPrevention"`
to the `supportedBooleanKeys` array (lines 19-43). Place it at the end of
the array, after `"searchIncludeAlwaysHidden"` (line 42), with a trailing
comma (the repo mandates trailing commas — `.swiftformat` enforces this).

The line to add:
```swift
        "enableExperimentalOverflowPrevention",
```

**Alternative (only if the maintainer directed it)**: instead of adding to
`supportedBooleanKeys`, remove line 89 (`"enableExperimentalOverflowPrevention": .enableExperimentalOverflowPrevention,`)
from `keyMapping` so the mapping matches the unreachable reality, and skip
documenting it in `URI_SCHEMES.md`. The default is to ADD (Step 1 as
written); only take the alternative if explicitly instructed.

**Verify**: `grep -n "enableExperimentalOverflowPrevention" Thaw/Utilities/SettingsURIHandler.swift` → the key now appears in BOTH `supportedBooleanKeys` and `keyMapping`.

### Step 2: Document the missing keys in `docs/URI_SCHEMES.md`

Read `docs/URI_SCHEMES.md` around lines 128-156 to see the exact table
format (columns, example rows). Match that format exactly.

- In the **Boolean settings table** (around line 128-147), add rows for:
  `enableMenuBarItemOverflow`, `searchIncludeVisible`,
  `searchIncludeHidden`, `searchIncludeAlwaysHidden`, and
  `enableExperimentalOverflowPrevention`. Use the same columns as existing
  rows. For `enableExperimentalOverflowPrevention`, note it is experimental
  (default off) in the description column.
- In the **Double settings table** (around line 149-156), add a row for
  `tempShowInterval` with range `0-30` and default per
  `Thaw/Utilities/Defaults.swift` (read the default there; if unsure, state
  "default: see Advanced settings").

**Verify**: `grep -n "tempShowInterval" docs/URI_SCHEMES.md` → at least one match; `grep -n "searchIncludeVisible" docs/URI_SCHEMES.md` → at least one match.

### Step 3: Add tests for the now-reachable key

Check whether `ThawTests/SettingsURIHandlerTests.swift` exists
(`ls ThawTests/SettingsURIHandlerTests.swift`). If it exists, add two
cases mirroring the existing boolean set/toggle tests:
- `testSetEnableExperimentalOverflowPreventionViaURI` — set the key to
  `true` via `handleSet` (with a whitelisted sender or by calling
  `handleSet` directly if existing tests bypass `isWhitelisted`), assert
  `Defaults.bool(forKey: .enableExperimentalOverflowPrevention) == true`.
- `testToggleEnableExperimentalOverflowPreventionViaURI` — toggle it and
  assert the value flipped.

If `ThawTests/SettingsURIHandlerTests.swift` does NOT exist, STOP and
report — do not create a new test file without an exemplar pattern; ask
the reviewer whether to model after `ThawTests/HotkeyActionTests.swift` or
another existing handler test.

**Verify**: `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` → exit 0, new tests pass.

### Step 4: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` → no leftover diffs.

## Test plan

- New tests in `ThawTests/SettingsURIHandlerTests.swift` (if it exists):
  - `testSetEnableExperimentalOverflowPreventionViaURI` (set true, assert value).
  - `testToggleEnableExperimentalOverflowPreventionViaURI` (toggle, assert flip).
- Model after an existing boolean set/toggle test in the same file (read
  the file first to find the pattern).
- Verification: `xcodebuild test ...` → all pass including the 2 new tests.

## Done criteria

- [ ] `enableExperimentalOverflowPrevention` appears in `supportedBooleanKeys` (or, if the alternative was taken, is removed from `keyMapping` — record which).
- [ ] `docs/URI_SCHEMES.md` documents `tempShowInterval` and the four search/overflow booleans.
- [ ] `isValidSettingsKey("enableExperimentalOverflowPrevention")` returns `true` (verify by test or by `grep`).
- [ ] `xcodebuild test ...` exits 0; 2 new tests pass (or none added if the test file was absent and you STOPPED).
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- `ThawTests/SettingsURIHandlerTests.swift` does not exist — stop and ask
  which exemplar to model a new test file after (do not invent a test
  pattern).
- The `docs/URI_SCHEMES.md` table format has changed since this plan was
  written (drift) — re-read and match the live format before editing.
- `enableExperimentalOverflowPrevention` is not in `Defaults.Key` (i.e.
  `.enableExperimentalOverflowPrevention` doesn't resolve) — report and
  stop; the key may have been renamed.

## Maintenance notes

- When `enableExperimentalOverflowPrevention` is graduated (prefix dropped)
  per plan 028, update both `supportedBooleanKeys` and `URI_SCHEMES.md` to
  the new name in the same PR.
- A reviewer should confirm the `keyMapping` and `supportedBooleanKeys`
  entries use the identical string (no typo) — a mismatch silently
  re-breaks reachability.
- Any future settings key added to `keyMapping` MUST also be added to one
  of the four validation lists or it is unreachable; consider a future
  plan to assert at test-time that every `keyMapping` key is in a
  validation list (out of scope here).
