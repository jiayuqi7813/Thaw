# Plan 013: Add a backoff/circuit-breaker to the post-assertion verify tear-down

> **Executor instructions**: Follow this plan step by step. This is a
> safety-net path; read "STOP conditions" carefully — do NOT suppress the
> genuine safety net.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift" "Thaw/MenuBar/HiddenSectionPatch/AssessmentModeBackend.swift"`
> If either file changed since this plan was written, re-read the cited lines.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

When `AssessmentModeBackend`'s assertion fires, `SimpleItemHider` spawns a
200ms-delayed `verifyHidingUnsupportedItemsVisiblePostAssertion` Task
(`SimpleItemHider.swift:1000-1003`). That verify re-enumerates AX and, if
any denylisted hiding-unsupported item is invisible/absent, calls
`resetBackendRestriction()` (`:1046`) → `backend.apply(sectionAssignment: [:], allItems: [])`
(`:1050-1052`) → `AssessmentModeBackend.reset()` (`:499-508`). `reset()`
clears `handle` (so the next 1s tick's `apply` re-activates, bypassing the
anti-flap guard at `:379` because `handle == nil`, and the
`lastFailedConfiguration` guard at `:396` because the tear-down was a
`reset()`, not an async failure). So if a denylisted bundle is
collateral-hidden by the assertion (the exact scenario the safety net
exists for), the bar would flap: reveal-all → 200ms → re-conceal → 1s →
reveal-all → … indefinitely, with no backoff, circuit breaker, or
`lastFailedConfiguration` marker to suppress it.

