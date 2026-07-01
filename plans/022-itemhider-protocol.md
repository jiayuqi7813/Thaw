# Plan 022: Unify the macOS 27 hider backends behind an `ItemHider` protocol

> **Executor instructions**: This is a **refactor** gated by tests. Do NOT
> start until plans 015 and 016 have landed (the test seams are the
> safety net). Read "STOP conditions" carefully — pass ordering is
> load-bearing.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/MenuBar/HiddenSectionPatch"`
> If any in-scope file changed since this plan was written, re-read the
> "Current state" section before proceeding.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MED
- **Depends on**: plan 015 (AssessmentModeBackend tests), plan 016 (SimpleItemHider injection)
- **Category**: tech-debt
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

`SimpleItemHider` holds four concrete backend properties
(`AssessmentModeBackend`, `ControlCenterModuleManager`, `CGSWindowHider`,
`AXItemHider`) with no shared interface
(`SimpleItemHider.swift:82-103`). Their `apply` signatures diverge
(`AssessmentModeBackend.swift:200` `sectionAssignment:allItems:` vs
`CGSWindowHider.swift:89` `hiddenPIDs:` vs `AXItemHider.swift:52`
`hiddenPIDs:allItems:`). `applyExperimentalWindowHiding`
(`SimpleItemHider.swift:1157-1260`) hand-orchestrates four ordered passes
(plist → CGS → AX → position-lock) with `stripSurgicallyHandledPIDs`
plumbing the handled-PID set back into `backendAssignment` between each
pass — the lockstep seam every backend change touches. Adding or
modifying any backend requires touching four divergent sites, and
there's no compile-time contract that they share the lifecycle the
orchestrator expects. A protocol makes a future backend (e.g. a
`MenuBarAgent` XPC path) a drop-in adapter instead of a fifth
hand-wired pass.

**Caveat**: pass ordering (plist → CGS → AX → position-lock) is
load-bearing for the iStat-ghosting fix (documented at
`SimpleItemHider.swift:90-94`). The protocol must NOT flatten that
ordering silently — it must make it explicit and preserved.

## Current state

The four backends and their `apply`/`restoreAll` shapes:
- `AssessmentModeBackend.swift:200`/`:483`/`:499` — `apply(sectionAssignment:allItems:)`/`pulse`/`reset`; `@MainActor final class`.
- `CGSWindowHider.swift:89`/`:140` — `apply(hiddenPIDs:)`/`restoreAll`; has `Environment` seam.
- `AXItemHider.swift:52`/`:94` — `apply(hiddenPIDs:allItems:)`/`restoreAll`; no seam (now gated out on macOS 27 by plan 012).
- `TrailingItemPositionStore.swift:51`/`:144`/`:197`/`:124` — `lockVisiblePositions`/`hideItems`/`showItems`/`restoreAll` (plist-based; not a `hiddenPIDs` shape).
- `ControlCenterModuleManager.swift:170`/`:206` — `apply(hiddenMenuExtraTitles:)`/`restoreAll`; has `Environment` seam.

