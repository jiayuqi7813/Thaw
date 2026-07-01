# Plan 024: Split `MenuBarOverlayPanel` into lifecycle, validation, and shape-renderer

> **Executor instructions**: This is a **refactor** with no current test
> seam. Step 1 below adds overlay shape snapshot tests FIRST so the
> extraction has a safety net; do not skip it.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/MenuBar/Appearance/MenuBarOverlayPanel.swift"`
> If the file changed since this plan was written, re-read the cited
> sections before proceeding.

## Status

- **Priority**: P3
- **Effort**: L
- **Risk**: MED
- **Depends on**: none (Step 1 adds the snapshot safety net inline)
- **Category**: tech-debt
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

`MenuBarOverlayPanel` is a single `final class` spanning 1902 lines
(+571 on this branch) accumulating three unrelated responsibilities:
panel lifecycle (`:637` show, `:685` scheduleShowRetry, `:725`
updateWindowLevel), validation (`:590` validate, `:584` insertUpdateFlag),
AX-refresh scheduling (`:1000` scheduleAXItemBoundsRefresh, `:1058`
updateCachedItemWindows, `:1083` scheduleItemWindowsConfirmation), and
three shape renderers (`:1225` pathForNotchShape, `:1310` pathForFullShape,
`:1461` pathForSplitShape, plus drawTint/updateBackgroundGlass/drawBackground/
drawBackgroundShadow/drawBackgroundBorder). Any visual-lifecycle bug fixed
in the path code also reads as touching validation and AX scheduling —
there's no cohesive unit small enough to characterize with a test. The
file has zero direct tests.

## Current state

`Thaw/MenuBar/Appearance/MenuBarOverlayPanel.swift` (1902 lines):
- `:219` — single `final class MenuBarOverlayPanel`.
- `:584-740` — validation (`validate(for:with:)`, `insertUpdateFlag`).
- `:637-725` — lifecycle (show, scheduleShowRetry, updateWindowLevel).
- `:798-801` — the AX-refresh justification comment.
- `:910-1055` — sinks + `scheduleAXItemBoundsRefresh`/`updateCachedItemWindows`/`scheduleItemWindowsConfirmation`.
- `:1144-1788` — three `pathFor…Shape` methods + draw methods.

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/MenuBar/Appearance/MenuBarOverlayPanel.swift` (slim down)
- New files:
  - `Thaw/MenuBar/Appearance/OverlayShapeRenderer.swift`
  - `Thaw/MenuBar/Appearance/OverlayValidationCoordinator.swift` (optional — see Step 2)

**Out of scope**:
- Do NOT change the rendering output (paths, draws) — only move them.
- Do NOT change the AX-refresh scheduling behavior (plan 008 handles dedupe).
- Do NOT touch `MenuBarAppearanceManager`.

## Git workflow

- Branch: `advisor/024-menubaroverlaypanel-split`
- Commit style: `refactor(overlay): extract OverlayShapeRenderer from MenuBarOverlayPanel`
- Commit in small, test-passing steps.

## Steps

### Step 0: Add overlay shape snapshot tests (the safety net)

Before extracting anything, add `ThawTests/MenuBarOverlayPanelShapeTests.swift`
with snapshot-style tests for the three `pathFor…Shape` methods
(`:1225`, `:1310`, `:1461`). Construct fixture `OverlayGeometry` inputs
(notch bounds, full bounds, split bounds) and assert the returned `NSBezierPath`/`CGPath`
matches a recorded reference (use the repo's existing snapshot-test
pattern — check `ThawTests/AdvancedSettingsSnapshotTests.swift` and
`ThawTests/GeneralSettingsSnapshotTests.swift` for the convention). If
the repo has no snapshot infra for paths, assert structural invariants
(path bounding box, element count) instead. These tests are the
regression catch for Step 1's extraction.

**Verify**: `xcodebuild test ...` → exit 0, snapshot tests pass and record baseline.

### Step 1: Extract `OverlayShapeRenderer` (the pure-CG part)

Move the three `pathFor…Shape` methods (`:1225`, `:1310`, `:1461`) and
the draw methods (`drawTint`, `updateBackgroundGlass`, `drawBackground`,
`drawBackgroundShadow`, `drawBackgroundBorder`) into a new value-typed
`OverlayShapeRenderer` whose input is a small `OverlayGeometry` struct
(bounds, notch, tint, border config). `MenuBarOverlayPanel` constructs an
`OverlayGeometry` and calls the renderer. The renderer is pure CG — easy
to snapshot-test.

Read each `pathFor…Shape` first to identify its inputs (bounds, screen
notch geometry, appearance config) and capture them in `OverlayGeometry`.

**Verify**: build → exit 0; existing tests pass; manually confirm the overlay still renders identical shapes (visual diff on macOS 27).

### Step 2: (Optional) Extract `OverlayValidationCoordinator`

If the validation methods (`:584-740`) are cohesive, extract them into an
`OverlayValidationCoordinator`. If they're tightly coupled to panel
state, leave them in `MenuBarOverlayPanel` and note as deferred.

**Verify**: build → exit 0.

### Step 3: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` → no leftover diffs.

## Test plan

- Step 0 adds `ThawTests/MenuBarOverlayPanelShapeTests.swift` (snapshot
  or structural-invariant tests for the three shapes) — the safety net.
- Verification gate: the existing suite + the new shape tests + a manual
  visual diff (render before/after on macOS 27 and compare the menu bar
  shape pixel-for-pixel).

## Done criteria

- [ ] `OverlayShapeRenderer` exists; the three `pathFor…Shape` + draw methods live there.
- [ ] `MenuBarOverlayPanel` is below ~1200 lines (the renderer extraction removes ~600).
- [ ] `ThawTests/MenuBarOverlayPanelShapeTests.swift` exists and passes (Step 0 safety net).
- [ ] The overlay renders identically (manual visual diff on macOS 27).
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- The `pathFor…Shape` methods read panel state that can't be captured in
  a value-typed `OverlayGeometry` without a large refactor — extract only
  what's cleanly movable; report the rest as deferred.
- A manual visual diff shows ANY pixel difference in the rendered shape —
  the extraction changed behavior; revert and report.
- The existing suite goes red — revert and report.

## Maintenance notes

- `OverlayShapeRenderer` is the unit the Step 0 snapshot tests target — keep it pure (no panel state).
- A reviewer should do the manual visual diff: the shapes are the
  user-visible feature; a regression here is immediately noticeable.
- Coordinate with plan 008 (AX-walk dedupe) and plan 009 (probe gating):
  those touch the AX-refresh/lifecycle parts that remain in
  `MenuBarOverlayPanel` after this extraction.
