# Plan 025: Audit `AXSwift` for Swift 6 strict concurrency (or decide to vendor)

> **Executor instructions**: This is a **decision + audit** plan.
> Investigate, then either drop `@preconcurrency` imports in Thaw's 6
> files OR propose vendoring a thin in-tree wrapper. Do NOT start a
> large migration without maintainer approval.

> **Drift check (run first)**: `git diff --stat 87b0e507..HEAD -- Package.resolved` (or the resolved package)
> If the AXSwift pin changed since this plan was written, re-read it.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: migration
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

AXSwift is on the core Accessibility path (enumerating and hiding menu
bar items) and is pinned to `stonerl/AXSwift` @0.3.2 — a personal fork
of `tmandry/AXSwift` whose upstream last released in Sep 2021 (4+ years
stale, 14 open issues, 3 open PRs). Thaw is the sole maintainer of the
fork. Every Thaw file that imports it uses `@preconcurrency import AXSwift`
(`MenuBarItemManager.swift:9`, `AXItemHider.swift:9`,
`SimpleItemHider.swift:9`, `MenuBarItemService/SourcePIDCache.swift:9`,
`HIDEventManager.swift:9`, `Shared/Utilities/AXHelpers.swift:9`) — the
annotation that suppresses Swift 6 strict-concurrency/Sendable checks.
The suppression hides concurrency-safety bugs rather than resolving them.
Any macOS 27 Accessibility change is now Thaw's sole responsibility to
fix in a 2021 codebase.

## Current state

- `Thaw.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
  pins `stonerl/AXSwift` @0.3.2.
- 6 files: `@preconcurrency import AXSwift` (listed above).

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build | `xcodebuild build -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0 |
| Test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0 |

## Scope

**In scope (investigation; code change only after Step 2 approval)**:
- The 6 `@preconcurrency import AXSwift` files (read-only audit first).
- Possibly the AXSwift fork's `Sources/` (if a Swift 6 concurrency pass
  is chosen — that's a separate repo/PR; out of scope here unless the
  maintainer directs).

**Out of scope**:
- Do NOT replace AXSwift with a different SPM dep without approval.
- Do NOT vendor a wrapper in this plan unless Step 2 chooses that path
  and the maintainer approves a follow-up plan.

## Git workflow

- Branch: `advisor/025-axswift-swift6-audit` (if any code change results)

## Steps

### Step 1: Audit Thaw's actual AXSwift surface

Read the 6 files and catalog the EXACT AXSwift API surface Thaw uses
(`UIElement`, `Application`, attribute accessors, `attributeIsSettable`,
etc.). The goal: know how thin a vendored wrapper could be. Report the
surface as a list.

### Step 2: Choose a path (present to maintainer)

Two options:
- **(A) Commit to the fork as canonical**: run a Swift 6 strict-concurrency
  pass over `stonerl/AXSwift`'s `Sources/` (a separate PR in that repo),
  then drop `@preconcurrency` from the 6 Thaw files and fix the resulting
  Sendable errors. This keeps the dep but makes its concurrency safety
  explicit.
- **(B) Vendor a thin in-tree wrapper**: the surface from Step 1 is
  small (a handful of AX calls). A thin `Thaw/Utilities/AXShim.swift`
  wrapping the raw `AXUIElement` C API could replace the dep entirely,
  removing the SPM dependency and the `@preconcurrency` suppression.

Present both with effort/risk estimates; the maintainer chooses. This
plan does NOT implement either without approval — record the decision in
`plans/README.md` and spawn a follow-up plan.

## Test plan

N/A — this is an investigation/decision plan. The output is the surface
catalog (Step 1) and the chosen path (Step 2).

## Done criteria

- [ ] Step 1's surface catalog is written into this file's "Findings" section.
- [ ] Step 2's recommendation is recorded, with the maintainer's choice.
- [ ] `plans/README.md` notes the decision and links the follow-up plan (if spawned).

## STOP conditions

