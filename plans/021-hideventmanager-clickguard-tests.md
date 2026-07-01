# Plan 021: Add tests for the `HIDEventManager` click-guard state machine

> **Executor instructions**: Follow this plan step by step.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/Events/HIDEventManager.swift" ThawTests/HIDEventManagerBoundsLookupTests.swift`
> If either file changed since this plan was written, re-read the cited lines.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

The show-on-click path turns a real click into a section reveal. The
`GuardMouseUpState` swallow-then-disarm state machine
(`HIDEventManager.swift:82-93`, `:139-160` `isEnabled` toggle) was added
to prevent the click that revealed the hidden section from also
activating the underlying app. A regression here either swallows
legitimate clicks (the OS feels frozen) or lets the reveal-click leak
through ("clicking the Thaw icon opens the Control Center item
underneath"). `HIDEventManagerBoundsLookupTests.swift` scopes itself
exclusively to `menuBarBoundsLookupContains` (`:14`) and
`shouldIncludeItemInMenuBarBoundsLookup` (`:57`/`:73`/`:89`) — the pure
static helpers. Nothing drives the click-guard transitions or the
show-on-click decision at the instance level.

## Current state

`Thaw/Events/HIDEventManager.swift`:
- `:82-93` — `GuardMouseUpState` state machine.
- `:139-160` — `isEnabled` toggle + section-toggle-survival.
- `:850-939` — `handleShowOnClick(appState:screen:clickLocation:modifierFlags:isDoubleClick:)`
  (single-click reveal + double-click-region swallow logic).
- `:1457` — `handleShowOnHover`.

`ThawTests/HIDEventManagerBoundsLookupTests.swift`:
- `:14` — scopes to `menuBarBoundsLookupContains`.
- `:57`/`:73`/`:89` — `shouldIncludeItemInMenuBarBoundsLookup`.
- `:176-215` — reconstructs the filter manually rather than calling the
  instance rebuild (so the toggle-survival invariant isn't really tested).

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/Events/HIDEventManager.swift` (extract `GuardMouseUpState`
  transitions and the show-on-click "did the click land in the guard
  region / within the double-click window" decision into pure statics)
- `ThawTests/HIDEventManagerClickGuardTests.swift` (create)

**Out of scope**:
- Do NOT test the live CGEventTap (hardware input); test the extracted
  pure decision functions.
- Do NOT change `handleShowOnHover` (separate concern).

## Git workflow

- Branch: `advisor/021-hideventmanager-clickguard-tests`
- Commit style: `test(events): characterize HIDEventManager click-guard transitions and show-on-click decision`

## Steps

### Step 1: Extract `GuardMouseUpState` transitions into a pure static

In `HIDEventManager`, extract the state-machine transition logic into:
```swift
static func nextGuardState(from current: GuardMouseUpState, given event: ...) -> GuardMouseUpState {
    // the swallow-then-disarm transitions
}
```
Have the instance call it. Behavior unchanged.

### Step 2: Extract the show-on-click guard-region decision into a pure static

Extract the "did the click land inside the guard region / within the
double-click window" decision from `handleShowOnClick` (`:850-939`) into:
```swift
static func shouldSwallowClick(
    clickLocation: CGPoint,
    guardRegion: CGRect,
    isDoubleClick: Bool,
    withinDoubleClickWindow: Bool
) -> Bool {
    // the decision logic
}
```

**Verify**: build → exit 0; existing tests pass.

### Step 3: Create `ThawTests/HIDEventManagerClickGuardTests.swift`

Test cases:
1. `testNextGuardState_ArmOnRevealClick` — a reveal click arms the
   swallow for the next mouse-up.
2. `testNextGuardState_DisarmAfterSwallow` — after swallowing one
   mouse-up, the guard disarms (doesn't swallow the next legitimate click).
3. `testNextGuardState_ToggleSurvivesRebuild` — the section-toggle-
   survival invariant (re-enabling doesn't drop the guard mid-swallow).
4. `testShouldSwallowClick_InsideGuardRegion` — click in region → swallow.
5. `testShouldSwallowClick_OutsideGuardRegion` — click outside → don't swallow.
6. `testShouldSwallowClick_DoubleClickWindow` — second click within the
   double-click window → swallow (the region-swallow logic).

**Verify**: `xcodebuild test ...` → exit 0, 6 new tests pass.

### Step 4: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` → no leftover diffs.

## Test plan

- 6 new tests in `ThawTests/HIDEventManagerClickGuardTests.swift` (listed in Step 3).
- Verification: `xcodebuild test ...` → all pass including the 6 new tests.

## Done criteria

- [ ] `nextGuardState` and `shouldSwallowClick` pure statics exist; the instance calls them.
- [ ] `ThawTests/HIDEventManagerClickGuardTests.swift` exists with the 6 cases, all passing.
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- `GuardMouseUpState`'s transitions depend on instance state (timers,
  real mouse-up events) that can't be parameterized — then extract what
  you can and report the rest as untestable; do not force a pure
  extraction that misrepresents the logic.
- `handleShowOnClick`'s decision is intertwined with `AppState` in a way
  the pure static can't capture — extract only the guard-region /
  double-click-window predicate; leave the rest.

## Maintenance notes

- The extracted statics are the contract future click-guard changes must
  preserve; update the tests when the contract changes.
- A reviewer should confirm the live event-tap path still calls the
  extracted statics (no behavior change).
