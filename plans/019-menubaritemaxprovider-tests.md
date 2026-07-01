# Plan 019: Add tests for `MenuBarItemAXProvider` enumeration and assembly

> **Executor instructions**: Follow this plan step by step.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/MenuBar/MenuBarItems/MenuBarItemAXProvider.swift"`
> If the file changed since this plan was written, re-read the cited lines.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

`MenuBarItemAXProvider` is the ONLY way to discover items on macOS 27
(its doc comment at `:11-18` says so — the legacy CGS window-list path is
gone). Bugs in instance-index assignment or the overflow-placeholder skip
(`:133-138`) produce duplicate `uniqueIdentifier`s (overwriting persisted
assignments) or item loss. The `assemble` function (`:196`) and the
enumeration body have no coverage; the synthetic-window-ID generation
(`:209`) and the iteration-then-fallback-title bump (`:86-126`) have
never been characterized. The only tests (`MenuBarItemTagTests.swift:1689-1702`,
`:800-922`) cover `namespace(forBundleIdentifier:)` and `identityTitle(...)`
statics — reachable only because they happen to also be pure helpers.

## Current state

`Thaw/MenuBar/MenuBarItems/MenuBarItemAXProvider.swift`:
- `:49` — `menuBarItems(on:option:)` (the full AX walk).
- `:86-126` — enumeration body with iteration-then-fallback-title bump.
- `:133-138` — native-overflow-placeholder skip path.
- `:196` — `assemble` (instance index assignment, `syntheticWindowID`, sort left-to-right).
- `:209` — synthetic-window-ID generation.
- Inputs come straight from `AXHelpers`/`NSWorkspace.shared.runningApplications` with no injectable seam.

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/MenuBar/MenuBarItems/MenuBarItemAXProvider.swift` (extract `assemble`
  to take `raw: [RawItem]`; make `RawItem` test-constructible; do NOT
  change the runtime enumeration)
- `ThawTests/MenuBarItemAXProviderTests.swift` (create)

**Out of scope**:
- Do NOT test the live AX walk itself (it needs real running apps); test
  `assemble` with fixture `RawItem`s.
- Do NOT change `namespace(forBundleIdentifier:)` or `identityTitle(...)`
  (they're already tested).

## Git workflow

- Branch: `advisor/019-menubaritemaxprovider-tests`
- Commit style: `test(ax): characterize MenuBarItemAXProvider assembly and index assignment`

## Steps

### Step 1: Make `assemble` and `RawItem` testable

Read `MenuBarItemAXProvider.swift:196`+ to see `assemble`'s current
signature and the `RawItem` type. If `assemble` already takes `raw: [RawItem]`
as a parameter, make `RawItem` test-constructible (its properties may be
internal/private — expose an `init` for tests). If `assemble` is a method
that does its own enumeration, extract the assembly into a `static func`
taking `raw: [RawItem]` and the display/option, and have the live
`menuBarItems(on:option:)` call it.

**Verify**: build → exit 0; existing behavior unchanged.

### Step 2: Create `ThawTests/MenuBarItemAXProviderTests.swift`

Test cases (construct `RawItem` fixtures, call `assemble`, assert the
returned `[MenuBarItem]`):
1. `testAssemble_AssignsIncrementalInstanceIndexPerNamespace` — two items
   with the same `(namespace, title)` → get distinct `uniqueIdentifier`s
   (instance index 0 and 1).
2. `testAssemble_DuplicateNamespaceTitleHandled` — duplicates don't
   overwrite (the index disambiguates).
3. `testAssemble_SkipsNativeOverflowPlaceholder` — a `RawItem` matching
   the overflow-placeholder signature (`:133-138`) is NOT in the result.
4. `testAssemble_SortsLeftToRight` — items with frames at x=100, x=50,
   x=200 → returned in x=50, 100, 200 order.
5. `testAssemble_SyntheticWindowIDStable` — two `assemble` calls with the
   same raw inputs produce the same `syntheticWindowID` for the same item
   (read the generation at `:209` to confirm determinism).
6. `testAssemble_FallbackTitleBump` — an item whose first title is empty
   gets the iteration-then-fallback title (`:86-126`) — assert the
   bumped title appears.

**Verify**: `xcodebuild test ...` → exit 0, 6 new tests pass.

### Step 3: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` → no leftover diffs.

## Test plan

- 6 new tests in `ThawTests/MenuBarItemAXProviderTests.swift` (listed in Step 2).
- Verification: `xcodebuild test ...` → all pass including the 6 new tests.

## Done criteria

- [ ] `assemble` is a static func taking `raw: [RawItem]`; `RawItem` is test-constructible.
- [ ] `ThawTests/MenuBarItemAXProviderTests.swift` exists with the 6 cases, all passing.
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- `assemble` can't be extracted without pulling in the live AX
  enumeration (it's deeply intertwined) — report; a larger refactor may
  be needed. Do not half-extract.
- `RawItem` contains non-Sendable / AX-`UIElement` referents that can't
  be faked — then `assemble`'s pure logic (index assignment, sort,
  synthetic-window-ID) must be extracted to operate on plain structs;
  report and adapt.
- `syntheticWindowID` generation (`:209`) is non-deterministic (e.g.
  uses a global counter) — then test 5 is wrong; assert the ID is unique
  instead of stable, and report the non-determinism as a separate finding.

## Maintenance notes

- The `assemble` extraction is the seam a future live-AX integration test
  would use — keep it clean.
- A reviewer should confirm `menuBarItems(on:option:)` still calls the
  extracted `assemble` with the real enumerated `RawItem`s.
