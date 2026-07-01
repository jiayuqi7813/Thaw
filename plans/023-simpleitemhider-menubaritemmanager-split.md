# Plan 023: Break the `SimpleItemHider` ↔ `MenuBarItemManager` circular god-object dependency

> **Executor instructions**: This is a **large refactor** gated by tests
> and the protocol seam. Do NOT start until plans 015, 016, and 022 have
> landed. Read "STOP conditions" carefully — this touches the heart of
> the menu bar manager.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift" "Thaw/MenuBar/MenuBarItems/MenuBarItemManager.swift"`
> If either file changed since this plan was written, re-read the cited
> sections before proceeding.

## Status

- **Priority**: P3
- **Effort**: L
- **Risk**: MED
- **Depends on**: plan 015 (AssessmentModeBackend tests), plan 016 (SimpleItemHider injection), plan 022 (ItemHider protocol)
- **Category**: tech-debt
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

`SimpleItemHider` (1466 lines) and `MenuBarItemManager` (9115 lines,
+2202 churn on this branch) are mutual god-objects with a circular
`AppState`-mediated dependency:
- `SimpleItemHider → MenuBarItemManager`: `:450`
  (`reconcileMacOS27SectionBoundaries`), `:507` (`isAnyMenuBarItemMenuOpen`),
  `:543` (`mirrorMacOS27SectionOrder`), `:923` (`itemCache.managedItems`),
  `:989` (`noteRestrictionChange`).
- `MenuBarItemManager → SimpleItemHider`: 9 sites (`:581`, `:4293`,
  `:5593`, `:6298`, `:6631`, `:6690`, `:6986`, `:7027`, `:8644`) reach
  into `appState.menuBarManager.simpleItemHider` and call its internals
  (`setSection`, `persistOrder`, `applyProfileLayout`,
  `resetAssignment`, `section(for:)`).

Neither object can be faked for the other, so they can't be tested
independently, and any refactor on either side ripples to the other. The
+2202 churn in `MenuBarItemManager` is mostly the macOS-27 logic flowing
through `simpleItemHider` — exactly the logic tested only via static
helpers today.

## Current state

The 9 `MenuBarItemManager → simpleItemHider` call sites (confirmed by
grep during audit, but the file is 9115 lines — re-read each before
editing):
- `:581`, `:4293`, `:5593`, `:6298`, `:6631`, `:6690`, `:6986`, `:7027`, `:8644`.

The `SimpleItemHider → itemManager` call sites:
- `:450` (reconcileMacOS27SectionBoundaries), `:507` (isAnyMenuBarItemMenuOpen), `:543` (mirrorMacOS27SectionOrder), `:923` (itemCache.managedItems), `:989` (noteRestrictionChange).

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift` (split into
  smaller objects; depend on protocols, not on `MenuBarItemManager`)
- `Thaw/MenuBar/MenuBarItems/MenuBarItemManager.swift` (depend on
  protocols, not on `simpleItemHider` internals)
- New files for the split pieces (e.g.
  `Thaw/MenuBar/HiddenSectionPatch/SectionAssignmentStore.swift`,
  `SectionRevealController.swift`, `HidingOrchestrator.swift`)

**Out of scope**:
- Do NOT change the runtime hiding/assignment behavior — only the
  module boundaries.
- Do NOT split `MenuBarItemManager` beyond what's needed to break the
  cycle (its full decomposition is out of scope).

## Git workflow

- Branch: `advisor/023-simpleitemhider-menubaritemmanager-split`
- Commit style: `refactor(hider): break SimpleItemHider↔MenuBarItemManager cycle via protocols`
- Commit in small, test-passing steps (one protocol + call-site at a time).

## Steps

### Step 1: Define the protocol seams that break the cycle

Introduce two `@MainActor` protocols capturing the cross-object surface:
```swift
@MainActor
protocol SectionOrdering: AnyObject {
    func orderedItems(in section: MenuBarSection.Name) -> [MenuBarItem]
    func mirrorMacOS27SectionOrder(_ order: [MenuBarSection.Name: [String]])
    // ... the subset of SimpleItemHider methods MenuBarItemManager calls
}

