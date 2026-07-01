# Plan 030: Generalize `SettingsSearchIndex`'s ranking into a shared `SearchRanker`

> **Executor instructions**: Follow this plan step by step.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/Settings/SettingsSearchIndex.swift" "Thaw/Settings/SettingsSearchModel.swift" "Thaw/MenuBar/Search/MenuBarSearchModel.swift"`
> If any file changed since this plan was written, re-read the cited lines.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: direction (tech-debt)
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

Two parallel fuzzy-search code paths drift independently. The settings
side just landed a clean, generic, explicitly-extracted ranking helper
(`SettingsSearchIndex.swift:74-87` `sortedByRelevance<T>(_ items: [(item: T, diffScore: Double)])`,
extracted "so it can be unit-tested without linking Ifrit into the test
target"). The menu-bar-item side (`Thaw/MenuBar/Search/MenuBarSearchModel.swift:37`)
still hand-rolls a second `Fuse(threshold: 0.5)` instance and its own
weighting/filtering path; the settings-side generic isn't used there.
Future search surface (the README roadmap's "menu bar item groups" and
"spacer items" will want group/spacer search too, and "search menu bar
items" is already shipped at `README.md:119`) would re-implement the
wheel a third time. One shared `SearchRanker` keeps both consistent and
makes future search ride the same pipe.

## Current state

- `Thaw/Settings/SettingsSearchIndex.swift:74-87` — `sortedByRelevance<T>(...)`
  (generic, extracted, tested by `SettingsSearchIndexTests.swift:68-141`).
- `Thaw/Settings/SettingsSearchModel.swift:49-77` — inline `SearchItem: Searchable`
  with hand-rolled `FuseProp` weighting (title 0.3 / keywords 0.6 / description 1.0).
- `Thaw/MenuBar/Search/MenuBarSearchModel.swift:37` — `fuse = Fuse(threshold: 0.5)`, separate filtering path.
- `SettingsSearchIndex.swift:32-38` — doc notes `SectionedListItem` is
  the shared precedent between the two search systems.

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/Settings/SettingsSearchIndex.swift` (lift `sortedByRelevance` +
  the `Searchable`/`FuseProp` weighting into a `SearchRanker` enum/struct)
- `Thaw/Settings/SettingsSearchModel.swift` (adopt `SearchRanker`)
- `Thaw/MenuBar/Search/MenuBarSearchModel.swift` (adopt `SearchRanker`)

**Out of scope**:
- Do NOT change the search UI or results display — only the ranking pipe.
- Do NOT change Ifrit/Fuse versions.

## Git workflow

- Branch: `advisor/030-settings-search-ranking-generalize`
- Commit style: `refactor(search): share SettingsSearchIndex ranking across menu-bar-item search`

## Steps

### Step 1: Locate where `MenuBarSearchModel` does its filtering

Read `Thaw/MenuBar/Search/MenuBarSearchModel.swift` fully and find where
`displayedItems` is filtered/sorted (it may live in a view, not the
model — the subagent noted this uncertainty). Confirm the exact reuse
surface before refactoring. **STOP** if the filtering is in a view and
lifting `SearchRanker` into it is awkward — report and scope down.

### Step 2: Lift the ranking into a `SearchRanker`

In `SettingsSearchIndex.swift` (or a new `Thaw/Settings/SearchRanker.swift`),
define:
```swift
enum SearchRanker {
    static func rank<T: Searchable>(
        _ items: [T],
        query: String,
        weights: SearchWeights
    ) [(item: T, score: Double)]
    static func sortedByRelevance<T>(_ items: [(item: T, diffScore: Double)]) -> [(item: T, diffScore: Double)]
}
struct SearchWeights { let title, keywords, description: Double }
```
Move the existing `sortedByRelevance` and the `Searchable`/`FuseProp`
weighting recipe into it. Keep `SettingsSearchIndex` calling it (behavior
unchanged).

### Step 3: Adopt `SearchRanker` in `MenuBarSearchModel`

Replace `MenuBarSearchModel`'s hand-rolled ranking with a `SearchRanker.rank(...)`
call (with menu-bar-item-appropriate weights). Add a drift-guard test
equivalent to the settings one (`SettingsSearchIndexTests.swift:68-141`)
for menu-bar-item search.

**Verify**: `xcodebuild test ...` → exit 0, new test passes, existing settings-search tests still pass.

### Step 4: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` clean.

## Test plan

- A new drift-guard test for menu-bar-item search (mirroring
  `SettingsSearchIndexTests.swift:68-141`).
- Existing settings-search tests must still pass.
- Verification: `xcodebuild test ...` → all pass.

## Done criteria

- [ ] `SearchRanker` exists and is adopted by both `SettingsSearchModel` and `MenuBarSearchModel`.
- [ ] A drift-guard test for menu-bar-item search exists and passes.
- [ ] Existing settings-search tests still pass.
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- `MenuBarSearchModel`'s filtering lives in a view (not the model) and
  lifting `SearchRanker` into it is awkward — STOP and report; scope
  down to the settings side only, or spawn a follow-up.
- The two search paths use different `Fuse`/`FuseProp` configurations in
  a way that a shared `SearchWeights` can't capture — report the
  difference; don't force-fit.

## Maintenance notes

- The shared `SearchRanker` is the pipe future search surface (groups,
  spacers) should adopt — keep it minimal and well-tested.
- A reviewer should confirm the menu-bar-item search RESULTS are
  unchanged (same ranking order for the same query) — this is a pure
  refactor, not a behavior change.
