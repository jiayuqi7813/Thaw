# Plan 028: Graduate or retire the three `enableExperimental*` flags

> **Executor instructions**: This is a **decision + graduation** plan.
> For each flag, add characterization tests, then either drop the
> `Experimental` prefix (graduate) or remove the flag (retire). The
> maintainer makes the call per flag.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/Utilities/Defaults.swift" "Thaw/Settings/SettingsSearchIndex.swift" "Thaw/MenuBar/HiddenSectionPatch/CGSWindowHider.swift" "Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift" "Thaw/MenuBar/HiddenSectionPatch/AXItemHider.swift"`
> If any in-scope file changed since this plan was written, re-read.

## Status

- **Priority**: P3
- **Effort**: S-M
- **Risk**: MED
- **Depends on**: plan 012 (AXItemHider gate-out), plan 014 (overflowBase fix), plan 016 (SimpleItemHider tests)
- **Category**: direction (tech-debt resolution)
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

Three experimental flags (`Thaw/Utilities/Defaults.swift:185-187`):
`enableExperimentalSystemItemHiding`,
`enableExperimentalWindowHiding`,
`enableExperimentalOverflowPrevention` — all default `false`. The
"experimental" label is masking that two of three are the only mechanism
for whole classes of macOS 27 behavior (system-item hiding; notched-
display overflow prevention), and the third (CGS window hiding) is the
documented fix for the iStat-ghosting collateral
(`CGSWindowHider.swift:11-31`). Users who would benefit can't discover
`enableExperimentalWindowHiding` — it's excluded from settings search
(`SettingsSearchIndex.swift:61-67` `nonSearchableProperties`). And
`AXItemHider` (under the system-item-hiding flag's umbrella) is a known
no-op on macOS 27 (plan 012 gates it out). The "experimental" posture
is incoherent: some experimental things are load-bearing production
mechanisms, others are dead. This plan forces a decision per flag.

## Current state

- `Defaults.swift:185-187` — the three flags (default `false`).
- `SettingsSearchIndex.swift:61-67` — `enableExperimentalWindowHiding`
  in `nonSearchableProperties` (excluded from search).
- `CGSWindowHider.swift:11-31` — the documented iStat-ghosting fix.
- `SimpleItemHider.swift:1058-1098` — `applyExperimentalOverflowPreventionIfEnabled` (real production position-weight writes).
- `SimpleItemHider.swift:101-103` — `AXItemHider` no-op admission (gated out by plan 012).

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope** (per-flag decisions):
- `Thaw/Utilities/Defaults.swift`
- `Thaw/Settings/SettingsSearchIndex.swift`
- `Thaw/Settings/Models/AdvancedSettings.swift` (the flag's settings surface)
- `Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift` (rename method names if graduating)
- `Thaw/Resources/Localizable.xcstrings` (English string for renamed setting — no translations)

**Out of scope**:
- Do NOT change the underlying mechanisms' behavior (plans 012, 014 handle the bugs).
- Do NOT graduate a flag whose characterization test fails on macOS 27 GM — leave it experimental and note why.

## Git workflow

- Branch: `advisor/028-experimental-flags-graduation`
- Commit style: `chore(hider): graduate enableExperimental* flags after characterization`

## Steps

### Step 1: For each flag, add a characterization test

Using plan 016's SimpleItemHider injection seam, add a test per flag
asserting the documented behavior:
- `enableExperimentalWindowHiding`: with the flag on, hidden items'
  windows are moved off-screen via CGS (assert the fake `CGSWindowHider.apply`
  is called with the right PIDs).
- `enableExperimentalOverflowPrevention`: with the flag on, hidden items
  get position weights ≥ 50000 (assert via the injected
  `TrailingItemPositionStore`).
- `enableExperimentalSystemItemHiding`: with the flag on, system items
  assigned Hidden are concealed via their `MBSystemItemIdentifier`
  (assert via the backend's `concealedSystemItemIDs`).

**Verify**: `xcodebuild test ...` → exit 0, characterization tests pass on macOS 27 GM. If any FAILS, that flag is NOT ready to graduate — leave it experimental and note the failure.

### Step 2: Per flag, graduate or retire (maintainer decision)

For each flag where the characterization test PASSES on macOS 27 GM:
- Graduate: rename `enableExperimentalX` → `enableX` across `Defaults`,
  `AdvancedSettings`, `SimpleItemHider`, `SettingsSearchIndex` (remove
  from `nonSearchableProperties`), and `SettingsURIHandler` (if mapped —
  see plan 003). Add a migration in `Defaults` so existing users'
  `enableExperimentalX = true` migrates to `enableX = true`.
- Update the settings UI label (drop "Experimental").

For each flag where the test FAILS or the mechanism is dead (e.g.
`AXItemHider` under system-item-hiding is a no-op per plan 012):
- Retire: remove the flag and its code path (coordinate with plan 012's
  AXItemHider gating). OR keep the flag but document honestly that it's
  inert on macOS 27.

**Record the per-flag decision in `plans/README.md`.**

### Step 3: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` clean.

## Test plan

- 3 characterization tests (Step 1) — one per flag.
- Verification: `xcodebuild test ...` → all pass.

## Done criteria

- [ ] 3 characterization tests exist (one per flag), passing on macOS 27 GM.
- [ ] Per-flag graduation/retirement decision is recorded in `plans/README.md`.
- [ ] Graduated flags: renamed, migrated, surfaced in settings search.
- [ ] Retired flags: removed (or documented inert).
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- A characterization test fails on macOS 27 GM — do NOT graduate that
  flag; leave it experimental and record the failure as a follow-up.
- Renaming a flag breaks the `Defaults` migration for existing users —
  the migration must preserve `true` values; if `Defaults` (the
  `Defaults` library) doesn't support key migration cleanly, ask the
  maintainer.
- The maintainer hasn't decided per-flag — STOP and present the
  characterization test results for a decision; do not graduate
  unilaterally.

## Maintenance notes

- Graduating a flag invites users onto a private-API path
  (`ThawAssessmentModeHidingActivate`) that may break on macOS point
  releases — coordinate with plan 026's unavailability warning so
  graduated flags degrade visibly, not silently.
- A reviewer (the maintainer) makes each per-flag call.
- When a flag is graduated, update `AGENTS.md`'s (plan 001) macOS 27
  invariants section to reflect the new supported surface.
