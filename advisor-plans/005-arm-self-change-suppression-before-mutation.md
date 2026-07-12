# Plan 005: Arm self-change suppression windows before the mutation that can trigger them, not after

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md` — unless a reviewer dispatched you and told you
> they maintain the index.
>
> **Drift check (run first)**: `git diff --stat b41f1e96..HEAD -- Thaw/MenuBar/HiddenSectionPatch/MenuBarSectionController.swift`
> If that file changed since this plan was written, compare the "Current
> state" excerpts below against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW (reordering two already-adjacent statements; no new logic)
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `b41f1e96`, 2026-07-11

## Why this matters

This project previously shipped a fix for a SIGABRT crash loop caused by
`AssessmentStateMonitor`'s self-suppression window not covering a recovery
re-apply's own follow-on `com.apple.donotdisturb.stateChanged` notification —
the notification re-entered recovery, which posted again, which re-entered
again, until AppKit's status-item scene machinery crashed. The fix was a
1.5-second self-change suppression window (`noteSelfChange()`), armed by the
caller right when it makes a self-initiated assertion mutation.

In the code as committed, `noteSelfChange()` is called **after** the mutation
it's meant to shield (`backend.apply(...)` / `backend.pulse(...)`), not
before. `com.apple.donotdisturb.stateChanged` is a
`DistributedNotificationCenter` notification — posted by a **different
process** (the DND/Assessment-Mode daemon) in response to the assertion
mutation, delivered to our process asynchronously. There is no run-loop
guarantee that this cross-process notification can't arrive and be processed
before our own `noteSelfChange()` call executes, especially if the private
assertion API involves any synchronous IPC round-trip that pumps our run loop
internally. If that happens, the suppression window opens too late and the
exact feedback loop this code was written to prevent can recur.

The fix is mechanical and safe regardless of whether the race is provably
real: arm the suppression window immediately before the mutation instead of
immediately after. This can only ever suppress **more** self-attributed
notifications, never fewer, so it cannot introduce a new bug — the window
already exists specifically to be over-inclusive ("swallows the entire
self-attributed burst," per the existing code comment).

## Current state

`Thaw/MenuBar/HiddenSectionPatch/MenuBarSectionController.swift`:

```swift
560:        let assignment = assertionAssignmentInput()
561:        guard assignment.values.contains(where: { $0 == .hidden || $0 == .alwaysHidden }) else {
562:            return false
563:        }
564:        let allItems = appState.itemManager.itemCache.managedItems
565:
566:        var didChange = false
567:        if recoverySnapshot().isControlledHidden {
568:            didChange = backend.apply(sectionAssignment: [:], allItems: allItems)
569:        }
570:        didChange = backend.pulse(
571:            sectionAssignment: assignment,
572:            allItems: allItems
573:        ) || didChange
574:        noteRecoveryRestrictionChange(didChange)
575:        return didChange
576:    }
577:
578:    private func noteRecoveryRestrictionChange(_ didChange: Bool) {
579:        guard didChange, let appState else { return }
580:        assessmentStateMonitor?.noteSelfChange()
581:        appState.itemManager.noteRestrictionChange()
582:        restoreVisibleControlItemAfterRestrictionChange()
583:    }
```

`noteRecoveryRestrictionChange` (and therefore `noteSelfChange()`) is called
**after** both `backend.apply` and `backend.pulse` — the actual assertion
mutations — have already executed.

There are more call sites of `assessmentStateMonitor?.noteSelfChange()` and
`prefsWatcher?.noteSelfWrite()` elsewhere in this file (`grep -n
"noteSelfChange\|noteSelfWrite" Thaw/MenuBar/HiddenSectionPatch/MenuBarSectionController.swift`
currently shows 13 call sites of `noteSelfWrite()` and 2 of
`noteSelfChange()`). This plan is scoped to `noteSelfChange()` only — see
Scope below for why `noteSelfWrite()` is excluded.

`AssessmentStateMonitor.swift`'s own doc comment currently says (this
sentence itself should be corrected as part of this fix, since the fix
inverts the calling contract):

```swift
    /// Opens a window during which DND/assessment notifications attributed to
    /// Thaw's own assertion change are ignored. Call this immediately after a
    /// self-initiated assertion mutation; re-arming extends...
    func noteSelfChange() {
```

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build + test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, all tests pass |
| Lint | `swiftlint --strict` | exit 0 |
| Confirm call order | `grep -n "noteSelfChange\|backend.apply\|backend.pulse" Thaw/MenuBar/HiddenSectionPatch/MenuBarSectionController.swift` | `noteSelfChange()` line number now precedes both `backend.apply`/`backend.pulse` call sites within the same function |

## Scope

**In scope**:
- `Thaw/MenuBar/HiddenSectionPatch/MenuBarSectionController.swift` — reorder
  the two call sites listed below (lines 560-583 and 1500-1530-ish; re-locate
  by searching for `assessmentStateMonitor?.noteSelfChange()`, there are
  exactly 2 matches as of the planned commit).
- `Thaw/MenuBar/HiddenSectionPatch/AssessmentStateMonitor.swift` — update the
  doc comment on `noteSelfChange()` to say "call before" instead of "call
  after," matching the corrected contract.
- `ThawTests/AssessmentStateMonitorTests.swift` — add a test for the ordering
  guarantee (see Test plan).

**Out of scope**:
- `MenuBarAgentPreferencesWatcher.noteSelfWrite()` and its ~13 call sites.
  This one was independently verified during the advisor review to be safe
  as committed: `noteSelfWrite()` synchronously re-reads and stores
  `lastSnapshot` at the moment it's called, and both the watcher's
  `DispatchSourceFileSystemObject` event handler and every caller are
  main-actor isolated with no `await` between the file write and the
  `noteSelfWrite()` call, so a queued file-system event cannot interleave
  with it. Do not "fix" this one — it is not broken, and moving these calls
  around risks introducing an actual bug into currently-correct code.
- Any change to the 1.5-second suppression window duration itself, or to the
  burst-suppression logic in `AssessmentStateMonitor.start()`'s observer
  closure — only the call-site ordering changes.
- `backend.apply` / `backend.pulse` implementations themselves — not part of
  this diff and not the source of the bug.

## Git workflow

- Branch: `advisor/005-assessment-monitor-arm-order`
- One commit, message style matching repo convention, e.g.
  `fix(menu): arm assessment self-change suppression before assertion mutation`
- Do NOT push or open a PR.

## Steps

### Step 1: Locate both call sites

```bash
grep -n "assessmentStateMonitor?.noteSelfChange()" Thaw/MenuBar/HiddenSectionPatch/MenuBarSectionController.swift
```

Expect 2 matches (as of `b41f1e96`, at lines 580 and 1520). For each, read
30 lines of surrounding context to find the enclosing function and the exact
mutation call(s) (`backend.apply`, `backend.pulse`, or equivalent) that
precede it.

### Step 2: Reorder the first call site (around line 560-583)

Move the `assessmentStateMonitor?.noteSelfChange()` call so it executes
**before** `backend.apply(sectionAssignment:allItems:)` and
`backend.pulse(sectionAssignment:allItems:)` run, not after. Concretely:
extract the `noteSelfChange()` call out of `noteRecoveryRestrictionChange`
into its own step at the top of the enclosing function (the one containing
lines 560-576), called unconditionally before the `if
recoverySnapshot().isControlledHidden` block — since the window is designed
to be over-inclusive (see "Why this matters"), arming it even when
`didChange` later turns out `false` is safe and matches the existing
"swallow the whole burst" philosophy. `noteRecoveryRestrictionChange` keeps
its other two calls (`appState.itemManager.noteRestrictionChange()` and
`restoreVisibleControlItemAfterRestrictionChange()`) exactly as they are —
only `noteSelfChange()` moves out.

**Verify**: re-run the grep from Step 1; the `noteSelfChange()` line number
at this site must now be lower than the `backend.apply`/`backend.pulse` line
numbers in the same function.

### Step 3: Reorder the second call site (around line 1500-1530)

Read the function containing the second `noteSelfChange()` call (originally
around line 1520) in full, identify the assertion-mutating call(s) it's
meant to shield, and apply the same reordering principle: arm before mutate.
If this function's structure doesn't cleanly support hoisting the call to
the very top (e.g. the mutation decision itself isn't known until partway
through), place `noteSelfChange()` immediately before the *first* line that
can trigger a `stateChanged` notification, even if that means it fires in
some code paths that ultimately don't mutate anything — that's the safe
direction to err in.

**Verify**: re-run the grep from Step 1 for this second site; same ordering
check.

### Step 4: Update the doc comment

In `AssessmentStateMonitor.swift`, change the doc comment on `noteSelfChange()`
from "Call this immediately after a self-initiated assertion mutation" to
"Call this immediately before a self-initiated assertion mutation" (or
equivalent wording — the point is the contract must now say "before").

**Verify**: `grep -n "Call this immediately" Thaw/MenuBar/HiddenSectionPatch/AssessmentStateMonitor.swift` → shows "before," not "after."

### Step 5: Build and test

**Verify**: `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` → exit 0, all tests pass (including the existing `AssessmentStateMonitorTests.swift`, which must still pass unmodified since this plan doesn't change `AssessmentStateMonitor`'s own logic, only its callers).

## Test plan

- Add a test to `ThawTests/AssessmentStateMonitorTests.swift` (model it after
  `testSelfChangeSuppressesWholeBurst` already in that file) that simulates
  the race directly: call `noteSelfChange()`, then **immediately** (same
  synchronous scope, no `await` in between) post a burst of
  `stateChangedNotification` via `deliverImmediately: true`, and assert the
  reconcile callback fires zero times. This is really testing
  `AssessmentStateMonitor` itself (already correct) — the point of this test
  is to act as a regression guard on the *contract*, so a future caller that
  reintroduces "arm after mutate" ordering has a clear example of the
  supported pattern to copy from.
- If `MenuBarSectionController`'s two call sites are reachable by an existing
  test in `ThawTests/MenuBarSectionControllerTests.swift` that already
  exercises `backend.apply`/`backend.pulse` (check via `grep -n "backend.apply\|backend.pulse"
  ThawTests/MenuBarSectionControllerTests.swift`), consider adding an
  assertion there that `noteSelfChange()` — or a test double / spy standing
  in for the monitor — is invoked before the mock backend's `apply`/`pulse`
  is invoked, if the test harness already has a mock backend with call-order
  tracking. If no such mock exists, do not build one from scratch for this
  plan — the direct `AssessmentStateMonitor` test above is the required
  minimum; call it out in NOTES if the `MenuBarSectionController`-level test
  was skipped for this reason.
- Verification: full test command above → all pass, including the new test.

## Done criteria

- [ ] `xcodebuild test ...` exits 0
- [ ] `swiftlint --strict` exits 0
- [ ] Both `noteSelfChange()` call sites in `MenuBarSectionController.swift`
      precede their corresponding assertion-mutation calls
- [ ] `AssessmentStateMonitor.swift`'s doc comment says "before," not "after"
- [ ] A new test exists asserting the suppress-before-mutate contract and
      passes
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `advisor-plans/README.md` status row for 005 updated

## STOP conditions

Stop and report back (do not improvise) if:

- The code around either `noteSelfChange()` call site has drifted materially
  from the excerpts above (e.g. the function has been refactored into
  multiple smaller functions) — re-locate the mutation and suppression calls
  by their actual current names and confirm the same "arm before mutate"
  principle still applies before proceeding.
- Hoisting `noteSelfChange()` to the top of a function would require calling
  it in a code path that provably never mutates the assertion (e.g. an early
  `guard ... else { return false }` before any mutation) in a way that would
  visibly suppress unrelated, non-self-caused DND state changes for 1.5
  seconds on every call to that function, even when idle. If you find this,
  stop and report the exact function and guard clause — placement needs a
  human judgment call about whether over-suppression here is acceptable.
- Any existing test fails after the reorder — this would mean call order was
  load-bearing in a way not anticipated by this plan; do not force tests to
  pass by weakening assertions.

## Maintenance notes

- The "arm before mutate" pattern established here should be the template
  for any future self-change suppression added to this file — a reviewer
  adding a new assertion mutation path should arm suppression first, mutate
  second.
- `MenuBarAgentPreferencesWatcher.noteSelfWrite()` remains correct as-is and
  intentionally untouched (see Scope) — don't let a future refactor "fix" it
  to match this pattern; its safety currently comes from a different
  mechanism (synchronous same-actor read + no interleaving `await`), not from
  call ordering relative to a cross-process event.
