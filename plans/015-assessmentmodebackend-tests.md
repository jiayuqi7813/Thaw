# Plan 015: Extract pure helpers from `AssessmentModeBackend.apply` and add characterization tests

> **Executor instructions**: Follow this plan step by step. This introduces
> a test seam; do NOT change the runtime behavior of `apply`.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/MenuBar/HiddenSectionPatch/AssessmentModeBackend.swift" ThawTests/MenuBarItemTagTests.swift`
> If either file changed since this plan was written, re-read the cited lines.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none (but plan 016 depends on this)
- **Category**: tests
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

`AssessmentModeBackend` is the branch's centerpiece — the private-API
assertion that genuinely removes icons. Its two highest-risk behaviors —
the "empty item cache → keep current restriction" guard
(`AssessmentModeBackend.swift:238-243`, which exists precisely because a
regression was emptying users' menu bars) and the anti-flap /
last-failed-config hysteresis (`:379-401`) — have ZERO characterization.
The only test file exercising this type (`MenuBarItemTagTests.swift:1641-1686`)
asserts the **static** helpers (`protectedBundleIDs`,
`isSystemHostBundleID`, `allowedSystemItems`, `systemItemIdentifier(for:)`).
`apply()` reaches `NSWorkspace.shared.runningApplications` (`:317`) and
`ThawAssessmentModeHidingActivate` (`:431`) directly — neither is
abstracted behind an `Environment` like `CGSWindowHider` and
`ControlCenterModuleManager` already have. So any future edit here can
regress the whole menu bar emptying or hot-loop into reflow flashes, and
nothing in CI catches it. This plan extracts the pure decision logic into
testable static functions and characterizes them.

## Current state

`Thaw/MenuBar/HiddenSectionPatch/AssessmentModeBackend.swift`:
- `:200-219` — `apply()` learns bundle IDs from `allItems`.
- `:238-243` — the empty-cache guard: `if allItems.isEmpty, !concealed.isEmpty { ... return false }`.
- `:251-260` — `bundlesWithVisibleItem` derivation.
- `:265-302` — `concealedBundleIDs` derivation (subtract visible bundles,
  protected bundles, system hosts, denylisted).
- `:316-320` — `allowedSet` from `runningApplications`.
- `:365-368` — the dedupe guard.
- `:379-401` — anti-flap + lastFailedConfiguration guards.
- `:431-452` — the activation + async-failure callback.

Existing exemplar for the `Environment` seam pattern:
`Thaw/MenuBar/HiddenSectionPatch/CGSWindowHider.swift:36-49` and
`Thaw/MenuBar/HiddenSectionPatch/ControlCenterModuleManager.swift:44-59`
both define `@MainActor struct Environment` with `static var live`.

Existing exemplar for pure-helper testing: `ThawTests/MenuBarItemTagTests.swift:1641-1686`
(asserts `AssessmentModeBackend.protectedBundleIDs` etc. as statics).

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/MenuBar/HiddenSectionPatch/AssessmentModeBackend.swift` (extract
  pure static helpers; do NOT change `apply`'s runtime behavior)
- `ThawTests/AssessmentModeBackendTests.swift` (create)

**Out of scope**:
- Do NOT add an `Environment` seam to `apply()` itself in this plan (that
  is plan 016's job for `SimpleItemHider`; `AssessmentModeBackend`'s
  instance path is characterized indirectly via the pure helpers). If you
  want, you MAY add the `Environment` struct now (matching `CGSWindowHider`)
  but do not restructure `apply()` to use it — just extract the pure logic.
- Do NOT change `pulse()` or `reset()`.

## Git workflow

- Branch: `advisor/015-assessmentmodebackend-tests`
- Commit style: `test(hider): characterize AssessmentModeBackend allowlist + reactivation guards`

## Steps

### Step 1: Extract the allowlist resolution into a pure static function

In `AssessmentModeBackend`, extract the logic at `:251-302` (deriving
`concealedBundleIDs`, `concealedSystemItemIDs`, `allowedSystemItemSet`)
into a `static func` that takes all inputs as parameters and returns the
derived sets — no `self` access:

```swift
/// Pure: resolves the concealment sets from assignment + live items +
/// the sticky known-bundle maps. Extracted from `apply` so it can be
/// unit-tested without `NSWorkspace` or the private API.
static func resolveConcealment(
    sectionAssignment: [String: MenuBarSection.Name],
    allItems: [MenuBarItem],
    knownBundleIDs: [String: String],
    knownSystemItemIDs: [String: Int]
) -> (concealedBundleIDs: Set<String>, concealedSystemItemIDs: Set<Int>, allowedSystemItemSet: Set<Int>) {
    // ... move the bodies of :223-305 here, returning the three sets ...
}
```

Have `apply()` call this static and use the returned sets. The behavior
must be identical.

Also extract the reactivation-decision into a pure static:
```swift
/// Pure: decides whether `apply` should re-activate the assertion given
/// the current and applied configs. Extracted so the dedupe / anti-flap
/// / last-failed / circuit-breaker guards can be unit-tested.
static func shouldReactivate(
    handleIsNil: Bool,
    concealedChanged: Bool,
    systemItemsChanged: Bool,
    newlyAppeared: Bool,
    appliedConfig: (allowed: Set<String>, systemItems: Set<Int>, concealed: Set<String>)?,
    previousConfig: (allowed: Set<String>, systemItems: Set<Int>, concealed: Set<String>, at: ContinuousClock.Instant)?,
    lastFailed: (allowed: Set<String>, systemItems: Set<Int>)?,
    antiFlapWindow: Duration,
    now: ContinuousClock.Instant
) -> Bool {
    // ... move the guard logic from :365-401 here ...
}
```

**Verify**: build → exit 0; `xcodebuild test ...` → existing tests still pass (behavior unchanged).

### Step 2: Create `ThawTests/AssessmentModeBackendTests.swift`

Model the file on `ThawTests/MenuBarItemTagTests.swift` (read its
`@MainActor` annotation, `import XCTest`, and `final class ...: XCTestCase`
shape). Add the new file to the `ThawTests` target (the project uses
Xcode — add the file via the `.xcodeproj` or rely on the folder-based
target membership; check how existing test files are members).

Test cases (use `MenuBarTestFixtures.swift` for fixture items if helpful —
read it first):
1. `testResolveConcealment_HidesBundleWhenNoSiblingVisible` — an item
   assigned `.hidden` with no visible sibling → its bundle is in
   `concealedBundleIDs`.
2. `testResolveConcealment_KeepsBundleWhenSiblingVisible` — same bundle
   has a `.visible` sibling → bundle NOT concealed (the
   `bundlesWithVisibleItem` guard).
3. `testResolveConcealment_NeverConcealsProtectedBundle` — an item whose
   owner is a Thaw-owned bundle (`Constants.thawOwnedBundleIdentifiers`)
   → never in `concealedBundleIDs`.
4. `testResolveConcealment_NeverConcealsDenylisted` — an item in
   `MenuBarItemTag.hidingUnsupportedBundleIDs` → not concealed.
5. `testShouldReactivate_FirstActivation` — `handleIsNil == true` →
   reactivates (even if nothing changed).
6. `testShouldReactivate_NoChangeSteadyState` — handle non-nil, no
   change, no new app → does NOT reactivate.
7. `testShouldReactivate_SuppressesFlapWithinWindow` — previous config
   equals desired, within anti-flap window → does NOT reactivate.
8. `testShouldReactivate_RetriesAfterGenuineChange` — lastFailed set,
   but desired set changed → reactivates (clears lastFailed).
9. `testShouldReactivate_SuppressesIdenticalFailedConfig` — lastFailed
   equals desired → does NOT reactivate (hot-loop guard).

**Verify**: `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` → exit 0, 9 new tests pass.

### Step 3: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` → no leftover diffs. (The new test file needs the copyright header — SwiftFormat/SwiftLint enforce it; `swiftformat .` will add it, or add it manually matching `.swiftformat:18`.)

## Test plan

- 9 new tests in `ThawTests/AssessmentModeBackendTests.swift` (listed in Step 2).
- Model after `ThawTests/MenuBarItemTagTests.swift` structure.
- Use `ThawTests/MenuBarTestFixtures.swift` for fixture items (read it to see what's available).
- Verification: `xcodebuild test ...` → all pass including the 9 new tests.

## Done criteria

- [ ] `AssessmentModeBackend.resolveConcealment` and `shouldReactivate` static pure functions exist; `apply()` calls them.
- [ ] `apply()`'s runtime behavior is unchanged (existing tests pass).
- [ ] `ThawTests/AssessmentModeBackendTests.swift` exists with the 9 cases, all passing.
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean (incl. copyright header on the new file).
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- `apply()`'s logic at `:223-305` / `:365-401` has dependencies on `self`
  state that can't be parameterized cleanly (e.g. it mutates
  `knownBundleIDs` mid-derivation) — if the extraction can't be done
  without changing behavior, STOP and report; do not risk a regression
  on the hiding primitive.
- The new test file can't be added to the `ThawTests` target without
  editing the `.pbxproj` in a way you're not confident about — ask how
  existing test files are members (the project may use folder
  references).
- `MenuBarTestFixtures.swift` doesn't provide the fixtures you need —
  extend it minimally, or construct items inline; do not block on it.

## Maintenance notes

- The pure helpers are the contract future refactors (plan 022 ItemHider
  protocol, plan 024 god-object split) must preserve. Update the tests
  when the contract changes.
- A reviewer should confirm `apply()` still calls the real
  `ThawAssessmentModeHidingActivate` and `NSWorkspace.shared` — only the
  DECISION logic was extracted, not the side effects.
- If `apply()` gains a new guard (e.g. plan 013's circuit breaker), add
  it to `shouldReactivate` and add a paired test.
