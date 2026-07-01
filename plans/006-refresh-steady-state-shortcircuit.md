# Plan 006: Short-circuit the 1Hz hider refresh on the steady state

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- Thaw/MenuBar/HiddenSectionPatch/AssessmentModeBackend.swift Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift`
> If either file changed since this plan was written, compare the "Current
> state" excerpts against the live code before proceeding.

## Status

- **Priority**: P2
- **Effort**: S-M
- **Risk**: LOW-MED
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

`SimpleItemHider` runs a 1Hz `Timer` (`:655-662`) that calls `refresh()`,
which calls `AssessmentModeBackend.apply(...)`. Even at steady state —
zero state change, the same items hidden, no app launch/quit — both
functions do significant work every second, forever:

- `AssessmentModeBackend.apply` iterates `allItems` to learn bundle IDs
  (`:207-219`), rebuilds `Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))`
  (`:316-320`), and runs a "self-check" loop that does
  `runningApplications.contains { ... }` once per protected bundle AND
  emits a `diagLog.info` line per bundle (`:348-353`) — all BEFORE the
  dedupe guard at `:368` that could short-circuit the expensive assertion
  re-activation. So the guard prevents re-activation but not the per-tick
  prep.
- `SimpleItemHider.refresh` rebuilds invalid-assignment `Set`s (`:924-928`),
  re-snapshots every assigned live item (`:940-943`), recomputes CC-hidden
  titles (`:956-962`), and re-runs the experimental window-hiding passes
  (`:976-981`) every tick — even when nothing changed.

On an idle machine this is steady CPU, AX IPC, and log noise (a self-check
`.info` line per protected bundle per second). The fix: compute a cheap
desired-state signature at the top of each function and return early when
it's unchanged; let the explicit mutators (`setSection`, `show`,
`hideRevealedSections`, `revealItemTemporarily`) keep triggering full
refreshes directly.

## Current state

`Thaw/MenuBar/HiddenSectionPatch/AssessmentModeBackend.swift`:
- `:111` — `private var handle: UnsafeMutableRawPointer?`
- `:114` — `appliedConcealed: Set<String> = []`
- `:117` — `appliedAllowed: Set<String> = []`
- `:144` — `appliedAllowedSystemItems = AssessmentModeBackend.allSystemItems`
- `:200-219` — `apply()` starts by iterating `allItems` to populate
  `knownBundleIDs`/`knownSystemItemIDs`.
- `:316-320` — `var allowedSet = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).filter { ... })`
- `:348-353` — self-check loop:
  ```swift
  for ownBundleID in protectedBundleIDs.sorted() {
      let running = NSWorkspace.shared.runningApplications.contains {
          $0.bundleIdentifier == ownBundleID
      }
      diagLog.info("self-check: \(ownBundleID) allowed=\(...) concealed=\(...) inRunningApps=\(running)")
  }
  ```
- `:365-368` — the dedupe guard:
  ```swift
  let concealedChanged = concealedBundleIDs != appliedConcealed
  let systemItemsChanged = allowedSystemItemSet != appliedAllowedSystemItems
  let newlyAppeared = !allowedSet.subtracting(appliedAllowed).isEmpty
  guard handle == nil || concealedChanged || systemItemsChanged || newlyAppeared else { return false }
  ```

`Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift`:
- `:655-662` — `start()` creates the 1s Timer.
- `:920` — `func refresh()`.
- `:924-928` — `invalidAssignmentIdentifiers(...)` rebuilds three `Set`s.
- `:940-943` — snapshot rebuild + `snapshots.filter`.
- `:956-962` — `ccHiddenTitles` + `ccModuleManager.apply(...)`.
- `:976-981` — `applyExperimentalWindowHiding(...)`.
- `:61,67,71,77` — the `@Published` state (`sectionAssignment`,
  `sectionItemOrder`, `revealedSection`, `temporarilyRevealedIDs`) whose
  mutation should drive a real refresh.

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/MenuBar/HiddenSectionPatch/AssessmentModeBackend.swift`
- `Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift`

**Out of scope**:
- Do NOT change the mutator methods (`setSection`, `show`,
  `hideRevealedSections`, `revealItemTemporarily`,
  `scheduleTemporaryItemConceal`) — they must keep calling `refresh()`
  directly so user actions take effect immediately.
- Do NOT change the Timer interval (1s) — a new app appearing must still
  be picked up within ~1s. The signature must include the live-item
  identifier set so a new app drives a change.
- Do NOT touch `pulse()` or `reset()` — they are explicit re-activation
  paths.
- Do NOT change the self-check's content — only gate it behind the
  "restriction really changed" branch.

## Git workflow

- Branch: `advisor/006-refresh-steady-state-shortcircuit`
- Commit style: `perf(hider): short-circuit 1Hz refresh and backend prep on the steady state`

## Steps

### Step 1: Gate `AssessmentModeBackend.apply`'s per-tick prep behind a cheap signature

Goal: at the top of `apply(...)`, compute a cheap "desired-state signature"
and return `false` early if it matches the currently-applied state AND the
running-bundle set is unchanged — BEFORE iterating `allItems` for
`knownBundleIDs`, BEFORE rebuilding `allowedSet` from
`runningApplications`, and BEFORE the self-check loop.

