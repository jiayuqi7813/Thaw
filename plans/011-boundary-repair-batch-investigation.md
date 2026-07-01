# Plan 011: Investigate batching the macOS 27 boundary-repair loop

> **Executor instructions**: This is a **design spike**, not a build plan.
> Investigate, report findings, and propose a fix — do NOT implement the
> batching until the maintainer approves a specific approach.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/MenuBar/MenuBarItems/MenuBarItemManager.swift" "Thaw/MenuBar/MenuBarItems/MenuBarAgentPositionStore.swift"`
> If either file changed since this plan was written, re-read the cited lines.

## Status

- **Priority**: P3
- **Effort**: M (investigation; implementation TBD)
- **Risk**: MED
- **Depends on**: none
- **Category**: perf (investigate)
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

On the macOS 27 reveal path (Thaw-icon click, hotkey, hover — the hottest
user path), `MenuBarItemManager.reconcileMacOS27SectionBoundaries` calls
`MenuBarAgentPositionStore.move(item:to:liveItems:…)` once per
boundary-violating assigned item (`MenuBarItemManager.swift:4385-4396`),
and after each successful move does
`liveItems = await MenuBarItem.getMenuBarItems(option: .activeSpace)` —
a full AX walk per item. Each `move` also writes the plist and calls
`nudgeAgent()` (`MenuBarAgentPositionStore.swift:150-153,459-465`), which
`SIGTERM`s `MenuBarAgent` — a managed launch agent that relaunches in
~1-2s per the doc comment at `:448-458`. So for N boundary-violating
items, the reveal path does N plist writes, N SIGTERMs (each forcing a
1-2s agent relaunch), and N full AX walks — serially. The bar visibly
churns per item and the work blocks the user's next interaction.

**Caveat (why this is a spike, not a fix):** the codebase AUTHORS document
the justification at `MenuBarAgentPositionStore.swift:448-458`:
> "This restarts immediately, once per `move(...)`. The per-pair reconcile
> loop is sequentially dependent — each move needs the agent to re-sort
> before the next is planned and verified — so restarts there cannot be
> coalesced without breaking verification. The batch entry point (which
> writes every target weight from one snapshot, then nudges once) is where
> a multi-item reorder collapses to a single restart."

So the question is NOT "just batch it" — it's: **does the boundary-repair
case genuinely require per-item verification, or can the destinations be
computed up-front from one snapshot and applied via the existing batch
entry point?** The batch path already exists (`MenuBarAgentPositionStore`
has a "Batch order" entry point at `:160`+ that writes every target weight
from one snapshot then nudges once).

## Current state

`Thaw/MenuBar/MenuBarItems/MenuBarItemManager.swift:4370-4414` — the
boundary-repair loop:
```swift
if #available(macOS 27, *),
   MenuBarAgentPositionStore.move(
       item: liveItem,
       to: destination,
       liveItems: liveItems,
       experimentalSystemItemHiding: experimentalSystemItemHiding
   )
{
    MenuBarItemManager.diagLog.info("Repaired macOS 27 section boundary for ...")
    liveItems = await MenuBarItem.getMenuBarItems(option: .activeSpace)  // full AX walk per item
}
```
The `destination` comes from `LayoutPlanner.sectionBoundaryDestination(for:controlItems:)`
(`:4371-4374`) — "which side of the divider" the item should be on.

