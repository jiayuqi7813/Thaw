# Plan 008: Dedupe the overlay panel's AX walk against the item manager's recent walk

> **Executor instructions**: Follow this plan step by step. This plan
> touches the visible hot path; read "STOP conditions" carefully.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/MenuBar/Appearance/MenuBarOverlayPanel.swift" "Thaw/MenuBar/MenuBarItems/MenuBarItemManager.swift"`
> If either file changed since this plan was written, re-read the cited
> lines before proceeding.

## Status

- **Priority**: P2
- **Effort**: S-M
- **Risk**: MED
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

`MenuBarOverlayPanel` sinks on `appState.itemManager.$itemCache`, every
section's `controlItem.$onScreenFrame`, and `simpleItemHider.$revealedSection`,
calling `scheduleAXItemBoundsRefresh()` on each (`:910-955`). That function
does `await MenuBarItem.getMenuBarItems(on: displayID, option: [.onScreen, .activeSpace])`
(`:1022-1025`) — a full synchronous AX round-trip to every running app.
But the item-cache refresh that triggered the sink already did the same AX
walk moments earlier (`MenuBarItemManager.swift:2471-2474`). So every
settled state change triggers a SECOND full AX walk just to refresh the
split-pill geometry. AX walks are the single most expensive thing this
code does. (A 200ms debounce collapses bursts, so this is +1 redundant
walk per settled change, not a storm — but still the most expensive
redundancy on the path.)

## Current state

`Thaw/MenuBar/Appearance/MenuBarOverlayPanel.swift`:
- `:930-939` — sink on `appState.itemManager.$itemCache` → `scheduleAXItemBoundsRefresh()`.
- `:910-923` — sink on each section's `controlItem.$onScreenFrame` → `scheduleAXItemBoundsRefresh()`.
- `:941-955` — sink on `simpleItemHider.$revealedSection` → `scheduleAXItemBoundsRefresh()`.
- `:1022-1025` — `scheduleAXItemBoundsRefresh` does `await MenuBarItem.getMenuBarItems(on: displayID, option: [.onScreen, .activeSpace])`.
- `:798-801` — comment justifying the re-walk: item-cache sections can't
  be used because "Apple items can remain physically visible while
  assigned Hidden, and concealed-item snapshots can retain stale on-screen
  bounds."

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/MenuBar/Appearance/MenuBarOverlayPanel.swift`
- `Thaw/MenuBar/MenuBarItems/MenuBarItemManager.swift` (only to EXPOSE the
  last-walk result + timestamp — minimal addition)

**Out of scope**:
- Do NOT change `MenuBarItem.getMenuBarItems` itself.
- Do NOT remove the overlay panel's own walk entirely — the `:798-801`
  comment is a real constraint (concealed items can retain stale bounds).
  The fallback to the panel's own walk must remain for the stale case.
- Do NOT change the 200ms debounce.

## Git workflow

- Branch: `advisor/008-overlaypanel-ax-walk-dedupe`
- Commit style: `perf(overlay): reuse item manager's recent AX walk when fresh`

## Steps

### Step 1: Expose the item manager's last AX walk result + timestamp

In `MenuBarItemManager`, add (near the `itemCache` property):
```swift
/// The on-screen items from the most recent `getMenuBarItems` walk, with
/// the walk's timestamp. Used by `MenuBarOverlayPanel` to avoid a second
/// full AX walk when the cache just refreshed.
@MainActor
var lastOnScreenMenuBarItems: ([MenuBarItem], ContinuousClock.Instant?)
```
Populate it wherever `getMenuBarItems` is called for the cache refresh
(around `:2471-2474`). Store the on-screen-filtered subset and `.now`.

If `getMenuBarItems` is called from multiple sites, populate
`lastOnScreenMenuBarItems` only at the cache-refresh site (the one that
already feeds `$itemCache`).

**Verify**: build → exit 0.

### Step 2: Have `scheduleAXItemBoundsRefresh` reuse the recent walk when fresh

In `MenuBarOverlayPanel.scheduleAXItemBoundsRefresh` (`:1022-1025`),
before doing its own `getMenuBarItems` walk, check
`appState.itemManager.lastOnScreenMenuBarItems`. If the timestamp is
within ~200ms of `.now`, use those items directly (filter to the display
if needed) and skip the walk. Otherwise, fall back to the existing
`getMenuBarItems` call.

```swift
let (recentItems, recentAt) = appState.itemManager.lastOnScreenMenuBarItems
let items: [MenuBarItem]
if let recentAt, recentAt.duration(to: .now) < .milliseconds(200) {
    items = recentItems.filter { /* on the target display */ }
} else {
    items = (await MenuBarItem.getMenuBarItems(on: displayID, option: [.onScreen, .activeSpace])) ?? []
}
```

The on-screen filter the overlay needs is a subset of what
`getMenuBarItems` already returned, so reusing is correct.

**Verify**: `xcodebuild test ...` → exit 0. Manually (if possible) confirm the overlay still renders correct split-pill geometry after a cache refresh — the reused items must include the on-screen items the overlay needs.

### Step 3: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` → no leftover diffs.

## Test plan

- No direct `MenuBarOverlayPanel` tests exist (it's UI). The verification
  gate is the existing suite + a manual visual check.
- A future snapshot test for the overlay (out of scope) would catch a
  regression here.

## Done criteria

- [ ] `MenuBarItemManager.lastOnScreenMenuBarItems` exists and is populated at the cache-refresh site.
- [ ] `scheduleAXItemBoundsRefresh` reuses it when fresher than ~200ms; falls back to its own walk otherwise.
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- The `:798-801` comment's constraint (concealed items with stale bounds)
  means the reused items are WRONG for the overlay's needs — if reusing
  the cache's on-screen items produces visibly wrong split-pill geometry,
  STOP. The win is narrower than "reuse the cache": the overlay needs
  items that are physically on-screen RIGHT NOW, which the cache's
  section buckets may not reflect. If so, abandon the reuse and instead
  just ensure the panel's walk is gated behind "panel actually visible"
  (a smaller win). Report which path you took.
- `MenuBarItem.getMenuBarItems` is called from so many sites that
  populating `lastOnScreenMenuBarItems` everywhere is impractical — limit
  to the cache-refresh site and report if other sites matter.
- Existing tests fail in a way that indicates the reused items are stale.

## Maintenance notes

- The 200ms freshness window must stay at or below the panel's debounce
  (also 200ms) — if the debounce changes, update the window.
- A reviewer should run the app on macOS 27, toggle a hidden section, and
  confirm the split-pill geometry is correct (no stale bounds) — this is
  the only reliable proof that the reuse is safe.
- If `getMenuBarItems` ever gains a notification-based change signal (the
  holy grail), this dedupe becomes unnecessary — revisit then.
