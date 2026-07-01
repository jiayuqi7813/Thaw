# Plan 010: Memoize `isParkedOffMenuBarBand` within a repair pass

> **Executor instructions**: Follow this plan step by step.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/MenuBar/MenuBarItems/MenuBarItem.swift" "Thaw/MenuBar/MenuBarItems/MenuBarItemManager.swift"`
> If either file changed since this plan was written, re-read the cited lines.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

`MenuBarItem.isParkedOffMenuBarBand(among:)` (`:141-159`) does
`peers.first(where:…)` twice (O(N)) per call to find the bar midY.
`MenuBarItemManager.repairVisibleLayoutAfterRestrictionChange` calls it
3-5 times per pass via separate `filter` calls (`:602-603`, `:626-630`,
`:664-668`, `:691-696`), recomputing the same parked-ness for the same
items within one pass — and the whole function re-enters in a 4× retry
loop (`:559-563`). So each repair does ~3-5 O(N·N) traversals, paid 4×.
Sub-millisecond per pass in absolute terms, but pure waste: an item's
parked-ness doesn't change across the three filters within one pass, and
`barMidY` is identical for every call within a pass.

## Current state

`Thaw/MenuBar/MenuBarItems/MenuBarItem.swift:141-159` —
`isParkedOffMenuBarBand(among:)` (O(N) per call).

`Thaw/MenuBar/MenuBarItems/MenuBarItemManager.swift`:
- `:559-563` — `noteRestrictionChange` re-enters
  `repairVisibleLayoutAfterRestrictionChange` in a retry loop (up to 4 polls).
- `:602-603` — `prePulseParked` and `prePulseOnBand` are two separate
  `filter` passes over `pulseCandidates` that each call
  `isParkedOffMenuBarBand(among: liveItems)` per candidate — parked-ness
  computed twice for the same items in the same pass.
- `:626-630` — `parkedVisible` recomputes `isParkedOffMenuBarBand` over
  `liveItems` again.
- `:664-668`, `:691-696` — `afterItems` filters recompute it twice more
  in the post-pulse check.

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/MenuBar/MenuBarItems/MenuBarItem.swift`
- `Thaw/MenuBar/MenuBarItems/MenuBarItemManager.swift`

**Out of scope**:
- Do NOT change the retry loop (`:559-563`) — its retry semantics are
  load-bearing for restriction-change settling.
- Do NOT change the `filter` structure beyond swapping the per-item
  predicate for set membership.

## Git workflow

- Branch: `advisor/010-isparkedoffmenubarband-memoize`
- Commit style: `perf(layout): memoize parked-item set per repair pass`

## Steps

### Step 1: Add a helper that derives the parked-item set + barMidY once per snapshot

In `MenuBarItemManager`, add a small private helper (near
`repairVisibleLayoutAfterRestrictionChange`) that, given a snapshot of
`liveItems`, computes once:
- `barMidY: CGFloat?` — the menu bar midY (the value
  `isParkedOffMenuBarBand` derives via `peers.first(where:)`).
- `parkedIDs: Set<CGWindowID>` — the set of item windowIDs whose midY is
  off the bar band.

```swift
private func parkedSetAndBarMidY(in items: [MenuBarItem]) -> (barMidY: CGFloat?, parkedIDs: Set<CGWindowID>) {
    // Derive barMidY the same way isParkedOffMenuBarBand does (read that
    // function first to match its peer-selection logic exactly).
    let barMidY = ... // one derivation
    var parked = Set<CGWindowID>()
    for item in items {
        if /* item is off the band per the same predicate */ {
            parked.insert(item.windowID)
        }
    }
    return (barMidY, parked)
}
```

**Read `MenuBarItem.isParkedOffMenuBarBand(among:)` first** (`:141-159`)
to match its peer-selection and off-band predicate EXACTLY — the helper
must produce the same parked set as `isParkedOffMenuBarBand` would for
every item. Do not reimagine the predicate.

### Step 2: Replace the repeated `filter { isParkedOffMenuBarBand }` calls with set membership

In `repairVisibleLayoutAfterRestrictionChange`, at the top of each pass
(before the `prePulseParked`/`prePulseOnBand` filters at `:602-603`),
compute `(barMidY, parkedIDs) = parkedSetAndBarMidY(in: liveItems)` once.
Then replace:
- `prePulseParked = pulseCandidates.filter { $0.isParkedOffMenuBarBand(among: liveItems) }`
  → `prePulseParked = pulseCandidates.filter { parkedIDs.contains($0.windowID) }`
- `prePulseOnBand = pulseCandidates.filter { !$0.isParkedOffMenuBarBand(among: liveItems) }`
  → `prePulseOnBand = pulseCandidates.filter { !parkedIDs.contains($0.windowID) }`
- `parkedVisible` (`:626-630`) → `liveItems.filter { parkedIDs.contains($0.windowID) }`
  (recompute `parkedIDs` for the `afterItems` snapshot at `:664-668`/
  `:691-696` since the snapshot changed — that's a legitimate recompute,
  not waste).

Recompute `(barMidY, parkedIDs)` whenever the snapshot changes (i.e. for
the `afterItems` post-pulse checks) — only the within-snapshot repeats
are waste.

**Verify**: `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` → exit 0 (existing layout tests must still pass — the parked set must match `isParkedOffMenuBarBand` exactly).

### Step 3: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` → no leftover diffs.

## Test plan

- The existing layout tests (`PlanLeftmostMoveTests`, `PlanNotchOverflowTests`,
  `LayoutReconcilerTests`, etc.) exercise the repair pass indirectly — if
  the memoized set ever diverges from `isParkedOffMenuBarBand`, these
  tests will catch it.
- No new test required; the behavior must be identical.

## Done criteria

- [ ] `parkedSetAndBarMidY` helper exists and matches `isParkedOffMenuBarBand`'s predicate exactly.
- [ ] Within-snapshot `filter { isParkedOffMenuBarBand }` calls replaced with `parkedIDs.contains`.
- [ ] `xcodebuild test ...` exits 0 (existing layout tests pass — proving equivalence).
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- `MenuBarItem.isParkedOffMenuBarBand(among:)` uses peer-selection logic
  that depends on which items are passed as `among:` (i.e. it's not a
  pure function of the item + a fixed `barMidY`) — if the predicate is
  context-dependent in a way the helper can't reproduce, STOP. Do not
  memoize a predicate that isn't pure.
- The existing layout tests fail after the change — the memoized set
  diverges; do not loosen the tests, fix the helper.

## Maintenance notes

- If `isParkedOffMenuBarBand`'s predicate changes, update
  `parkedSetAndBarMidY` in the same PR — they must stay equivalent.
- A reviewer should confirm the helper is called once per snapshot (not
  per filter) and that the `afterItems` post-pulse check recomputes (the
  snapshot legitimately changed there).