`Thaw/MenuBar/MenuBarItems/MenuBarAgentPositionStore.swift`:
- `:140-156` — `move(item:to:liveItems:…)` (per-pair: writes plist + nudges).
- `:448-465` — `nudgeAgent()` SIGTERMs MenuBarAgent; doc comment above.
- `:160`+ — the "Batch order" entry point (writes every target weight
  from one snapshot, then nudges once).

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build (after any experimental change) | `xcodebuild build -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0 |

## Scope

**In scope (investigation; do NOT change code without approval)**:
- Read `Thaw/MenuBar/MenuBarItems/MenuBarItemManager.swift` around the
  boundary-repair loop (`:4350-4415`) and `applyMacOS27SectionItemOrder`.
- Read `Thaw/MenuBar/MenuBarItems/MenuBarAgentPositionStore.swift` — the
  `move` per-pair path (`:140-156`) and the batch path (`:160`+).
- Read `Thaw/MenuBar/MenuBarItems/LayoutPlanner.swift` —
  `sectionBoundaryDestination` and `achievableOrderSegments`.

**Out of scope**:
- Do NOT implement batching in this plan. Produce a written finding and a
  proposed fix; a separate plan will implement it after approval.

## Git workflow

- Branch: `advisor/011-boundary-repair-batch-investigation`
- Commit style: `docs(perf): investigate batching macOS 27 boundary-repair loop` (or no commit if just a report)

## Steps

### Step 1: Determine whether boundary-repair destinations are independent of intermediate states

Read `LayoutPlanner.sectionBoundaryDestination(for:controlItems:)`. The
key question: **does moving item A to "the correct side of the divider"
change the destination of item B?**

- If NO (each item's destination is "which side of a fixed divider" —
  computable from one snapshot): the batch path is applicable. Proceed
  to Step 2.
- If YES (moving A changes B's anchor/midpoint): per-item verification is
  genuinely needed. STOP and report — the perf cost is inherent; the only
  mitigation would be a lighter nudge than SIGTERM-restart (Step 3).

### Step 2: If batchable, propose using the existing batch entry point

Write a short proposal: replace the per-item `move` loop with a single
call to the batch entry point (`MenuBarAgentPositionStore`'s "Batch
order" at `:160`+), computing all destinations from one snapshot, writing
all target weights, and nudging once. Identify what would need to change
in `reconcileMacOS27SectionBoundaries` (collect destinations in one pass,
call the batch API, then do ONE AX walk to verify residuals).

Identify risks: the batch path may not support the "which side of the
divider" destination shape directly (it may be designed for full-section
reordering). Note the gap.

### Step 3: If NOT batchable, investigate a lighter nudge

If per-item verification is genuinely required, the SIGTERM-and-relaunch
(1-2s per item) is the bottleneck. Investigate whether a lighter nudge
exists — e.g. posting a distributed notification that MenuBarAgent
observes to re-read positions without a full process restart. The doc
comment says "The reliable trigger is a restart" — but verify whether
that's still true on macOS 27 or whether a `CFPreferencesSynchronize`+
notification combo now works. Report findings.

## Test plan

N/A — this is an investigation. The output is a written report appended to
this plan file (or a new `plans/011-findings.md`) describing:
- Whether destinations are independent (Step 1 result).
- The proposed batch approach + risks (Step 2), OR the lighter-nudge
  investigation (Step 3).
- A recommendation: implement / defer / abandon.

## Done criteria

- [ ] A written report exists (in this file's "Findings" section below, or a linked `011-findings.md`) answering the Step 1 question with evidence (cited lines from `LayoutPlanner`).
- [ ] If batchable: a concrete proposed fix with the exact API call and the residual-verification plan.
- [ ] If not batchable: a note on whether a lighter nudge is feasible.
- [ ] `plans/README.md` status row updated (mark BLOCKED on maintainer decision, or TODO for the implementation plan this spawns).

## STOP conditions

- The boundary-repair loop's correctness depends on subtle ordering you
  can't verify from reading — STOP and report; do not propose a batch
  change you can't justify.
- The batch entry point's signature/contract doesn't match the
  boundary-repair need — report the gap and stop (a separate plan would
  extend the batch API).

## Findings

Boundary destinations are independent at the policy level, but not directly
batchable through the current API:

- `LayoutPlanner.sectionBoundaryDestination(section:controlItems:)` maps each
  assigned item to a divider-relative destination: visible items go right of
  the Hidden divider, Hidden items go left of it, and Always Hidden items go
  left of the Always Hidden divider when that divider exists.
- `MenuBarItemManager.reconcileMacOS27SectionBoundaries` recomputes
  `ControlItemPair` and calls `MenuBarAgentPositionStore.move` per violating
  item, then re-enumerates AX after each successful move. The loop therefore
  pays one plist write, one `MenuBarAgent` nudge, and one AX walk per item.
- `MenuBarAgentPositionStore.applyOrder` is a real batch primitive, but its
  contract is section-order permutation within
  `LayoutPlanner.achievableOrderSegments`. It intentionally partitions around
  fixed system anchors and reuses existing weights inside each segment. It does
  not express "place every boundary-violating hidden item left of this divider"
  or "place every visible item right of this divider".

Recommendation: do not route boundary repair through `applyOrder` as-is. Add a
follow-up implementation plan for a boundary-specific batch API that:

1. Takes a list of `(item, destination)` repairs computed from one live
   snapshot.
2. Resolves all keys and candidate anchor weights from that same snapshot.
3. Writes all changed weights once and nudges `MenuBarAgent` once.
4. Performs one residual AX verification pass, then falls back to the existing
   per-item loop only for unresolved or still-violating items.

I did not find evidence for a lighter reliable nudge in this codebase. The
existing `nudgeAgent()` contract documents restart as the reliable trigger, and
both `move` and `applyOrder` still depend on that mechanism.

## Maintenance notes

- This spike gates a potential high-impact perf win on the hot reveal
  path. Don't skip the investigation and "just batch it" — the authors'
  documented justification (`MenuBarAgentPositionStore.swift:448-458`)
  must be engaged with directly.
- A reviewer (the maintainer) makes the final call on whether to
  implement the proposed fix.