- The AXSwift surface Thaw uses is larger than expected (e.g. it relies
  on AXSwift's Swift-idiomatic observers/KVO wrappers) — vendoring (B)
  is impractical; recommend (A). Report.
- The fork's `Sources/` have drifted from upstream in ways that make a
  Swift 6 concurrency pass risky — report; (B) may be the only safe path.

## Findings

**Step 1 — surface catalog** (audited 2026-07-01, all 6 `@preconcurrency import AXSwift` files plus `Shared/Utilities/AXHelpers.swift`, which is where nearly the entire surface is already funneled):

- `UIElement` — the struct wrapping a raw `AXUIElement`. Used as: a property type (`AXItemHider.swift:26` `[CGWindowID: UIElement]`), a return/parameter type throughout, and its `.element` raw handle is *already* reached into directly in two places (`AXHelpers.swift:36` `AXUIElementSetMessagingTimeout(app.element, 0.25)`; `AXHelpers.swift:127` `AXUIElementGetPid(element.element, &pid)`) — i.e. the code already bypasses AXSwift for the raw C API when AXSwift doesn't expose something.
- `Application` — a `UIElement` subclass; only constructed via `Application(runningApp: NSRunningApplication)` (`AXHelpers.swift:30`).
- `systemWideElement.elementAtPosition(Float, Float)` (`AXHelpers.swift:25`) — one call site.
- `.attribute(_:)` generic typed getter — used for `.extrasMenuBar`, `.menuBar`, `.enabled`, `.frame`, `.title`, `.identifier`, `.description`, `.role`, `.hidden` (via `setAttribute`) — all funneled through `AXHelpers.swift`.
- `.arrayAttribute(.children)` (`AXHelpers.swift:54`) — one call site (`children(for:)`).
- `.setAttribute(_:value:)` — 3 call sites in `AXItemHider.swift` (all `.hidden`).
- `.attributeIsSettable(_:)` — 1 call site (`AXItemHider.swift:181`).
- `.press()` — 1 call site (`AXHelpers.swift:136`), a convenience wrapper presumably around `AXUIElementPerformAction("AXPress")`.

**No AXObserver/KVO-notification wrapper usage exists anywhere in the 6 files** — grepped for `Observer`/`Notification` across all of them; the only `Observer` hit (`SourcePIDCache.swift:167`) is a doc-comment about observing `NSRunningApplication` via `NSWorkspace`, unrelated to AXSwift. This directly rules out the plan's stated risk condition for option (B) ("if it relies on AXSwift's Swift-idiomatic observers/KVO wrappers, vendoring is impractical") — that condition does not apply.

**Step 2 — recommendation**: the entire surface is ~9 primitives, already centralized behind `AXHelpers.swift`'s ~15 static methods, with zero use of AXSwift's higher-level observer/notification machinery, and the code already reaches past AXSwift for two raw-API needs. This is a small, mechanical, well-bounded surface. **Recommend option (B): vendor a thin in-tree `AXShim.swift`** wrapping `AXUIElementCopyAttributeValue`/`AXUIElementSetAttributeValue`/`AXUIElementIsAttributeSettable`/`AXUIElementPerformAction`/`AXUIElementCopyElementAtPosition`/`AXUIElementGetPid` directly, replacing `AXHelpers.swift`'s AXSwift-backed implementations with raw-API ones (same public method signatures, so all 6 call-site files need zero changes beyond the two `@preconcurrency import AXSwift` → plain import lines they'd drop). This removes the SPM dependency on a personal fork of a 4+-year-stale upstream, and removes the `@preconcurrency` suppression by construction (a from-scratch shim can be written Sendable-clean).

Option (A) (Swift 6 pass on the fork) is not recommended: it requires maintaining expertise in a second repo's build/release process for a surface this small, for no capability gain.

**This plan does NOT implement the vendoring** — per its own STOP instructions, that requires maintainer approval as a separate follow-up plan. Flagging to the maintainer for a go/no-go decision.

## Maintenance notes

- AXSwift is the single point of failure for macOS 27 AX enumeration;
  whichever path is chosen, the maintainer should be able to fix an
  Apple-side AX change within hours, not weeks.
- A reviewer (the maintainer) makes the final (A) vs (B) call.