**Currently inert**: `MenuBarItemTag.hidingUnsupportedBundleIDs` is empty
(`MenuBarItemTag.swift:101-105`, the iStat entry is commented out), so
`verifyHidingUnsupportedItemsVisiblePostAssertion` early-returns at
`:1014`. The flap cannot trigger today. But if any bundle is re-added to
the denylist (the safety net's reason to exist), the flap activates.

## Current state

`Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift`:
- `:996-1003` — on `didChangeRestriction`, spawn 200ms-delayed verify Task.
- `:1011-1048` — `verifyHidingUnsupportedItemsVisiblePostAssertion`:
  re-enumerate AX (`:1017`), filter unsupported (`:1019-1021`), find
  invisible/absent (`:1023-1036`), call `resetBackendRestriction()` (`:1046`).
- `:1050-1052` — `resetBackendRestriction()` → `backend.apply(sectionAssignment: [:], allItems: [])`.

`Thaw/MenuBar/HiddenSectionPatch/AssessmentModeBackend.swift`:
- `:379-401` — anti-flap + lastFailedConfiguration guards (only suppress
  re-activation when `handle != nil`; `reset()` clears `handle`, so these
  don't suppress the post-reset re-activation).
- `:499-508` — `reset()` clears `handle`, `appliedConcealed`,
  `appliedAllowed`, `appliedAllowedSystemItems`; does NOT set
  `lastFailedConfiguration`.

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift`
- `Thaw/MenuBar/HiddenSectionPatch/AssessmentModeBackend.swift` (only to
  expose a way to record the torn-down config so the next tick suppresses
  re-activation)

**Out of scope**:
- Do NOT remove or weaken the verify safety net — it exists to prevent
  the assertion from stranding denylisted items invisible. The fix adds a
  backoff, not a removal.
- Do NOT change `MenuBarItemTag.hidingUnsupportedBundleIDs` (the denylist
  is empty by design; re-adding entries is a separate decision).

## Git workflow

- Branch: `advisor/013-verify-flap-backoff`
- Commit style: `fix(hider): back off after a post-assertion verify tear-down to prevent flapping`

## Steps

### Step 1: Record the torn-down configuration so the next tick suppresses re-activation

In `SimpleItemHider.resetBackendRestriction()` (`:1050-1052`), before
calling `backend.apply(sectionAssignment: [:], allItems: [])`, record the
config that's being torn down so `AssessmentModeBackend` can suppress
re-activation of the identical config on the next tick — mirroring the
existing async-failure hot-loop guard at `AssessmentModeBackend.swift:392-401`.

Option A (preferred): add a method to `AssessmentModeBackend`:
```swift
/// Records that the current restriction was torn down by an external
/// safety net (e.g. verifyHidingUnsupportedItemsVisiblePostAssertion) and
/// must not be re-activated with the same config on the next tick —
/// mirrors the async-failure lastFailedConfiguration guard.
func markExternallyTornDown() {
    // Capture the config we just tore down so the next apply() with the
    // same desired set returns early instead of re-activating → flapping.
    lastFailedConfiguration = (allowed: appliedAllowed, systemItems: appliedAllowedSystemItems)
    // Also bump a tear-down counter so repeated tear-downs escalate.
    consecutiveTearDowns += 1
}
```
Add `private var consecutiveTearDowns = 0` and clear it in `apply()` at
the point where a genuinely different config is detected (line 402 area,
where `lastFailedConfiguration = nil` runs).

Then in `SimpleItemHider.resetBackendRestriction()`:
```swift
private func resetBackendRestriction() {
    backend.markExternallyTornDown()
    backend.apply(sectionAssignment: [:], allItems: [])
}
```

**Verify**: build → exit 0.

### Step 2: Escalate after N consecutive tear-downs (circuit breaker)

In `AssessmentModeBackend.apply()`, after the `lastFailedConfiguration`
guard (`:396-401`), add a circuit-breaker: if `consecutiveTearDowns >= 3`
(for the same config), log an `.error` and leave the assertion OFF
(`handle = nil`) until the desired config genuinely changes (clear
`consecutiveTearDowns` when `concealedChanged` or `systemItemsChanged` is
true). This stops the flap after 3 cycles instead of running forever.

```swift
if consecutiveTearDowns >= 3,
   allowedSet == lastFailedConfiguration?.allowed,
   allowedSystemItemSet == lastFailedConfiguration?.systemItems
{
    diagLog.error("apply: suppressing re-activation after \(consecutiveTearDowns) consecutive verify tear-downs (circuit breaker); config: concealed=\(concealedBundleIDs.sorted())")
    return false
}
```

The threshold of 3 is a starting point — the maintainer may tune it. The
key invariant: a genuine change to the desired set (drag, reset, app
launch) clears `consecutiveTearDowns` and `lastFailedConfiguration`, so
the user is never stuck.

**Verify**: `xcodebuild test ...` → exit 0. Manually (if a test harness
allows): seed `hidingUnsupportedBundleIDs` with a bundle that the
assertion collateral-hides, and confirm the bar flaps at most 3 times
then settles with the assertion OFF and an `.error` log — instead of
flapping forever.

### Step 3: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` → no leftover diffs.

## Test plan

- This plan defers unit tests to plan 016 (SimpleItemHider test seams) —
  the verify path needs an injectable `AssessmentModeBackend`. The
  verification gate here is the existing suite + a manual smoke test if
  the denylist can be seeded.
- If plan 016 has landed, add a case: inject a fake backend whose
  `apply` simulates the tear-down cycle, seed a denylist, and assert
  `markExternallyTornDown` is called and the circuit breaker fires after
  3 cycles.

## Done criteria

- [ ] `AssessmentModeBackend.markExternallyTornDown()` exists and is called from `SimpleItemHider.resetBackendRestriction()`.
- [ ] `consecutiveTearDowns` circuit breaker fires after 3 same-config tear-downs.
- [ ] A genuine config change clears `consecutiveTearDowns` and `lastFailedConfiguration`.
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- The verify safety net's correctness depends on the immediate tear-down
  happening on EVERY collateral-hide — if the backoff causes a
  denylisted item to stay hidden longer than acceptable, STOP. The
  safety net exists to strand items invisible; the backoff trades "flap
  forever" for "leave the assertion off after 3 tries" — confirm with
  the maintainer that "assertion off, item visible" is an acceptable
  steady state (it should be: the assertion off means nothing is
  hidden, so the denylisted item is visible by definition).
- `AssessmentModeBackend.lastFailedConfiguration`'s type doesn't match
  the captured config (it's `(allowed: Set<String>, systemItems: Set<Int>)?`
  per `:141`) — `appliedAllowed`/`appliedAllowedSystemItems` must fit
  that shape; if not, adapt the capture.
- Existing tests fail because the circuit breaker suppresses a
  legitimate re-activation — do not loosen the tests; report.

## Maintenance notes

- The threshold (3) is tunable; a reviewer should confirm it's not so
  low that normal settling flaps trip it, and not so high that the flap
  is visible for too long.
- When `hidingUnsupportedBundleIDs` is empty (the current state), this
  code is inert — the verify early-returns. The backoff only matters
  when the denylist is repopulated. A reviewer should seed the denylist
  locally to validate the backoff before merging.
- Coordinate with plan 016: the `markExternallyTornDown` method should
  be on the `AssessmentModeBackend` protocol/struct that 016's injection
  exposes, so tests can assert it.
