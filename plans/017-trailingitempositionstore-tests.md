# Plan 017: Add tests for `TrailingItemPositionStore` key-resolution and weight math

> **Executor instructions**: Follow this plan step by step.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/MenuBar/HiddenSectionPatch/TrailingItemPositionStore.swift"`
> If the file changed since this plan was written, re-read the cited lines.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

`TrailingItemPositionStore` writes the private
`TrailingItemPreferredPositions` plist and is the ONLY surgical per-item
hide mechanism on macOS 27 (the assertion hides per-bundle, not per-item).
Wrong key resolution here tiles iStat-style dynamic-title items onto stale
keys, scrambling order or hiding the wrong item silently.
`computeRestoreWeight`'s midpoint-then-fallback logic
(`TrailingItemPositionStore.swift:299-309`) produces a wrong weight when
neighbors are exactly 1 apart, and no test pins that behavior. Grep for
`TrailingItemPositionStore` across `ThawTests/` returns nothing — zero
direct tests. The pure helpers (`resolvedPositionKey` `:339`,
`resolvePositionalKey` `:402`, `computeRestoreWeight` `:262`) match the
shape of the well-tested `MenuBarAgentPositionStoreTests.swift:36-186`
(which tests its parallel `resolveKey`).

## Current state

`Thaw/MenuBar/HiddenSectionPatch/TrailingItemPositionStore.swift`:
- `:339-382` — `static func resolvedPositionKey(for:existingKeys:)` (module/status/display-name tiers).
- `:402-427` — `static func resolvePositionalKey(for:existingKeys:positions:allItems:)` (iStat fallback).
- `:262-310` — `computeRestoreWeight(for:savedWeight:existingKeys:positions:allItems:)` (midpoint logic at `:299-309`).
- `:144-186` — `hideItems` (instance; needs an `Environment` seam to test).
- `:197-241` — `showItems` (instance).
- `:431-460` — `readPositions`; `:462-482` — `writePositions` (instance; these are the I/O the `Environment` seam would abstract).

Existing exemplar: `ThawTests/MenuBarAgentPositionStoreTests.swift:36-186`
tests the parallel `MenuBarAgentPositionStore.resolveKey` with fixture
items and an injected `Environment`.

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/MenuBar/HiddenSectionPatch/TrailingItemPositionStore.swift` (add
  an `Environment` seam matching `MenuBarAgentPositionStore`; do NOT
  change the resolution logic)
- `ThawTests/TrailingItemPositionStoreTests.swift` (create)

**Out of scope**:
- Do NOT change the resolution/weight logic itself (only test it).
- Do NOT touch `MenuBarAgentPositionStore` (it's the exemplar).
- Do NOT change `readPositions`/`writePositions` behavior (plan 007
  handles the writePositions race).

## Git workflow

- Branch: `advisor/017-trailingitempositionstore-tests`
- Commit style: `test(hider): characterize TrailingItemPositionStore key resolution and restore weights`

## Steps

### Step 1: Add an `Environment` seam to `TrailingItemPositionStore`

Mirror `MenuBarAgentPositionStore.Environment` (read it first —
`Thaw/MenuBar/MenuBarItems/MenuBarAgentPositionStore.swift` around the
`Environment` struct). Add to `TrailingItemPositionStore`:

```swift
@MainActor
struct Environment {
    let readPositions: @MainActor () -> [String: Int]
    let writePositions: @MainActor ([String: Int]) -> Void

    static var live: Environment {
        Environment(
            readPositions: { /* the current readPositions body */ },
            writePositions: { /* the current writePositions body */ }
        )
    }
}
```

Change `init` to accept `environment: Environment = .live` (matching
`CGSWindowHider.init`). Route `readPositions()`/`writePositions()` (and
the planned `willTerminate` observer from plan 002) through `environment`.

**Verify**: build → exit 0; production behavior unchanged.

### Step 2: Create `ThawTests/TrailingItemPositionStoreTests.swift`

Model on `MenuBarAgentPositionStoreTests.swift` (its injection + fixture
pattern). Build fixture `MenuBarItem`s (use `ThawTests/MenuBarTestFixtures.swift`
if it has builders; read it first).

Test cases (pure statics first, then instance via injected Environment):
1. `testResolvedPositionKey_ModuleKey` — an Apple module item → resolves
   to `module:<title>`.
2. `testResolvedPositionKey_BundleIDForm` — third-party item →
   `status:<bundleID>::<title>`.
3. `testResolvedPositionKey_DisplayNameSuffix` — item whose key is in
   display-name form → suffix-match resolves it.
4. `testResolvedPositionKey_DynamicTitleReturnsNil` — iStat-style item
   whose title isn't in any key → returns `nil` (caller falls back to
   positional).
5. `testResolvePositionalKey_FamilySizeMismatch` — `family.count != familyKeys.count` → returns `nil`.
6. `testResolvePositionalKey_PairsByLeftToRightOrder` — families match
   in size → the Nth item maps to the Nth-by-weight key.
7. `testComputeRestoreWeight_MidpointBetweenNeighbors` — left=100,
   right=200 → returns 150.
8. `testComputeRestoreWeight_NeighborsOneApart` — left=100, right=101 →
   midpoint 100 equals `lo` → returns `savedWeight` (the `mid != lo && mid != hi` guard at `:302`).
9. `testComputeRestoreWeight_OnlyLeftNeighbor` — returns `lo + 10`.
10. `testHideItems_RemovesKeyAndRecordsWeight` — inject an Environment
    with a known positions dict, hide an item, assert the key was
    removed and `hiddenPlistKeys` recorded the weight.
11. `testShowItems_RestoresKeyWithNeighborWeight` — after hide, show
    restores the key with a weight between neighbors.

**Verify**: `xcodebuild test ...` → exit 0, 11 new tests pass.

### Step 3: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` → no leftover diffs (incl. copyright header).

## Test plan

- 11 new tests in `ThawTests/TrailingItemPositionStoreTests.swift` (listed in Step 2).
- Model after `ThawTests/MenuBarAgentPositionStoreTests.swift`.
- Verification: `xcodebuild test ...` → all pass including the 11 new tests.

## Done criteria

- [ ] `TrailingItemPositionStore.Environment` seam exists (matching `MenuBarAgentPositionStore`).
- [ ] `ThawTests/TrailingItemPositionStoreTests.swift` exists with the 11 cases, all passing.
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- `MenuBarTestFixtures.swift` doesn't provide a way to build `MenuBarItem`
  fixtures with specific `tag`/`bounds`/`windowID` — extend it minimally
  or build items inline; if `MenuBarItem`'s initializer is private, ask
  how existing tests construct items.
- The `Environment` seam conflicts with plan 002's `willTerminate`
  observer addition — coordinate; the observer should use the injected
  `notificationCenter` (matching `CGSWindowHider`), not a hardcoded one.
- `computeRestoreWeight`'s signature uses `existingKeys: [String]` and
  `positions: [String: Int]` — if it can't be called as a pure function
  without `self`, extract it to `static` first (it already reads only its
  parameters, so this should be mechanical).

## Maintenance notes

- The `Environment` seam is the prerequisite for testing plan 007's
  gated `writePositions` fallback — add that test here or in 007.
- A reviewer should confirm the `Environment.live` `readPositions`/`writePositions`
  closures exactly match the pre-seam bodies (no behavior change).
