# Plan 006: Add test coverage for the recovery-driver healthy-guard wiring in `MenuBarSectionController`

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md` — unless a reviewer dispatched you and told you
> they maintain the index.
>
> **Drift check (run first)**: `git diff --stat b41f1e96..HEAD -- Thaw/MenuBar/HiddenSectionPatch/MenuBarSectionController.swift ThawTests/MenuBarSectionControllerTests.swift`
> If either file changed since this plan was written, compare the "Current
> state" excerpts below against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW (test-only change, no production code touched)
- **Depends on**: none (independent of 004/005, though reading plan 005 first
  gives useful context on the same subsystem)
- **Category**: test coverage
- **Planned at**: commit `b41f1e96`, 2026-07-11

## Why this matters

`MenuBarSectionController` had a real, previously-shipped crash bug: a
feedback loop where reacting to `MenuBarAgent`'s own housekeeping (an
external `TrailingItemPreferredPositions` reorder that's actually benign)
triggered unnecessary recovery, which caused more churn, which triggered more
reaction. The fix that shipped in this branch is
`areConcealmentAuthoritiesHealthy` — a guard that checks whether hidden
items are still actually off-screen / the assertion is still actually held
before allowing `handleExternalPositionsChange` to call
`recoveryDriver?.recover(...)`. This guard is the single thing standing
between "harmless MenuBarAgent housekeeping" and "recovery storm." The new
tests added alongside this code (`MenuBarSectionControllerTests.swift`, +193
lines) cover `makeRecoverySnapshot` and the position-hiding assertion-input
stripping, but nothing in the new test code exercises
`handleExternalPositionsChange` itself, its `areConcealmentAuthoritiesHealthy`
guard, or `handleAssessmentStateChange`. A future refactor could silently
invert or loosen that guard and no test would catch it — which is exactly
the failure mode that caused the original bug.

## Current state

`Thaw/MenuBar/HiddenSectionPatch/MenuBarSectionController.swift`:

```swift
356:    private func handleExternalPositionsChange(_ positions: [String: Int]) {
357:        // MenuBarAgent renormalizes the entire `TrailingItemPreferredPositions`
358:        // dictionary during its own reflows, so the watcher fires on churn in
359:        // keys Thaw does not manage (148-key rewrites). If every concealment
360:        // authority is still healthy — hidden items still off-screen, assertion
361:        // still held — there is nothing to recover, and reacting would rewrite
362:        // the store, which MenuBarAgent normalizes again, sustaining the
363:        // "reordering that never stops" loop. Only recover on a genuine breach.
364:        guard !areConcealmentAuthoritiesHealthy else {
365:            diagLog.debug("external order change is benign (concealment healthy); skipping recovery")
366:            return
367:        }
368:        diagLog.notice("external MenuBarAgent order change (\(positions.count) key(s)); scheduling settled recovery")
369:        recoveryDriver?.recover(trigger: .externalPositions)
370:    }
371:
372:    private func handleAssessmentStateChange() {
373:        refreshHidingAvailability()
374:        recoveryDriver?.recover(trigger: .assessmentState)
375:    }
```

Both `handleExternalPositionsChange` and `handleAssessmentStateChange` are
`private`, so they can't be called directly from a test target unless the
test is `@testable import Thaw` (already the pattern used by
`ThawTests/MenuBarSectionControllerTests.swift` — check its import block
first) — private members remain visible to `@testable` test targets within
the same module, so this should work without any visibility changes to
production code.

`areConcealmentAuthoritiesHealthy` (also in this file, ~line 427):

```swift
427:    private var areConcealmentAuthoritiesHealthy: Bool {
428:        let assertionHealthy = !hasDesiredAssertionRestriction || backend.isHolding
429:        let positionHealthy = !positionHideBackend.hasManagedItems || positionHideBackend.isInDesiredState
```
(read the rest of this computed property — it continues past line 429 —
before writing tests, so you assert against its actual full logic, not a
guess)

`recoveryDriver` is a `MenuBarRecoveryDriver?` (line 244), configured in
`configureRecoveryDriver()` (~line 380-415) with an `environment:` closure
bundle including `isAssertionAlive`, `repulseAssertion`, `relockPositions`,
`doubleToggle`, `markTornDown`. Read `MenuBarRecoveryDriver.swift` in full
(it's short — 39 lines) to understand what `recover(trigger:)` actually does
with these closures before designing the test doubles below.

Existing test file conventions — read
`ThawTests/MenuBarSectionControllerTests.swift` in full before starting;
note how it currently constructs a `MenuBarSectionController` under test
(what mock `AppState`, mock backend, etc. it already has set up — reuse that
scaffolding rather than building new fixtures from scratch).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build + test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, all tests pass |
| Lint | `swiftlint --strict` | exit 0 |
| List existing test helpers | `grep -n "class Mock\|struct Mock\|final class Fake" ThawTests/MenuBarSectionControllerTests.swift` | shows existing mock backend(s) to reuse |

## Scope

**In scope**:
- `ThawTests/MenuBarSectionControllerTests.swift` — add new test methods.
- If a test double for the concealment backend / position-hide backend
  doesn't already expose enough control to force `areConcealmentAuthoritiesHealthy`
  to `true` or `false` on demand, you may add minimal, narrowly-scoped
  test-only seams (e.g. a settable property on an existing mock/fake type
  already used by this test file) — but only inside test-target code or
  types that are already clearly test doubles (check for a
  `ThawTests/Mocks/` or similar directory, or fakes defined inline in the
  test file itself). Do not add test-only hooks into production types in
  `Thaw/MenuBar/HiddenSectionPatch/MenuBarSectionController.swift` itself.

**Out of scope**:
- `MenuBarSectionController.swift` production code — no behavior changes,
  this is a test-only plan.
- `MenuBarRecoveryDriver.swift` — read it for context, don't modify it.
- Plans 004 and 005 — independent, don't merge work.

## Git workflow

- Branch: `advisor/006-recovery-driver-tests`
- One commit (or a small number of logically separate commits, one per test
  scenario, if that matches how this file's git history already splits test
  additions — check `git log --oneline -- ThawTests/MenuBarSectionControllerTests.swift`)
- Do NOT push or open a PR.

## Steps

### Step 1: Read the full recovery-driver wiring

Read, in order: `MenuBarRecoveryDriver.swift` (full file, 39 lines),
`MenuBarSectionController.swift` lines 240-430 (state properties through
`areConcealmentAuthoritiesHealthy`'s full body), and the existing
`ThawTests/MenuBarSectionControllerTests.swift` in full. Confirm you
understand: what makes `areConcealmentAuthoritiesHealthy` return `false`
(a "breach" the guard should let through), and what the existing test
fixture already gives you control over (mock backend `isHolding`,
`positionHideBackend.hasManagedItems`/`isInDesiredState`, etc.).

**Verify**: no command — this is a reading step. Move on once you can state,
in your own words, one concrete scenario that makes
`areConcealmentAuthoritiesHealthy` false and one that makes it true, using
only the existing test fixture's mocks.

### Step 2: Test — benign external reorder is skipped

Add a test that: sets up the controller such that
`areConcealmentAuthoritiesHealthy` is `true` (assertion held, positions in
desired state), calls `handleExternalPositionsChange(_:)` with some sample
positions dictionary, and asserts `recoveryDriver?.recover(trigger:)` was
**not** invoked (use a test double for `recoveryDriver`'s environment, or a
spy inserted via the existing mock backend if `recover` ends up calling back
into observable backend methods — follow whatever seam the existing test
fixture already provides; if none exists, that itself is useful information,
report it in NOTES rather than inventing a large new test harness).

**Verify**: `xcodebuild test ...` → new test passes.

### Step 3: Test — genuine breach triggers recovery

Add a test with the mirror-image setup: `areConcealmentAuthoritiesHealthy`
is `false` (e.g. assertion no longer held while concealment is still
desired), call `handleExternalPositionsChange(_:)`, and assert recovery
**was** triggered.

**Verify**: `xcodebuild test ...` → new test passes.

### Step 4: Test — assessment-state change always re-checks and recovers

Add a test for `handleAssessmentStateChange()`: assert it always calls
`refreshHidingAvailability()` and always calls
`recoveryDriver?.recover(trigger: .assessmentState)`, regardless of the
healthy-guard (per the current code, this path has no healthy-guard —
confirm that's still true when you read it in Step 1, and if it's not,
adjust this test to match the actual guarded behavior rather than what this
plan assumed).

**Verify**: `xcodebuild test ...` → new test passes.

## Test plan

- Three new test methods (per Steps 2-4 above) in
  `ThawTests/MenuBarSectionControllerTests.swift`, named following the
  existing convention in that file (e.g.
  `testHandleExternalPositionsChange_SkipsRecoveryWhenConcealmentHealthy`,
  `testHandleExternalPositionsChange_TriggersRecoveryWhenConcealmentUnhealthy`,
  `testHandleAssessmentStateChange_AlwaysRefreshesAndRecovers`).
- Model structure after the existing tests in the same file, e.g.
  `testRefresh_NoOpsWithoutAttachedAppState` / `testShow_RevealsOnlyRequestedSection`
  for how they construct a controller + mock `AppState`.
- Verification: `xcodebuild test ...` → all pass, including the 3 new ones.

## Done criteria

- [ ] `xcodebuild test ...` exits 0
- [ ] `swiftlint --strict` exits 0
- [ ] 3 new tests exist, named per above, and pass
- [ ] Each new test fails if you temporarily invert its corresponding guard
      in production code (verify locally before committing, then revert the
      temporary inversion — don't leave production code changed)
- [ ] No files outside `ThawTests/MenuBarSectionControllerTests.swift` (and,
      if narrowly needed, an existing test-double file) are modified
- [ ] `advisor-plans/README.md` status row for 006 updated

## STOP conditions

Stop and report back (do not improvise) if:

- The existing test fixture in `MenuBarSectionControllerTests.swift` has no
  way to control `backend.isHolding` / `positionHideBackend.hasManagedItems`
  / `isInDesiredState` (i.e., the mocks aren't settable, or there's no mock
  at all and the controller talks to real system APIs) — report what
  fixture-level work would be needed instead of building a large new mock
  infrastructure yourself.
- `handleExternalPositionsChange` or `areConcealmentAuthoritiesHealthy` have
  materially different logic than the excerpt above (drift).
- Any of the 3 planned tests can't be written without modifying production
  code's access level (e.g. making something `internal`/`@testable`-visible
  that isn't already) beyond what `@testable import Thaw` already grants —
  stop and report which member needs wider visibility and why.

## Maintenance notes

- These tests are a regression guard specifically for the crash-loop bug
  class this project has already fixed once. A reviewer touching
  `areConcealmentAuthoritiesHealthy`, `handleExternalPositionsChange`, or
  `MenuBarRecoveryDriver` should re-run these tests and read them, not just
  trust green CI — confirm the assertions still test the *intended* guard
  behavior, since it would be easy for a future refactor to keep these tests
  green while accidentally testing something else if the mock wiring shifts.
- Plan 005 (arming self-change suppression before mutation) touches the same
  file; if both plans are executed, whoever merges should confirm the two
  diffs don't conflict on overlapping line ranges.
