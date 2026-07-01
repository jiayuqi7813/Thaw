# Plan 018: Add tests for `SyntheticMoveEngine` retry/dropX/anchoring

> **Executor instructions**: Follow this plan step by step.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/MenuBar/MenuBarItems/SyntheticMoveEngine.swift"`
> If the file changed since this plan was written, re-read the cited lines.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

`SyntheticMoveEngine` is the synthetic Command-drag — the PHYSICAL
reordering mechanism on macOS 27. If the verify-retry settle delay, the
dropX inset sign, or the anchored-target refusal is wrong, the menu bar
slides off in the wrong direction and the engine hot-loops into a
max-attempts failure path while the user observes "random item shuffle" —
the symptom the field reports cite. Grep for `SyntheticMoveEngine` in
`ThawTests/` returns nothing; zero tests. The struct already accepts its
seams (`makeEventSource`, `enumerateItems` at `SyntheticMoveEngine.swift:29-45`)
— yet nothing drives them. The verification path uses
`LayoutPlanner.liveOrderSatisfiesDestination` which IS well tested
(`MenuBarItemTagTests.swift:1779-2085`), so the verify side can be
stubbed with fixture items.

## Current state

`Thaw/MenuBar/MenuBarItems/SyntheticMoveEngine.swift`:
- `:29` — `move(item:to:maxAttempts:experimentalSystemItemHiding:)`.
- `:35-45` — anchored-target refusal.
- `:77-91` — dropX computation + on-screen-frame guard.
- `:104-111` — verify via `LayoutPlanner.liveOrderSatisfiesDestination` and retry on mismatch.
- `:120-128` — `currentBounds` matching (exact → matchesIgnoringWindowID → tag-only).
- `:130-171` — `postCommandDrag` synthetic-input path (the only genuinely-untestable-without-a-real-CGEvent-tap part).

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/MenuBar/MenuBarItems/SyntheticMoveEngine.swift` (only if a
  signature needs widening to inject `postCommandDrag` — see Step 2)
- `ThawTests/SyntheticMoveEngineTests.swift` (create)

**Out of scope**:
- Do NOT test `postCommandDrag` itself (it posts real CGEvents; untestable
  without a hardware event tap). Inject it as a seam and assert it's
  CALLED with the right dropX, not that it moved a window.
- Do NOT change `LayoutPlanner` (it's well tested; used as-is).

## Git workflow

- Branch: `advisor/018-syntheticmoveengine-tests`
- Commit style: `test(move): characterize SyntheticMoveEngine retry, dropX, and anchoring refusal`

## Steps

### Step 1: Read the file and confirm the seam shapes

Read `SyntheticMoveEngine.swift` fully. Confirm `move` accepts
`makeEventSource` and `enumerateItems` closures (or equivalent). If
`postCommandDrag` is a private method (not injectable), Step 2 widens the
seam.

### Step 2: Widen the seam if needed

If `postCommandDrag` is not injectable, add a closure parameter to `move`
(or a struct property) defaulting to the real implementation:
```swift
private let postCommandDrag: @MainActor (CGWindowID, CGPoint) -> Void = { ... real ... }
```
Make it injectable for tests (a no-op or recording fake). Do NOT change
the real `postCommandDrag` body.

**Verify**: build → exit 0.

### Step 3: Create `ThawTests/SyntheticMoveEngineTests.swift`

Model on `ThawTests/PlanLeftmostMoveTests.swift` / `PlanLCSMoveSequenceTests.swift`
(read them — they build fixture item layouts and assert move sequences).

Test cases (drive `move` with a fake `enumerateItems` returning pre- and
post-drag layouts, and a recording `postCommandDrag` fake):
1. `testMove_RefusesAnchoredTarget` — destination is a fixed anchor →
   returns failure without calling `postCommandDrag`.
2. `testMove_ReturnsSuccessWhenAlreadySatisfied` — `enumerateItems`
   already satisfies `liveOrderSatisfiesDestination` → returns success
   without dragging.
3. `testMove_ComputesDropXFromTargetBounds` — assert the `postCommandDrag`
   fake received a dropX derived from the target bounds per the
   `LayoutDestination` case (read the dropX math at `:77-91` to know the
   expected sign/value).
4. `testMove_ThrowsItemNotMovableWhenStartOffScreen` — item start frame
   off-screen → returns `itemNotMovable` (or the documented failure).
5. `testMove_RetriesUntilMaxAttempts` — `enumerateItems` never satisfies
   → asserts the engine retried up to `maxAttempts` then gave up (count
   `postCommandDrag` calls).
6. `testMove_CurrentBoundsExactMatch` — verify the bounds-matching tier
   (exact → matchesIgnoringWindowID → tag-only) prefers the exact match.

**Verify**: `xcodebuild test ...` → exit 0, 6 new tests pass.

### Step 4: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` → no leftover diffs.

## Test plan

- 6 new tests in `ThawTests/SyntheticMoveEngineTests.swift` (listed in Step 3).
- Model after `PlanLeftmostMoveTests.swift` / `PlanLCSMoveSequenceTests.swift`.
- Verification: `xcodebuild test ...` → all pass including the 6 new tests.

## Done criteria

- [ ] `postCommandDrag` is injectable (if it wasn't).
- [ ] `ThawTests/SyntheticMoveEngineTests.swift` exists with the 6 cases, all passing.
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- `SyntheticMoveEngine.move`'s signature doesn't accept the seams the
  subagent claimed — read the file first; if the seams aren't there, the
  injection work is larger; report and adapt.
- The dropX math at `:77-91` is more complex than expected (e.g.
  layout-destination-case-specific) — assert the EXPECTED value per case
  by reading the math; don't guess.
- Fixture `MenuBarItem`s with specific `bounds` can't be constructed —
  extend `MenuBarTestFixtures.swift` minimally.

## Maintenance notes

- The `postCommandDrag` injection seam is also where a future real-CGEvent-tap
  integration test would plug in — keep it clean.
- A reviewer should confirm the real `postCommandDrag` body is unchanged
  (only its call-site is injectable).
