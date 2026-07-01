# Plan 026: Surface an in-app "hiding unsupported" state when the private Assessment Mode API is unavailable

> **Executor instructions**: Follow this plan step by step.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/MenuBar/HiddenSectionPatch/ThawAssessmentModeHiding.h" "Thaw/MenuBar/HiddenSectionPatch/ThawAssessmentModeHiding.m" "Thaw/MenuBar/HiddenSectionPatch/AssessmentModeBackend.swift"`
> If any in-scope file changed since this plan was written, re-read the cited lines.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: deps (forward-compat observability)
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

The branch's defining feature — hiding menu bar items on macOS 27 —
rides on the private `MenuBarClientCore` framework's `MBAssessmentModeAssertion`
class (resolved via `NSClassFromString`, `dlopen`'d from a hardcoded
path). `ThawAssessmentModeHiding.m:30-31,39,51-52`. The defensive
`@try/@catch` + `NSClassFromString` means a rename/removal in a macOS
27.x point release or macOS 28 degrades to "hiding silently unavailable"
— `AssessmentModeBackend.isAvailable` returns `false`, the backend is
inert, and NOTHING is hidden. Users would see the feature vanish with no
in-app explanation (items they assigned Hidden would just stay visible;
the layout bars would show assignments that don't take effect).

(Notarization is NOT the issue — Developer ID notarization does not
reject private-API usage; that's an App Store review gate. The cost here
is forward-compat, not signing.)

## Current state

- `ThawAssessmentModeHiding.h/.m` — the bridge; `ThawAssessmentModeHidingAvailable()`
  returns `BOOL`.
- `AssessmentModeBackend.swift:36-38` — `static var isAvailable: Bool { ThawAssessmentModeHidingAvailable() }`.
- `AssessmentModeBackend`'s `apply` early-returns / is inert when
  unavailable (the class doc at `:31-32` says "When the private API is
  unavailable this backend is simply inert; there is no fallback.").
- No in-app UI surfaces "hiding is unavailable on this build."

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/MenuBar/HiddenSectionPatch/AssessmentModeBackend.swift` (expose an availability state)
- `Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift` (surface the state)
- `Thaw/Settings/SettingsPanes/AdvancedSettingsPane.swift` or a callout (show the warning) — pick the most visible non-modal surface; `SettingsWarningPill.swift` (new on this branch) is a candidate UI component.
- `Thaw/Resources/Localizable.xcstrings` (add a string — note: translations are managed via Crowdin, so add the English string only; do NOT add translations).

**Out of scope**:
- Do NOT replace the private API (there's no public alternative per the header comment).
- Do NOT add telemetry that phones home (local diagnostic logging only).
- Do NOT block the app from launching when unavailable — just inform.

## Git workflow

- Branch: `advisor/026-assessmentmode-unavailability-telemetry`
- Commit style: `feat(hider): surface in-app warning when Assessment Mode hiding is unavailable`

## Steps

### Step 1: Expose availability as an observable state

In `AssessmentModeBackend` (or `SimpleItemHider`), add an
`@Published var isHidingAvailable: Bool` initialized from
`AssessmentModeBackend.isAvailable`, checked at init and on
`NSApplication.didBecomeActiveNotification` (an OS update could land
while the app runs — re-check on activation).

### Step 2: Surface a non-modal warning when unavailable

When `isHidingAvailable == false` on macOS 27+, show a
`SettingsWarningPill`-style callout in the Advanced settings pane (and
optionally a one-time `os_log`/`DiagLog.error` at launch) stating:
"Hiding is unavailable on this macOS build (the required system
capability was not found). Reordering still works; hiding does not."
Match the existing `SettingsWarningPill` usage (read
`Thaw/UI/Views/SettingsWarningPill.swift` and find its existing call
sites to mirror the pattern).

### Step 3: Add a CI smoke assertion (if feasible)

If CI can assert at build time that the classes resolve on the
`Xcode_26.5`/macOS 26 runner, add a test that calls
`ThawAssessmentModeHidingAvailable()` and asserts `true` on macOS 26+
(or `false` on a stub — whatever the runner reports). The goal: catch a
rename before release. If the runner can't `dlopen` the private
framework (it's in the shared cache, may not be present in CI's
macOS-26-image), skip this and note it.

**Verify**: `xcodebuild test ...` → exit 0.

### Step 4: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` clean.

## Test plan

- A unit test asserting `SimpleItemHider.isHidingAvailable` reflects
  `AssessmentModeBackend.isAvailable` (injectable via plan 016's seam).
- Verification: `xcodebuild test ...` → pass.

## Done criteria

- [ ] `isHidingAvailable` is observable and re-checked on app activation.
- [ ] A non-modal warning shows in Advanced settings when unavailable on macOS 27+.
- [ ] `DiagLog.error` fires once at launch when unavailable.
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- `SettingsWarningPill` is not a reusable component (it's hardcoded for
  a specific warning) — adapt to the live component or ask the
  maintainer for the intended surface.
- The CI runner can't `dlopen` `MenuBarClientCore` (likely, on macOS 26
  CI) — skip Step 3's smoke test and note it; don't block.
- Showing a warning on every macOS 26 build (where the API is
  legitimately absent because the feature is macOS-27-only) would be
  wrong — gate the warning to macOS 27+ ONLY (`if #available(macOS 27, *)`).

## Maintenance notes

- When macOS 28 renames the class, this warning is what tells the user
  why hiding stopped working — keep the message actionable (point to the
  Thaw issue/release notes).
- A reviewer should confirm the warning is macOS-27-only (not shown on
  26 where the feature is correctly absent).
- Coordinate with plan 029 (experimental-flags graduation): if hiding
  becomes "supported" rather than "experimental," the warning's tone
  should shift from "experimental" to "unsupported on this build."
