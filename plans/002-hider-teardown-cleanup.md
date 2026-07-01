# Plan 002: Add `deinit` and `willTerminate` cleanup across the macOS 27 hider classes

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- Thaw/MenuBar/HiddenSectionPatch`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (plan 001 is not a hard dependency, but read `AGENTS.md` if present for conventions)
- **Category**: bug
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

Five classes in `Thaw/MenuBar/HiddenSectionPatch/` own resources that must be
released on teardown — a private-API assertion handle, a `RunLoop.main` Timer,
and `NotificationCenter` observers — yet none of them has a `deinit`, and one
(`TrailingItemPositionStore`) doesn't even register a `willTerminate`
observer like its siblings do. Today these objects live for the whole app
session (owned by `SimpleItemHider` via `MenuBarManager`), so normal quit
masks the leaks. But any lifecycle change — recreating the hider on a
settings toggle, a test that constructs and tears one down, or a future
refactor — leaks the Timer permanently on the RunLoop, leaves the
private-API assertion active after deallocation, and (for
`TrailingItemPositionStore`) strands menu bar icons hidden after quit when
the experimental flag is on. The fix is the standard Swift teardown pattern,
matching the existing `deinit` in `MenuBarItemManager`.

## Current state

Confirmed by `grep -rn "deinit" Thaw/MenuBar/HiddenSectionPatch/` → **no
matches** (none of these classes has a `deinit`).

The five classes and what they own:

1. **`AssessmentModeBackend.swift`** (`@MainActor final class`, 509 lines) —
   `private var handle: UnsafeMutableRawPointer?` at `:111`. The handle is a
   `CFBridgingRetain`'d `MBAssessmentModeAssertion` (see
   `ThawAssessmentModeHiding.m:97`). Only `reset()` (`:499-508`) and
   re-activation (`:453-456`) call `ThawAssessmentModeHidingInvalidate(handle)`.
   On deallocation with `handle != nil`, the +1 retain leaks and the
   assertion stays active. **No `deinit`.**

2. **`SimpleItemHider.swift`** (`@MainActor final class`, 1466 lines) —
   `private var timer: Timer?` at `:112`, added to `RunLoop.main` for
   `.common` at `:659` (created in `start()` at `:655-662`, never
   invalidated). `private var boundaryReconciliationTask: Task<Void, Never>?`
   at `:113`. `private var temporaryRevealConcealTasks = [String: Task<Void, Never>]()`
   at `:78`. The Timer closure uses `[weak self]` (`:657`) so it no-ops after
   dealloc, but the `Timer` object itself is retained by `RunLoop.main`
   forever. **No `deinit`.**

3. **`CGSWindowHider.swift`** (`@MainActor final class`, 148 lines) —
   `private var terminationObserver: NSObjectProtocol?` at `:62`, registered
   at `:69-75` via `addObserver(forName:object:queue:using:)`. `NotificationCenter`
   retains the observer+block; the block uses `[weak self]` so it no-ops, but
   the observer token is never removed. **No `deinit`.**

4. **`AXItemHider.swift`** (`@MainActor final class`, 189 lines) —
   `private var terminationObserver: NSObjectProtocol?` at `:28`, registered
   at `:31-37`. Same pattern as CGS. **No `deinit`.**

5. **`ControlCenterModuleManager.swift`** (`@MainActor final class`, 261
   lines) — `private var terminationObserver: NSObjectProtocol?` at `:119`,
   registered at `:129-136`. Same pattern. **No `deinit`.**

6. **`TrailingItemPositionStore.swift`** (`@MainActor final class`, 483
   lines) — owns `originalPositions` (`:30`) and `hiddenPlistKeys` (`:35`).
   Its `restoreAll()` (`:124-131`) restores both, but is **only called when
   the experimental flag is toggled off** (per `SimpleItemHider`), never on
   quit. **No `willTerminate` observer and no `deinit`** — the inconsistency
   vs. its siblings (CGS/AX/CCM all register `willTerminate`). With
   `enableExperimentalWindowHiding` on, items hidden by removing their
   `TrailingItemPreferredPositions` keys stay hidden after Thaw quits.

**Existing exemplar to match**: `Thaw/MenuBar/MenuBarItems/MenuBarItemManager.swift`
has a `deinit` that invalidates its `rehideTimer` and cancels
cancellables/tasks — follow that pattern. Read it with
`grep -n "deinit" -A 15 Thaw/MenuBar/MenuBarItems/MenuBarItemManager.swift`.

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |
| Format | `swiftformat .` | files formatted (idempotent) |

## Scope

**In scope** (the only files you should modify):
- `Thaw/MenuBar/HiddenSectionPatch/AssessmentModeBackend.swift`
- `Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift`
- `Thaw/MenuBar/HiddenSectionPatch/CGSWindowHider.swift`
- `Thaw/MenuBar/HiddenSectionPatch/AXItemHider.swift`
- `Thaw/MenuBar/HiddenSectionPatch/ControlCenterModuleManager.swift`
- `Thaw/MenuBar/HiddenSectionPatch/TrailingItemPositionStore.swift`

**Out of scope**:
- Do NOT change the `apply`/`refresh`/`restoreAll` logic itself — only add
  teardown.
- Do NOT touch `MenuBarItemManager.swift`'s existing `deinit` (it's the
  exemplar, not a target).
- Do NOT add new tests in this plan (teardown paths are hard to test without
  injection; a later characterization-test plan covers that).

## Git workflow

- Branch: `advisor/002-hider-teardown-cleanup`
- Commit style: `fix(hider): release assertion handle, invalidate timer, and remove observers on deinit`
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: `AssessmentModeBackend` — add `deinit` to invalidate the handle

Add this `deinit` to the class (place it just below `init` or wherever the
existing structure naturally accepts it; `AssessmentModeBackend` has no
explicit `init`, so place it near the top of the class body, after the
stored properties):

```swift
deinit {
    if let handle {
        ThawAssessmentModeHidingInvalidate(handle)
    }
}
```

`ThawAssessmentModeHidingInvalidate` is a C function (declared in
`ThawAssessmentModeHiding.h`) that tolerates `NULL` (see
`ThawAssessmentModeHiding.m:104-107`), so calling it from a `@MainActor`
class's `deinit` (which is `nonisolated`) is safe — it is not an instance
method and does not touch `self`'s actor state. If the compiler complains
about accessing `handle` from `nonisolated deinit`, read the property into
a local before the deinit body runs is not possible; instead, mark the
access with `MainActor.assumeIsolated` is WRONG in deinit — the correct
fix is that `UnsafeMutableRawPointer?` is `Sendable` and the property is
not actor-isolated for reads of a `Sendable` type in a `nonisolated deinit`.
If Swift 6 still rejects the bare read, wrap as:
```swift
deinit {
    let handleToInvalidate = handle
    if let handleToInvalidate {
        ThawAssessmentModeHidingInvalidate(handleToInvalidate)
    }
}
```
(Reading `handle` into a local in `deinit` is the documented Swift 6
pattern for `@MainActor` classes; the local is `Sendable`.)

**Verify**: `xcodebuild build -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` → exit 0.

### Step 2: `SimpleItemHider` — add `deinit` to invalidate the Timer, cancel Tasks

Add:
```swift
deinit {
    timer?.invalidate()
    boundaryReconciliationTask?.cancel()
    for task in temporaryRevealConcealTasks.values {
        task.cancel()
    }
}
```
(Read each property into a local first if the compiler flags `nonisolated
deinit` access — same pattern as Step 1. `Timer?`, `Task<Void, Never>?`,
and `[String: Task<Void, Never>]` contain `Sendable` referents.)

**Verify**: build → exit 0.

### Step 3: `CGSWindowHider`, `AXItemHider`, `ControlCenterModuleManager` — add `deinit` to remove the `willTerminate` observer

For each of these three classes, add:
```swift
deinit {
    if let terminationObserver {
        NotificationCenter.default.removeObserver(terminationObserver)
    }
}
```
(`terminationObserver` is `NSObjectProtocol?`, `Sendable`.)

For these three, the `willTerminate` block already calls `restoreAll()` via
`[weak self]` — that fires only on app quit, not on dealloc. The `deinit`
does NOT need to call `restoreAll()` (the observer won't fire after
dealloc, but these objects are session-lifetime; if you want belt-and-
suspenders, you MAY call `restoreAll()` before `removeObserver` in `deinit`,
but it is optional and not required for correctness). Keep the `deinit`
minimal: just `removeObserver`.

**Verify**: build → exit 0; `swiftlint --strict` → exit 0.

### Step 4: `TrailingItemPositionStore` — register a `willTerminate` observer (matching siblings) and add a `deinit`

This is the inconsistent one: it has no `willTerminate` observer. Add both.
Add a stored property near the other stored properties:
```swift
private var terminationObserver: NSObjectProtocol?
```
In `init` (the class has no explicit `init` — it uses the default
`@MainActor init()`), add an `init()` that registers the observer. If the
class is constructed with arguments in practice, check the call site
(`SimpleItemHider.init` constructs `TrailingItemPositionStore(appState:)`
or similar — read `SimpleItemHider.swift` around `:123-127` to confirm the
constructor signature and match it). Add:
```swift
init(notificationCenter: NotificationCenter = .default) {
    terminationObserver = notificationCenter.addObserver(
        forName: NSApplication.willTerminateNotification,
        object: nil,
        queue: .main
    ) { [weak self] _ in
        MainActor.assumeIsolated { self?.restoreAll() }
    }
}
```
Match the exact pattern from `CGSWindowHider.init` (`:64-76`).

Then add the `deinit`:
```swift
deinit {
    if let terminationObserver {
        NotificationCenter.default.removeObserver(terminationObserver)
    }
}
```

**STOP condition**: if `TrailingItemPositionStore` already has an `init`
with a different signature (e.g. it takes an `appState`), do NOT break the
call site — extend the existing `init` to also register the observer, and
keep the existing parameters. Report the signature you found.

**Verify**: build → exit 0; `swiftlint --strict` → exit 0.

### Step 5: Run the full test suite and lint

**Verify**:
- `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` → exit 0, all tests pass.
- `swiftlint --strict` → exit 0.
- `swiftformat .` → no leftover diffs (run it; it's idempotent).

## Test plan

No new tests in this plan (teardown paths need injection seams from a
later plan). Existing tests must still pass — the verification gate is the
full `xcodebuild test` suite.

If a future plan adds `TrailingItemPositionStore` tests (see
`plans/017-trailingitempositionstore-tests.md`), it should add a case that
constructs the store, hides an item, and asserts `restoreAll()` is called on
`willTerminate` — but that is out of scope here.

## Done criteria

- [ ] `grep -rn "deinit" Thaw/MenuBar/HiddenSectionPatch/` returns matches in all five classes (`AssessmentModeBackend`, `SimpleItemHider`, `CGSWindowHider`, `AXItemHider`, `ControlCenterModuleManager`) plus `TrailingItemPositionStore`.
- [ ] `TrailingItemPositionStore` registers a `willTerminate` observer (matching `CGSWindowHider.init`).
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0.
- [ ] `swiftformat .` leaves no uncommitted formatting diffs.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- The code at the cited locations doesn't match the excerpts (drift since
  this plan was written).
- `TrailingItemPositionStore` has an existing `init` signature you cannot
  extend without breaking a call site — report the signature and stop.
- A `deinit` access triggers a Swift 6 error you cannot resolve with the
  "read into a local" pattern — report the exact error and stop.
- Any test fails after the change that cannot be attributed to teardown
  ordering (do not "fix" unrelated tests).

## Maintenance notes

- If `SimpleItemHider` gains new `Task` or `Timer` properties, add their
  cancellation to its `deinit` in the same PR.
- The `willTerminate` observer pattern is now consistent across all four
  plist/CGS/AX/CCM stores — a reviewer should confirm `TrailingItemPositionStore`'s
  observer block matches `CGSWindowHider`'s byte-for-byte (modulo the
  `restoreAll` target).
- A reviewer should confirm `AssessmentModeBackend.deinit` calls
  `ThawAssessmentModeHidingInvalidate` (not `reset()` — `reset()` does
  extra bookkeeping that touches actor state and is unsafe in `deinit`).