However, `knownBundleIDs` is sticky (it absorbs newly-appeared items so
concealed items stay concealed after they drop out of AX enumeration). So
the signature cannot skip the `allItems` learn-pass entirely if a NEW item
appeared. The safe, minimal change:

1. Move the **self-check loop** (`:348-353`) to AFTER the dedupe guard
   (`:368`) — it should only run when a re-activation is actually
   happening. This alone removes the per-tick `.info` log line per
   protected bundle and the per-bundle `runningApplications.contains` scan.
2. Add a cheap early-exit at the very top of `apply`, BEFORE the
   `allItems` learn-pass (`:207`): compute
   `let liveIDSet = Set(allItems.map(\.uniqueIdentifier))` and
   `let runningBundleSet = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))`,
   then if `handle != nil`, `liveIDSet == lastLiveIDSet`,
   `runningBundleSet == lastRunningBundleSet`, and
   `sectionAssignment == lastSectionAssignment`, return `false`. Store
   `lastLiveIDSet`, `lastRunningBundleSet`, `lastSectionAssignment` as
   private `Set`/`Dictionary` properties (add them near `appliedConcealed`).
   Clear all three whenever `reset()` or `pulse()` runs (they already
   clear `appliedConcealed`/`appliedAllowed`).

   **Escape hatch**: if computing `liveIDSet` and `runningBundleSet`
   itself proves non-trivial (it's two `Set` constructions per tick —
   cheaper than the full prep but not free), the MINIMUM acceptable change
   is still Step 1 (moving the self-check). Do not over-engineer the
   signature; if the early-exit adds complexity risk, ship Step 1 alone
   and note the signature as deferred.

**Verify**: build → exit 0. Then add a temporary `diagLog.debug("apply: early-exit steady state")` in the early-return path and confirm via a manual run (or a test) that at steady state the message fires and the self-check `.info` lines stop. Remove the temporary log before committing.

### Step 2: Add a short-circuit to `SimpleItemHider.refresh()`

At the top of `refresh()` (`:920`), compute a signature over the inputs
that, if unchanged, means the tick has nothing to do:
```swift
let signature = (
    sectionAssignment,
    revealedSection,
    temporarilyRevealedIDs,
    Set(allItems.map(\.uniqueIdentifier))
)
if signature == lastRefreshSignature {
    return
}
lastRefreshSignature = signature
```
Add `private var lastRefreshSignature: (Set<...>, ...)?` — or use a
hashable representation. The `Set(allItems.map(\.uniqueIdentifier))` term
ensures a newly-appeared app still drives a real refresh.

**Important**: the explicit mutators (`setSection`, `show`, etc.) mutate
`sectionAssignment`/`revealedSection`/`temporarilyRevealedIDs` BEFORE
calling `refresh()`, so the signature will differ and the refresh will
run. Verify this by reading each mutator (they should mutate
`@Published` state then call `refresh()`). If any mutator calls
`refresh()` WITHOUT first mutating state, that's a separate bug — report
it, don't work around it.

Clear `lastRefreshSignature = nil` in `hideRevealedSections` and any path
that should force the next tick to run unconditionally.

**Verify**: `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` → exit 0, all tests pass.

### Step 3: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` → no leftover diffs.

## Test plan

- This plan defers new unit tests to plan 016 (`SimpleItemHider` test
  seams) — the short-circuit is hard to test without injecting the
  collaborators. The verification gate here is the existing test suite
  (must still pass) plus a manual confirmation that steady-state log
  noise drops.
- If plan 016 has already landed when this plan executes, add a test:
  construct a `SimpleItemHider` with fake collaborators, call `refresh()`
  twice with the same `allItems`, and assert the backend's `apply` was
  called at most once (use a counting fake).

## Done criteria

- [ ] The self-check loop in `AssessmentModeBackend.apply` runs only when a re-activation is happening (moved after the dedupe guard) OR a cheap early-exit prevents the per-tick prep.
- [ ] `SimpleItemHider.refresh()` returns early when its input signature is unchanged.
- [ ] `xcodebuild test ...` exits 0 (existing tests still pass).
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- A mutator (`setSection`/`show`/`hideRevealedSections`/`revealItemTemporarily`)
  calls `refresh()` WITHOUT first mutating state — the short-circuit would
  then swallow the user's action. Report the mutator and stop.
- The early-exit signature is hard to make `Hashable` (e.g.
  `sectionAssignment` is `[String: MenuBarSection.Name]` which is
  hashable, but if `MenuBarSection.Name` isn't `Hashable`, stop and
  report — do not add a conformance in this plan).
- Existing tests fail after the change in a way that indicates the
  short-circuit is skipping a real change — do not loosen the tests;
  report.

## Maintenance notes

- If a future change adds a new input to `refresh()` (e.g. a new
  `@Published` property that affects hiding), it MUST be added to the
  signature or the tick will miss it.
- The self-check loop is diagnostic — if a maintainer wants it back at
  steady state, gate it behind the `diagnosticAssessmentModeSceneProbes`
  default rather than re-running it unconditionally.
- A reviewer should confirm that `pulse()` and `reset()` clear
  `lastRefreshSignature` / the backend's `last*` properties, so an
  explicit pulse is not swallowed by the steady-state guard.
