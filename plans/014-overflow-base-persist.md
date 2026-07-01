# Plan 014: Persist `overflowBase` across calls so newly-hidden items get unique weights

> **Executor instructions**: Follow this plan step by step.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift"`
> If the file changed since this plan was written, re-read the cited lines.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug (experimental)
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

`applyExperimentalOverflowPreventionIfEnabled` (`SimpleItemHider.swift:1058-1098`)
pushes hidden items' position weights to extreme values (50000+) so the
native macOS 27 menu bar overflow on notched displays collapses them
before visible items. But `var overflowBase = 50000` (`:1070`) is a LOCAL
reset to 50000 on every `refresh()` call. So a newly-hidden item (weight
< 50000) is assigned `overflowBase` = 50000 — the SAME weight as the
first item elevated in any prior call. Two hidden items sharing weight
50000 have ambiguous collapse priority in macOS 27's native overflow; the
OS picks between them non-deterministically instead of preserving the
intended per-item ordering.

Experimental-only (gated on `enableExperimentalOverflowPrevention`, default
`false` per `Thaw/Utilities/Defaults.swift:187`), so low blast radius —
but the fix is trivial.

## Current state

`Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift:1067-1098`:
```swift
var positions = positionStore.readPositions()
let existingKeys = Array(positions.keys)
var changed = false
var overflowBase = 50000

for (identifier, section) in sectionAssignment where section != .visible {
    guard let item = ... else { continue }
    guard let key = ... else { continue }
    let currentWeight = positions[key] ?? overflowBase
    if currentWeight < 50000 {
        positions[key] = overflowBase
        overflowBase += 10
        changed = true
    }
}
guard changed else { return }
positionStore.writePositions(positions)
```

Within a single call, `overflowBase` increments (50000 → 50010 → 50020),
so items elevated in the same call get unique weights. Across calls, it
restarts at 50000, so a newly-hidden item in a later call reuses 50000 —
colliding with any item elevated to 50000 in a prior call (which is now
skipped because `currentWeight = 50000` is not `< 50000`).

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift`

**Out of scope**:
- Do NOT change the 50000 threshold or the +10 step (they're load-bearing
  for the overflow-collapse semantics).
- Do NOT change `enableExperimentalOverflowPrevention`'s default.
- Do NOT touch `positionStore`.

## Git workflow

- Branch: `advisor/014-overflow-base-persist`
- Commit style: `fix(hider): seed overflowBase from current max weight so hidden items get unique weights`

## Steps

### Step 1: Seed `overflowBase` from the current max elevated weight

Replace the local `var overflowBase = 50000` (`:1070`) with a value
seeded from the existing positions, so each newly-elevated item gets a
weight strictly greater than any already-elevated item:

```swift
// Seed above the highest already-elevated weight so newly-hidden items
// never reuse a weight an earlier call assigned (which would give two
// items ambiguous collapse priority in native overflow).
let maxElevated = positions.values.filter { $0 >= 50000 }.max() ?? 50_000
var overflowBase = maxElevated + 10
```

This way: on the first call, no weights are ≥50000, so `maxElevated` =
50000 (the fallback), `overflowBase` = 50010 — wait, that changes the
first item's weight from 50000 to 50010. To preserve the original
first-item weight of 50000, use:

```swift
let maxElevated = positions.values.filter { $0 >= 50000 }.max()
var overflowBase: Int
if let max = maxElevated {
    overflowBase = max + 10  // above any existing elevated weight
} else {
    overflowBase = 50_000    // first elevation: start at the base
}
```

Then the loop's `positions[key] = overflowBase; overflowBase += 10`
works as before, but the FIRST newly-elevated item of THIS call gets a
weight strictly above any prior call's elevations (or 50000 if none
exist yet).

**Verify**: build → exit 0. Trace: on call 1 with no prior elevations, `overflowBase=50000`, item A → 50000, item B → 50010. On call 2 (A=50000, B=50010 still in positions), a newly-hidden item C: `maxElevated=50010`, `overflowBase=50020`, C → 50020. No collision.

### Step 2: Run tests and lint

**Verify**: `xcodebuild test ...` → exit 0; `swiftlint --strict` → exit 0; `swiftformat .` clean.

## Test plan

- No direct tests for `applyExperimentalOverflowPreventionIfEnabled`
  (plan 016 adds SimpleItemHider test seams). The verification gate is
  the existing suite.
- If plan 016 has landed, add a case: seed positions with an item at
  50000, call the function with a newly-hidden item, assert the new item
  gets a weight > 50000 (not 50000).

## Done criteria

- [ ] `overflowBase` is seeded from `positions.values.filter { $0 >= 50000 }.max()` (or 50000 if none).
- [ ] A newly-hidden item never receives a weight already held by another elevated item.
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- The 50000 threshold or the `currentWeight < 50000` guard (`:1088`) has
  changed since this plan was written (drift) — re-read and adapt the
  seeding to match.
- The experimental flag is being graduated/retired by plan 028 in a way
  that changes this function's shape — coordinate; do not conflict.

## Maintenance notes

- If the 50000 base or the +10 step changes, update the seeding
  accordingly (the `>= 50000` filter and the `+ 10` increment must stay
  consistent).
- A reviewer should confirm the first-elevation case still starts at
  50000 (not 50010) — preserving the original first-item weight.
- This is experimental-only; if `enableExperimentalOverflowPrevention`
  is graduated (plan 028), this fix carries over unchanged.
