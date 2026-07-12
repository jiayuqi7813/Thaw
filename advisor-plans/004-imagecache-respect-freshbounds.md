# Plan 004: Make `MenuBarItemImageCache.captureImages` actually respect its `freshBounds` parameter

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md` — unless a reviewer dispatched you and told you
> they maintain the index.
>
> **Drift check (run first)**: `git diff --stat b41f1e96..HEAD -- Thaw/MenuBar/MenuBarItems/MenuBarItemImageCache.swift`
> If that file changed since this plan was written, compare the "Current
> state" excerpts below against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: MED (touches the macOS 27 menu-bar-icon capture hot path; a wrong
  bounds source can bring back blank/mismatched icon thumbnails)
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `b41f1e96`, 2026-07-11

## Why this matters

`MenuBarItemImageCache.captureImages(for:scale:appState:)` computes
`shouldUseFreshBounds` specifically so the **Visible** section can use its
own cache-cycle bounds instead of paying for an extra full AX enumeration —
the inline comment at the call site says exactly that: doing the extra walk
for Visible "can mismatch dynamic items and crop neighbors." But the private
overload it calls silently ignores the value it's handed
(`freshBounds _: Bool = false`), so on macOS 27 the live AX-bounds walk now
runs unconditionally for **every** section, including Visible, every capture
tick. This both burns extra AX/CPU work on every refresh and risks
reintroducing the exact "cropped across neighboring glyphs" bug class this
parameter existed to prevent for dynamic-title items (this project has an
open, unresolved bug of exactly that shape for one dynamic-title app). Fixing
this means the Visible section goes back to using each item's own already-
known `.bounds` instead of re-querying live AX bounds for the whole bar.

## Current state

- `Thaw/MenuBar/MenuBarItems/MenuBarItemImageCache.swift` — the private
  capture routine and its caller.

The private overload's signature discards the parameter (line 1159-1164):

```swift
private nonisolated func captureImages(
    of items: [MenuBarItem],
    scale: CGFloat,
    appState: AppState,
    freshBounds _: Bool = false
) async -> CaptureResult {
```

Inside the `#available(macOS 27, *)` branch (lines 1178-1229), the live-AX
path runs unconditionally — there is no reference to the (unused) parameter
anywhere in the function body:

```swift
if #available(macOS 27, *) {
    let displayID = await MainActor.run { ... }
    let screenFrame = await MainActor.run { ... }

    // Crop against FRESH live AX bounds, not cached `item.bounds`.
    // A reflowing MenuBarAgent item can keep stale snapshot bounds
    // long enough to crop across neighboring glyphs, which poisons
    // the cache with "half of two icons" thumbnails.
    let liveItems = await MenuBarItem.getMenuBarItems(option: [.onScreen, .activeSpace])
    let liveBoundsByID = Dictionary(
        liveItems.map { ($0.uniqueIdentifier, $0.bounds) },
        uniquingKeysWith: { first, _ in first }
    )

    var axItems: [(item: MenuBarItem, bounds: CGRect)] = []
    for item in capturable {
        guard let bounds = liveBoundsByID[item.uniqueIdentifier] else {
            ...
            continue
        }
        guard !bounds.isEmpty else { continue }
        if let screenFrame, !screenFrame.intersects(bounds) { continue }
        axItems.append((item: item, bounds: bounds))
    }

    guard !axItems.isEmpty else { ... return CaptureResult() }
    return await axBoundsCapture(axItems, scale: scale, displayID: displayID)
}
```

The caller (lines 1437-1464) computes the flag correctly but it's a no-op:

```swift
private func captureImages(
    for section: MenuBarSection.Name,
    scale: CGFloat,
    appState: AppState
) async -> [MenuBarItemTag: CapturedImage] {
    let items = await appState.itemManager.itemCache.managedItems(for: section)
    let revealedSection = await MainActor.run {
        appState.menuBarManager.sectionController?.revealedSection
    }
    let shouldUseFreshBounds = Self.shouldUseFreshBounds(
        for: section,
        revealedSection: revealedSection
    )
    if shouldUseFreshBounds {
        clearCaptureFailures(for: items)
    }
    let captureResult = await captureImages(
        of: items,
        scale: scale,
        appState: appState,
        // Revealed concealed sections need fresh AX bounds because cached
        // snapshot bounds are stale while MenuBarAgent temporarily publishes
        // their live glyphs. Visible uses its cache-cycle bounds: an extra
        // all-items AX walk can mismatch dynamic items and crop neighbors.
        freshBounds: shouldUseFreshBounds
    )
    ...
}
```

`MenuBarItem` (the struct in `items`) already carries its own `.bounds`
field — see `MenuBarModel/Sources/MenuBarModel/MenuBarItem.swift:31`
(`public let bounds: CGRect`) — populated from the cache cycle that produced
`items`. That's the value to fall back to when `freshBounds == false`; no new
data source is needed.

`Self.shouldUseFreshBounds(for:revealedSection:)` already exists in this file
(used at the call site above) — read its current definition before writing
the fix so the two conditions you're threading through stay consistent; don't
redefine the policy, only wire the existing decision through.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build + test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, all tests pass |
| Lint | `swiftlint --strict` | exit 0 |
| Format check | `swiftformat --lint .` | exit 0 (or run `swiftformat .` then re-check) |
| Grep for stray unused-param markers | `grep -n "freshBounds _:" Thaw/MenuBar/MenuBarItems/MenuBarItemImageCache.swift` | no matches after the fix |

## Scope

**In scope**:
- `Thaw/MenuBar/MenuBarItems/MenuBarItemImageCache.swift`
- `ThawTests/` — add/extend a test file for this behavior (create
  `ThawTests/MenuBarItemImageCacheFreshBoundsTests.swift` if no existing test
  file already targets this function; check first with
  `grep -rln "captureImages" ThawTests/` and extend an existing file instead
  if one already exercises this area)

**Out of scope**:
- `axBoundsCapture`, `individualCapture`, the macOS ≤26 branch below the
  `#available(macOS 27, *)` block — untouched, pre-existing, working code.
- `Self.shouldUseFreshBounds` itself — its policy (which sections get fresh
  bounds) is correct; only the plumbing that ignores its result is broken.
- Any other file in the diff (`MenuBarSectionController.swift`,
  `MenuBarAgentPreferencesWatcher.swift`, etc.) — separate plans cover those.

## Git workflow

- Branch: `advisor/004-imagecache-freshbounds` (create from current HEAD)
- One commit for the fix, following this repo's commit style (see
  `git log --oneline -10` for examples — imperative present tense,
  `type(scope): summary` prefix, e.g. `fix(capture): respect freshBounds flag
  in macOS 27 AX bounds capture`)
