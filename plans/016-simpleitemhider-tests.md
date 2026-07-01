# Plan 016: Inject `SimpleItemHider`'s collaborators and characterize its lifecycle

> **Executor instructions**: Follow this plan step by step. This plan
> unblocks the god-object refactor (plan 024) and the ItemHider protocol
> (plan 022); do it before those.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift"`
> If the file changed since this plan was written, re-read the cited lines.

## Status

- **Priority**: P2
- **Effort**: L
- **Risk**: MED
- **Depends on**: plan 015 (AssessmentModeBackend pure helpers — `SimpleItemHider`'s instance tests need a fakeable backend)
- **Category**: tests
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

`SimpleItemHider` is the orchestrator that ties assignment → hidden items
(via `AssessmentModeBackend`, `ControlCenterModuleManager`,
`CGSWindowHider`, `AXItemHider`, `TrailingItemPositionStore`). Its
`refresh()` (`SimpleItemHider.swift:920`) is the 1Hz entry that drives the
whole pipeline; the mutators (`setSection` `:683`/`:728`, `show` `:419`,
`hideRevealedSections` `:457`, `revealItemTemporarily` `:469`,
`applyProfileLayout` `:799`) are the user-action paths. EVERY
`SimpleItemHider` test today lives inside `MenuBarItemTagTests.swift:925-1746`
and asserts **`static func`** inputs/outputs only
(`assignmentFromOrder`, `mergeMigratedSectionOrder`, `loadOrder`,
`effectiveSectionAssignment`, `persistableOrderIdentifiers`, `orderedItems`,
`isProtectedAssignmentItem`). The instance lifecycle is untested because
`init` hard-constructs all five collaborators (`:123-127`). The riskiest
integration point — where assignment becomes hidden items — is
characterized only at the leaves. This plan introduces injection so the
instance can be tested against fakes.

## Current state

`Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift`:
- `:115-127` — `init(appState:)` hard-constructs `backend`, `ccModuleManager`, `cgsWindowHider`, `axItemHider`, `positionStore`.
- `:920` — `refresh()` (the 1Hz entry).
- `:419-520` — `show` / `hideRevealedSections` / `revealItemTemporarily` / `scheduleTemporaryItemConceal` (with the `isAnyMenuBarItemMenuOpen` polling loop at `:501-519`).
- `:924-936` — invalid-assignment eviction in `refresh()`.
- `:1157-1260` — `applyExperimentalWindowHiding` multi-pass with stash stripping.

Existing exemplar for injection: `CGSWindowHider.init(environment:notificationCenter:)`
(`CGSWindowHider.swift:64-67`) and `ControlCenterModuleManager.init(environment:notificationCenter:)`
(`ControlCenterModuleManager.swift:121-124`).

Existing exemplar for the static-only tests: `MenuBarItemTagTests.swift:925-1746`.

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift` (add an
  injection initializer; keep the existing `init(appState:)` for
  production)
- `ThawTests/SimpleItemHiderTests.swift` (create)

**Out of scope**:
- Do NOT split `SimpleItemHider` into multiple classes (that's plan 024).
- Do NOT change the collaborators' interfaces (plan 022 defines the
  `ItemHider` protocol; this plan just injects the existing concrete
  types behind protocols so fakes can be passed).
- Do NOT remove the existing static-helper tests in `MenuBarItemTagTests.swift`.

## Git workflow

- Branch: `advisor/016-simpleitemhider-tests`
- Commit style: `test(hider): inject SimpleItemHider collaborators and characterize refresh/lifecycle`

## Steps

### Step 1: Define minimal protocols for the five collaborators

`SimpleItemHider` needs to call into its collaborators' `apply`/`restoreAll`
methods. Define `@MainActor` protocols matching the subset of each
collaborator's interface that `SimpleItemHider` actually uses, e.g.:

```swift
@MainActor
protocol AssessmentModeBackending: AnyObject {
    func apply(sectionAssignment: [String: MenuBarSection.Name], allItems: [MenuBarItem]) -> Bool
    func pulse(sectionAssignment: [String: MenuBarSection.Name], allItems: [MenuBarItem]) -> Bool
    func markExternallyTornDown()  // if plan 013 landed; else omit
    static var isAvailable: Bool { get }
}
```
Conform `AssessmentModeBackend` to it (it already has these methods). Do
the same for `ControlCenterModuleManagering`, `CGSWindowHidering`,
`AXItemHidering` (minimal `apply`/`restoreAll`), and
`TrailingItemPositionStoring` (`lockVisiblePositions`/`hideItems`/`showItems`/`restoreAll`/`readPositions`/`writePositions`/`hasHiddenItems`).

**STOP condition**: if any collaborator's method used by `SimpleItemHider`
has a signature that doesn't fit a clean protocol (e.g. returns a
non-Sendable type), report and adapt — do not force a wrong shape.

**Verify**: build → exit 0 (production `init(appState:)` still works; conformances are additive).

### Step 2: Add an injection initializer

Add:
```swift
init(
    appState: AppState?,
    backend: AssessmentModeBackending,
    ccModuleManager: ControlCenterModuleManagering,
    cgsWindowHider: CGSWindowHidering,
    axItemHider: AXItemHidering,
    positionStore: TrailingItemPositionStoring
) {
    self.appState = appState
    self.backend = backend as! AssessmentModeBackend  // SEE STOP CONDITION
    ...
}
```

**STOP condition**: the `as!` above is wrong if the stored property type
must change. The cleaner approach: change the stored property types to
the protocols (`private let backend: AssessmentModeBackending`), and
update all call sites in `SimpleItemHider` to use the protocol methods.
If that causes widespread changes, do it — it's the point of the seam.
Keep the production `init(appState:)` constructing the real concrete
types (which conform). Do NOT use `as!` force-casts.

**Verify**: build → exit 0; existing tests pass.

### Step 3: Create `ThawTests/SimpleItemHiderTests.swift` with fakes

Model on `ThawTests/MenuBarAgentPositionStoreTests.swift` (read its
`@MainActor` + fake-`Environment` pattern — it already does injection).
Build small fake implementations of each protocol (counting `apply` calls,
returning canned handled-PID sets).

Test cases:
1. `testRefresh_EmptyItemCacheKeepsCurrentRestriction` — seed a hidden
   assignment, pass `allItems: []` to `refresh()`, assert the backend's
   `apply` was NOT called with the empty-allItems concealing path (the
   empty-cache guard). (Coordinate with plan 015's `resolveConcealment` —
   the guard is in `apply`.)
2. `testRefresh_EvictsInvalidAssignments` — seed an assignment whose
   identifiers aren't in `allItems`, call `refresh()`, assert they're
   evicted from `sectionAssignment`.
3. `testRevealItemTemporarily_ConcealsAfterDelay` — call
   `revealItemTemporarily`, assert the item is in
   `temporarilyRevealedIDs` and a conceal `Task` was scheduled; advance
   the clock / cancel the task and assert concealment.
4. `testShow_RevealsOnlyRequestedSection` — call `show(.hidden)`, assert
   `revealedSection == .hidden` and the backend's allowlist was
   recomputed.
5. `testSetSection_PersistsAndRefreshes` — call `setSection(.hidden, for: id)`,
   assert `sectionAssignment[id] == .hidden` and `refresh()` ran.
6. `testHideRevealedSections_ClearsReveal` — after `show(.hidden)`, call
   `hideRevealedSections`, assert `revealedSection == nil`.

**Verify**: `xcodebuild test ...` → exit 0, 6 new tests pass.

### Step 4: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` → no leftover diffs (incl. copyright header on new files).

## Test plan

- 6 new tests in `ThawTests/SimpleItemHiderTests.swift` (listed in Step 3).
- Fakes modeled on `MenuBarAgentPositionStoreTests.swift`'s injection pattern.
- Verification: `xcodebuild test ...` → all pass including the 6 new tests.

## Done criteria

- [ ] Five `@MainActor` protocols exist; the concrete collaborators conform.
- [ ] `SimpleItemHider` has an injection initializer; stored properties use the protocols.
- [ ] Production `init(appState:)` still constructs real collaborators.
- [ ] `ThawTests/SimpleItemHiderTests.swift` exists with the 6 cases, all passing.
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- Changing stored property types to protocols causes widespread call-site
  changes in `SimpleItemHider` (the file is 1466 lines) — if it's more
  than mechanical, STOP and report; do not half-migrate. The injection
  initializer is the value; the stored-property-type change is the means.
- A collaborator's interface can't be captured in a clean protocol —
  report which one and adapt.
- The existing static-helper tests in `MenuBarItemTagTests.swift` break —
  do not loosen them; the extraction must be behavior-preserving.

## Maintenance notes

- The protocols are the seam plan 022 (ItemHider protocol) will refine —
  keep them minimal and aligned with the eventual unified `ItemHider`
  shape where possible.
- A reviewer should confirm the production `init(appState:)` still
  constructs the REAL collaborators (not fakes) — a misroute here would
  make hiding inert in production.
- When `refresh()` gains a short-circuit (plan 006), add a test asserting
  the second `refresh()` with unchanged inputs doesn't re-call the
  backend.
