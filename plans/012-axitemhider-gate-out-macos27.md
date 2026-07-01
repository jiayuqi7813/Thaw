# Plan 012: Resolve `AXItemHider` — gate it out on macOS 27 and fix the contradicting doc

> **Executor instructions**: Follow this plan step by step.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/MenuBar/HiddenSectionPatch/AXItemHider.swift" "Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift"`
> If either file changed since this plan was written, re-read the cited lines.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug + tech-debt
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

`AXItemHider` is documented two contradictory ways: the file-level doc
(`AXItemHider.swift:12-18`) claims it "hides items surgically, without
whole-bar reflow" on macOS 27, while `SimpleItemHider.swift:101-103`
admits "AXHidden is not settable on macOS 27 menu-bar items; this hider
is kept for diagnostics but is effectively a no-op there." The real
reason it's a no-op is deeper than the doc admits:
`AXItemHider.resolveAXElements` (`:118-121`) filters items by
`pids.contains($0.ownerPID)`, but on macOS 27 the `pids` it receives are
`sourcePID`s (the real app — see `SimpleItemHider.swift:1206-1208`),
while `ownerPID` is `MenuBarAgent` (the hosting process). The filter
never matches, so `desiredHidden` is always empty and `apply` does AX
tree walks + `AXHelpers.isProcessTrusted()` checks for guaranteed no
effect — every 1s refresh tick. This is dead weight on macOS 27 (this
branch's only target OS).

The honest fix: gate `AXItemHider` out entirely on macOS 27 (it cannot
work given the hosting model AND AXHidden isn't settable), and correct
the file-level doc to state the real reason. Keep the class for a future
macOS where AXHidden becomes settable, but stop invoking it on 27.

## Current state

`Thaw/MenuBar/HiddenSectionPatch/AXItemHider.swift`:
- `:12-18` — file doc claims surgical hiding on macOS 27 (WRONG).
- `:52` — `apply(hiddenPIDs:allItems:)`.
- `:111-143` — `resolveAXElements` filters `allItems.filter { pids.contains($0.ownerPID) }`
  (`:118-121`), then for each pid does `NSRunningApplication(processIdentifier: pid)`
  + AX tree walk. On macOS 27 `ownerPID` is MenuBarAgent, never matches
  the `sourcePID`-keyed `pids`.

`Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift`:
- `:96-103` — `axItemHider` property with the "effectively a no-op" note.
- `:1166` — refresh path calls `axItemHider.apply(hiddenPIDs: [], allItems: allItems)`
  every tick (to restore).
- `:1221-1231` — the AX pass (run when CGS didn't handle all remaining
  PIDs) calls `axItemHider.apply` with potentially non-empty `hiddenPIDs`.

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/MenuBar/HiddenSectionPatch/AXItemHider.swift` (doc fix only — do
  NOT delete the class; keep it for a future macOS)
- `Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift` (gate the AX
  pass out on macOS 27)

**Out of scope**:
- Do NOT delete `AXItemHider` (it may be revived if AXHidden becomes
  settable; the diagnostics-probe path at `:166-182` is still useful
  behind a flag).
- Do NOT change `CGSWindowHider` or `AssessmentModeBackend`.
- Do NOT touch `MenuBarItem.ownerPID`/`sourcePID` semantics.

## Git workflow

- Branch: `advisor/012-axitemhider-gate-out-macos27`
- Commit style: `fix(hider): stop invoking AXItemHider on macOS 27 and correct its doc`

## Steps

### Step 1: Correct the `AXItemHider` file-level doc

Rewrite the doc comment at `AXItemHider.swift:12-18` to state the real
situation: on macOS 27, menu bar items live in `MenuBarAgent`'s AX tree
(not the real app's `AXExtrasMenuBar`), and `AXHidden` is not settable on
them. So this hider cannot hide on macOS 27; it is retained for the
diagnostics probe (`probeAXElement`) and for a future macOS where AXHidden
becomes settable. Match the existing doc-comment style (the `/// ` lines
above the class).

### Step 2: Gate the AX pass out on macOS 27 in `SimpleItemHider`

In `SimpleItemHider.applyExperimentalWindowHiding` (around `:1157-1260`),
the AX pass at `:1221-1231` runs when CGS didn't handle all remaining
PIDs. Gate it out:

```swift
if #unavailable(macOS 27) {
    let axHandled = axItemHider.apply(hiddenPIDs: remainingPIDs, allItems: allItems)
    remainingPIDs.subtract(axHandled)
}
// On macOS 27, AXItemHider cannot hide (items live in MenuBarAgent's AX
// tree and AXHidden is not settable) — skip the pass; remaining PIDs fall
// back to the assertion.
```

(Confirm the exact `#available`/`#unavailable` spelling the codebase
uses elsewhere — `grep -n "#available(macOS 27" Thaw/MenuBar/HiddenSectionPatch/`
shows the pattern; match it.)

Also gate the every-tick restore call at `:1166`
(`axItemHider.apply(hiddenPIDs: [], allItems: allItems)`) behind the same
`#unavailable(macOS 27)` — on 27 there's nothing to restore (nothing was
hidden via AX).

