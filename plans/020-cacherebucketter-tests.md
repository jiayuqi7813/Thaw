# Plan 020: Add tests for `CacheRebucketter.rebucket`

> **Executor instructions**: Follow this plan step by step.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/MenuBar/MenuBarItems/CacheRebucketter.swift"`
> If the file changed since this plan was written, re-read the cited lines.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plan 016 (SimpleItemHider injection) — OR refactor
  `rebucket` to take closures instead of the whole hider (see Step 1).
- **Category**: tests
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

`CacheRebucketter.rebucket` (`CacheRebucketter.swift:14`) reconstructs
the Visible/Hidden/Always-Hidden cache buckets from assignment + retained
snapshots. This module produces what the layout UI and the bounds-lookup
cache show the user. Bugs here surface as "items disappear from the
Hidden bar" or "concealed items reappear in Visible" — regressions that
look like user-data loss. The sole test touching this type
(`MenuBarItemTagTests.swift:970-986`) exercises only the four-line
`retainedCachedItems` helper (`CacheRebucketter.swift:71-76`); nothing
drives `rebucket` itself. The moved-live-items / missing-concealed-items
/ alwaysHidden-disabled flattening paths are not pinned.

## Current state

`Thaw/MenuBar/MenuBarItems/CacheRebucketter.swift`:
- `:14` — `rebucket(_:hider:allowsAlwaysHidden:)` (the main entry; takes
  a `SimpleItemHider`).
- `:57-63` — the snapshot-add-back path for concealed items that drop
  out of AX enumeration.
- `:71-76` — `retainedCachedItems` (the only tested helper).

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/MenuBar/MenuBarItems/CacheRebucketter.swift` (refactor `rebucket`
  to take closures instead of the whole `SimpleItemHider` — see Step 1)
- `ThawTests/CacheRebucketterTests.swift` (create)

**Out of scope**:
- Do NOT change the bucketing logic itself (only test it).
- Do NOT touch `SimpleItemHider` beyond the call-site update.

## Git workflow

- Branch: `advisor/020-cacherebucketter-tests`
- Commit style: `test(cache): characterize CacheRebucketter.rebucket bucket placement`

## Steps

### Step 1: Refactor `rebucket` to take closures (decouple from `SimpleItemHider`)

`rebucket(_:hider:allowsAlwaysHidden:)` takes the whole `SimpleItemHider`.
To test it without plan 016's full injection, change the signature to
take closures:
```swift
static func rebucket(
    _ cache: ItemCache,
    sectionFor: (MenuBarItem) -> MenuBarSection.Name,
    allowsAlwaysHidden: Bool,
    retainedSnapshotFor: (String) -> MenuBarItem?
) -> ItemCache
```
Update the call site in `SimpleItemHider` (or wherever `rebucket` is
called) to pass the closures that read from the hider. Behavior unchanged.

**Verify**: build → exit 0.

### Step 2: Create `ThawTests/CacheRebucketterTests.swift`

Model on `ThawTests/MenuBarTestFixturesTests.swift` (read it for fixture
`ItemCache` builders). Test cases:
1. `testRebucket_LiveItemGoesToAssignedSection` — a live item assigned
   `.hidden` → appears in the Hidden bucket.
2. `testRebucket_ConcealedItemMissingFromAXRestoredFromSnapshot` — an
   item in the snapshot but not in live items → restored to its assigned
   bucket via `retainedSnapshotFor`.
3. `testRebucket_AlwaysHiddenDisabledFlattensAlwaysHiddenIntoHidden` —
   `allowsAlwaysHidden == false` → Always-Hidden-assigned items appear
   in the Hidden bucket (not Always-Hidden).
4. `testRebucket_AlwaysHiddenEnabledKeepsSeparate` —
   `allowsAlwaysHidden == true` → Always-Hidden items in their own bucket.
5. `testRebucket_VisibleItemStaysVisible` — a live `.visible` item →
   Visible bucket.

**Verify**: `xcodebuild test ...` → exit 0, 5 new tests pass.

### Step 3: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` → no leftover diffs.

## Test plan

- 5 new tests in `ThawTests/CacheRebucketterTests.swift` (listed in Step 2).
- Verification: `xcodebuild test ...` → all pass including the 5 new tests.

## Done criteria

- [ ] `rebucket` takes closures (decoupled from `SimpleItemHider`).
- [ ] `ThawTests/CacheRebucketterTests.swift` exists with the 5 cases, all passing.
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- `ItemCache` is not easily constructible in tests (opaque internals) —
  extend `MenuBarTestFixtures.swift` or add a test builder; if the type
  is frozen, report.
- The call site of `rebucket` is large/complex and the closure refactor
  is risky — then fall back to plan 016's injected `SimpleItemHider` and
  pass a fake hider; do not force the closure refactor if it's not clean.
- `retainedSnapshotFor`'s signature doesn't match how snapshots are
  actually keyed — read `:57-63` and match the keying exactly.

## Maintenance notes

- The closure refactor makes `rebucket` a pure function — easier to test
  and reason about. Keep it pure.
- A reviewer should confirm the `SimpleItemHider` call site still passes
  the real section-assignment and snapshot lookups.