@MainActor
protocol AssignmentSource: AnyObject {
    func section(for identifier: String) -> MenuBarSection.Name
    func setSection(_ section: MenuBarSection.Name, for identifier: String)
    func resetAssignment()
    func applyProfileLayout(...)
    func persistOrder()
    // ... the subset of SimpleItemHider methods MenuBarItemManager calls
}
```
Have `SimpleItemHider` conform to `AssignmentSource` (it already has
these methods). Have `MenuBarItemManager` (or a new
`SectionOrderingProvider`) conform to `SectionOrdering`.

**Verify**: build → exit 0; conformances additive.

### Step 2: Make `MenuBarItemManager` depend on `AssignmentSource`, not `simpleItemHider`

Replace the 9 `appState.menuBarManager.simpleItemHider.<method>` call
sites with calls through an `AssignmentSource` reference (e.g.
`appState.menuBarManager.assignmentSource` that returns the hider-as-
protocol). Read each of the 9 sites first to confirm the method is in
the protocol; widen the protocol if a needed method is missing.

**Verify**: `xcodebuild test ...` → exit 0 (plan 016's tests are the safety net).

### Step 3: Make `SimpleItemHider` depend on `SectionOrdering`, not `itemManager`

Replace the 5 `appState.itemManager.<method>` call sites in
`SimpleItemHider` (`:450`, `:507`, `:543`, `:923`, `:989`) with calls
through a `SectionOrdering` reference. For `isAnyMenuBarItemMenuOpen`
(`:507`), that may belong on a separate `MenuOpenProbe` protocol rather
than `SectionOrdering` — extract it if it's not a section-ordering
concern.

**Verify**: `xcodebuild test ...` → exit 0.

### Step 4: (Optional, if time permits) Split `SimpleItemHider` into cohesive pieces

If the cycle is broken and tests are green, peel off:
- `SectionAssignmentStore` — persistence + eviction (`:185-216`, `:354`, `:924-936`).
- `SectionRevealController` — temporary reveal + conceal tasks (`:419-520`).
- `HidingOrchestrator` — drives backends (`:920-1005`, `:1157-1260`,
  using plan 022's `[SurgicalItemHider]`).

Each piece is independently testable (the protocols from Step 1 are the
seams). **STOP after the cycle is broken if the split risks
destabilizing** — the cycle-break is the high-value part; the split is
secondary.

**Verify**: `xcodebuild test ...` → exit 0.

### Step 5: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` → no leftover diffs.

## Test plan

- All plan 015/016/022 tests must still pass (the safety net).
- Add tests asserting the protocol seams work (a fake `AssignmentSource`
  in `MenuBarItemManager` tests; a fake `SectionOrdering` in
  `SimpleItemHider` tests) — these are the proof the cycle is broken.
- Verification: `xcodebuild test ...` → all pass.

## Done criteria

- [ ] `AssignmentSource` and `SectionOrdering` protocols exist.
- [ ] `MenuBarItemManager` calls `AssignmentSource` (no direct `simpleItemHider` internals).
- [ ] `SimpleItemHider` calls `SectionOrdering` (no direct `itemManager` internals).
- [ ] The 9 + 5 call sites are routed through protocols.
- [ ] All plan 015/016/022 tests still pass.
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- A call site uses a `simpleItemHider` (or `itemManager`) method that
  doesn't fit either protocol and forcing it would leak internals —
  STOP and report; do not bloat a protocol to break the cycle.
- Tests go red in a way that indicates the refactor changed behavior —
  revert and report; do not "fix" tests to match a broken refactor.
- The split in Step 4 is destabilizing — abandon Step 4 (the cycle-break
  in Steps 1-3 is the value); mark Step 4 as deferred.

## Maintenance notes

- The protocols are the long-term seam — future macOS-28 hiding work
  should depend on them, not on concrete classes.
- A reviewer should confirm NO new `appState.menuBarManager.simpleItemHider`
  or `appState.itemManager` direct-internal calls were introduced (grep
  the two files after the refactor).
- This is the riskiest plan in the set; a reviewer should scrutinize
  every protocol method for whether it truly belongs on that protocol
  (don't let `AssignmentSource` become a god-protocol).