- Do NOT push or open a PR.

## Steps

### Step 1: Restore the `freshBounds` parameter and thread it through

In `captureImages(of:scale:appState:freshBounds:)`, change the parameter back
to a real, named, used argument (`freshBounds: Bool = false`, not `_:`).
Inside the `#available(macOS 27, *)` branch, branch on it:

- When `freshBounds` is `true`: keep the existing live-AX-walk behavior
  exactly as it is today (the `MenuBarItem.getMenuBarItems` call and
  `liveBoundsByID` lookup).
- When `freshBounds` is `false`: skip the live AX walk entirely. Build
  `axItems` directly from each item's own `.bounds` (from the `capturable`
  array passed in), applying the same `!bounds.isEmpty` and
  `screenFrame.intersects(bounds)` filtering that the live-bounds branch
  already does, so both branches produce the same `[(item: MenuBarItem,
  bounds: CGRect)]` shape before calling `axBoundsCapture`.

Do not change the off-screen filtering logic itself — only the *source* of
`bounds` (live re-fetch vs. `item.bounds`) should differ between the two
branches.

**Verify**: `grep -n "freshBounds: Bool" Thaw/MenuBar/MenuBarItems/MenuBarItemImageCache.swift`
→ one match, with no trailing `_:` anywhere in the file for this parameter.