**Verify**: build → exit 0. `grep -n "axItemHider.apply" Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift` → all matches are now inside `#unavailable(macOS 27)` blocks.

### Step 3: Confirm the diagnostics probe still works behind its flag

`AXItemHider.probeAXElement` (`:166-182`) is a one-shot diagnostic that
logs supported attributes. It's invoked via `findMatchingChild` which is
called by `resolveAXElements`. If `apply` is gated out on 27, the probe
won't run on 27 either. If the maintainer wants the probe available on 27
for diagnostics, expose a separate `probeAllItems(_:)` method gated
behind `diagnosticAssessmentModeSceneProbes` and call it from
`SimpleItemHider`'s diagnostic path. **Default: do NOT add this in this
plan** — the probe is a one-shot `didProbe`-gated diagnostic; leaving it
unreachable on 27 is acceptable. Note it as deferred.

### Step 4: Run tests and lint

**Verify**: `xcodebuild test ...` → exit 0; `swiftlint --strict` → exit 0; `swiftformat .` clean.

## Test plan

- No direct `AXItemHider` tests exist (the class is now inert on 27, the
  only target OS). The verification gate is the existing suite.
- If plan 016 (SimpleItemHider tests) has landed, add a case asserting
  that on macOS 27 the AX pass is skipped (inject a fake `AXItemHider`
  and assert its `apply` is never called).

## Done criteria

- [ ] `AXItemHider.swift` file doc states the real reason (MenuBarAgent AX tree + AXHidden not settable), not the surgical-hiding claim.
- [ ] All `axItemHider.apply` calls in `SimpleItemHider` are gated behind `#unavailable(macOS 27)`.
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- The codebase uses `#available(macOS 27, *)` for gating (not
  `#unavailable`) in a way that makes the `#unavailable` form awkward —
  use whichever form the repo already uses; if unclear, ask.
- `SimpleItemHider` is constructed ONLY on macOS 27 (per its class doc at
  `:32-33`: "Created only on macOS 27+"). If so, gating the AX pass with
  `#unavailable(macOS 27)` means it NEVER runs — which is exactly the
  intent. Confirm this and proceed (the gate is correct; it documents
  WHY the pass is dead here). If `SimpleItemHider` is ever constructed on
  macOS 26, the gate correctly preserves the pass for 26. Either way,
  proceed.

## Maintenance notes

- If a future macOS build makes `AXHidden` settable on menu bar items,
  revive the AX pass: fix `resolveAXElements` to target MenuBarAgent's
  `AXExtrasMenuBar` keyed by `sourcePID`, remove the `#unavailable` gate,
  and update the doc.
- A reviewer should confirm the `didProbe` one-shot diagnostic is
  acceptable to leave unreachable on 27 (Step 3 default).
- This plan resolves findings #14 (no-op wired in) and #15 (PID filter
  bug) together; plan 028 (experimental-flags graduation) may revisit
  whether `AXItemHider` should be deleted entirely.