`SimpleItemHider.applyExperimentalWindowHiding` (`:1157-1260`) — the
hand-orchestrated pipeline; `stripSurgicallyHandledPIDs` prunes handled
PIDs from `backendAssignment` between passes.

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift`
- `Thaw/MenuBar/HiddenSectionPatch/AssessmentModeBackend.swift` (conform)
- `Thaw/MenuBar/HiddenSectionPatch/CGSWindowHider.swift` (conform)
- `Thaw/MenuBar/HiddenSectionPatch/AXItemHider.swift` (conform)
- `Thaw/MenuBar/HiddenSectionPatch/TrailingItemPositionStore.swift` (conform — the plist-based mechanism needs its own protocol or a `PlistHider` sub-protocol)
- `Thaw/MenuBar/HiddenSectionPatch/ControlCenterModuleManager.swift` (conform — the CC-module mechanism is title-keyed, not PID-keyed; may need a separate protocol)

**Out of scope**:
- Do NOT split `SimpleItemHider` into multiple classes (plan 023).
- Do NOT change the actual hiding behavior of any backend.
- Do NOT graduate/retire experimental flags (plan 028).

## Git workflow

- Branch: `advisor/022-itemhider-protocol`
- Commit style: `refactor(hider): unify backends behind ItemHider protocols`

## Steps

### Step 1: Define the protocol(s) by mechanism, not by force-fitting

The four backends have TWO mechanism shapes:
- **PID/window-based** (`CGSWindowHider`, `AXItemHider`): `apply(hiddenPIDs:...) -> Set<pid_t>` (handled PIDs), `restoreAll()`.
- **Non-PID** (`AssessmentModeBackend` is assignment-based; `ControlCenterModuleManager` is title-based; `TrailingItemPositionStore` is plist-key-based).

Do NOT force all four into one `apply(hiddenPIDs:)` signature — that
misrepresents `AssessmentModeBackend` (assignment-based) and
`ControlCenterModuleManager` (title-based). Instead define:

```swift
/// A backend that hides a subset of menu bar items and reports which it
/// handled, so the orchestrator can strip them from the next pass.
@MainActor
protocol SurgicalItemHider: AnyObject {
    /// Hides per-PID; returns the PIDs actually handled (so the caller
    /// can strip them from the assertion input).
    func apply(hiddenPIDs: Set<pid_t>, allItems: [MenuBarItem]) -> Set<pid_t>
    func restoreAll()
}
```
Conform `CGSWindowHider` and `AXItemHider` to `SurgicalItemHider`.
`AssessmentModeBackend`, `ControlCenterModuleManager`, and
`TrailingItemPositionStore` keep their own shapes (they're not
surgical-PID backends) — they're orchestrated separately in
`applyExperimentalWindowHiding`.

**Alternative (only if the maintainer prefers one protocol)**: define a
`protocol ItemHider { func apply(_ plan: HidePlan, allItems: [MenuBarItem]) -> HideResult }`
where `HidePlan` carries per-item section + temporary-reveal state and
each backend interprets the parts it can handle, returning a
`HideResult` with handled identifiers. This is more uniform but a
bigger change. Default: the per-mechanism protocols (Step 1 as written).

**Verify**: build → exit 0; conformances are additive.

### Step 2: Route the surgical passes through an ordered `[SurgicalItemHider]`

In `SimpleItemHider`, replace the named `cgsWindowHider`/`axItemHider`
properties (for the surgical passes) with:
```swift
private let surgicalHiders: [SurgicalItemHider]  // ordered: CGS, then AX
```
Order matters: CGS first (handles pre-27 / windows that exist), AX
second (the `#unavailable(macOS 27)`-gated pass from plan 012).
`applyExperimentalWindowHiding` iterates `surgicalHiders`, calling
`apply(hiddenPIDs:remainingPIDs, allItems:)` and `remainingPIDs.subtract(handled)`
between each — the existing `stripSurgicallyHandledPIDs` behavior, now
built into the pipeline.

Keep `AssessmentModeBackend`, `ControlCenterModuleManager`, and
`TrailingItemPositionStore` as named properties (their shapes don't fit
the surgical protocol); they're orchestrated before/after the surgical
passes exactly as today.

**Verify**: `xcodebuild test ...` → exit 0 (the SimpleItemHider tests from plan 016 must still pass — they're the safety net).

### Step 3: Add a test asserting pass ordering is preserved

In `ThawTests/SimpleItemHiderTests.swift` (from plan 016), add:
```swift
func testSurgicalHidersRunInOrder_CGSThenAX() {
    // inject fakes that record their call order; assert CGS.apply is
    // called before AX.apply, and AX only receives PIDs CGS didn't handle.
}
```

**Verify**: `xcodebuild test ...` → exit 0, new test passes.

### Step 4: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` → no leftover diffs.

## Test plan

- New test `testSurgicalHidersRunInOrder_CGSThenAX` in `SimpleItemHiderTests.swift`.
- All plan 016's SimpleItemHider tests must still pass (the safety net).
- Verification: `xcodebuild test ...` → all pass.

## Done criteria

- [ ] `SurgicalItemHider` protocol exists; `CGSWindowHider` and `AXItemHider` conform.
- [ ] `SimpleItemHider` orchestrates surgical passes via an ordered `[SurgicalItemHider]`.
- [ ] Pass ordering (CGS → AX) is preserved and tested.
- [ ] All plan 015/016 tests still pass.
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- Routing through `[SurgicalItemHider]` breaks the `stripSurgicallyHandledPIDs`
  contract (the handled-PID set isn't plumbed correctly between passes) —
  the plan 016 tests must catch this; if they don't, STOP and add more
  characterization tests before proceeding.
- `AssessmentModeBackend`'s assignment-based shape can't stay separate
  (it shares too much orchestration with the surgical passes) — report
  and consider the uniform `HidePlan` alternative; do not force-fit.
- The `AXItemHider` `#unavailable(macOS 27)` gate (plan 012) makes the
  surgical list's second element a no-op on 27 — that's fine (the
  protocol handles it), but confirm the empty-handled-set doesn't break
  the strip logic.

## Maintenance notes

- The protocol is the seam a future `MenuBarAgent` XPC backend plugs
  into — keep `SurgicalItemHider` minimal (apply/restoreAll).
- A reviewer should manually verify (on macOS 27, experimental flag on)
  that the iStat-ghosting fix still works — pass ordering is the
  load-bearing invariant; a misorder regresses it silently.
- Coordinate with plan 024 (god-object split): the surgical list may
  move into a dedicated `HidingOrchestrator` as part of that split.