### Step 2: Build and confirm no regressions

**Verify**: `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` → exit 0, all existing tests pass.

### Step 3: Add a regression test

Add a test that calls the private `captureImages(of:scale:appState:freshBounds:)`
overload (or, if it's not directly testable due to `private` access, add the
test at the level of `Self.shouldUseFreshBounds` plus a focused unit test that
constructs two `MenuBarItem` values with deliberately different cached vs.
"live" bounds and asserts that with `freshBounds: false` the cropped region
uses the item's own `.bounds`, not a re-fetched value). If full `SCStream`-
based capture can't run in the test environment (no screen-recording
permission in CI), the test may need to stub `ScreenCapture.captureMenuBarHostingWindowAsync`
or test only the bounds-selection logic in isolation — extract that
selection into a small `nonisolated static func` if that's what's needed to
make it unit-testable without a real capture. Follow the structure of
`ThawTests/MenuBarAgentPositionStoreTests.swift` or another XCTestCase in
`ThawTests/` for style (see file header convention below).

All new/changed Swift files need the repo's standard header:

```swift
//
//  <FILENAME>
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under GNU GPLv3
```

**Verify**: `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` → exit 0, new test(s) present and passing.

## Test plan

- New test: confirms that with `freshBounds: false`, capture bounds come from
  `item.bounds` (cached), not a live AX re-fetch.
- New test (or extend existing): confirms `freshBounds: true` still does the
  live re-fetch (guard against silently deleting the revealed-section
  behavior while fixing the Visible-section one).
- Model test structure after an existing `ThawTests/*.swift` file in the same
  area (`MenuBarItemManagerSignatureGateTests.swift` is a good structural
  example of testing a narrow piece of capture/cache logic in isolation).
- Verification: full test command above → all pass, including the new one(s).

## Done criteria

- [ ] `xcodebuild test ...` (command above) exits 0
- [ ] `swiftlint --strict` exits 0
- [ ] `grep -n "freshBounds _:" Thaw/MenuBar/MenuBarItems/MenuBarItemImageCache.swift` returns no matches
- [ ] A new or extended test exists that fails on the pre-fix code (verify by
      temporarily reverting the fix and confirming the test fails, then
      reapplying — do this locally before committing, don't leave the repo
      in the reverted state)
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `advisor-plans/README.md` status row for 004 updated

## STOP conditions

Stop and report back (do not improvise) if:

- The code at `MenuBarItemImageCache.swift` around lines 1159-1230 or
  1437-1464 doesn't match the excerpts above (drift).
- `Self.shouldUseFreshBounds` doesn't exist or has a materially different
  signature than implied here — re-read its actual definition and adjust the
  plan's assumption, but if its policy logic itself looks wrong, stop rather
  than changing it (out of scope for this plan).
- You cannot make the new logic testable without capturing a real screen (no
  screen-recording permission in the executor's environment) — in that case,
  implement the fix, get it building and passing existing tests, then report
  that test coverage for this specific plan had to be deferred and explain
  exactly what's untested and why.
- The fix requires touching `axBoundsCapture` itself — that's out of scope;
  stop and report what you found instead.

## Maintenance notes

- If a future change adds more capture-freshness policies beyond just
  Visible-vs-revealed, `Self.shouldUseFreshBounds` is the single place that
  should grow, not ad-hoc booleans threaded through call sites.
- A reviewer should scrutinize: does the `!freshBounds` branch actually skip
  the `MenuBarItem.getMenuBarItems` AX call (the whole point of the fix), or
  does it just relabel the same code path?
- This plan does not address the `scheduleCoalescedCacheRerun` signature-gate
  asymmetry noted during the advisor review — that was assessed as
  intentional/documented, not a defect, and is out of scope here.
