# Plan 029: Design spike — "trigger conditions" for per-item reveal

> **Executor instructions**: This is a **design spike**. Investigate,
> prototype the predicate/rule model, define the API, and list open
> questions. Do NOT build the full feature — produce a design a follow-up
> plan can implement.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/Events/HIDEventManager.swift" "Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift" README.md`
> If any file changed since this plan was written, re-read the cited lines.

## Status

- **Priority**: P3
- **Effort**: M (spike; implementation is a follow-up)
- **Risk**: MED
- **Depends on**: plan 016 (SimpleItemHider injection — the spike's prototype needs a testable hider)
- **Category**: direction (design)
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

`README.md:150` roadmap: "show menu bar items when trigger conditions
are met." Repo-wide grep for `trigger.?condition|TriggerCondition`
returns exactly one match — that README line. Zero code. But the
infrastructure is half-assembled:
- `HIDEventManager.swift:165-320` — universal mouse-down/up/drag/scroll
  monitors + a `mouseMovedTap` CGEventTap with throttling and
  per-display tracking already run on the live event stream.
- `HIDEventManager.swift:850-939` — `handleShowOnClick` already
  evaluates modifier flags, double-click, and option-click as
  conditional reveal triggers — the predicate-evaluation pattern.
- `SimpleItemHider.swift:469-520` — `revealItemTemporarily(_:)` +
  `scheduleTemporaryItemConceal(_:)` implement per-item temporary reveal
  with menu-open-aware re-conceal — the exact primitive a trigger-
  condition show needs, currently called only from the Thaw Bar click
  path.

A "trigger condition" (show Wi-Fi when BT is off, show battery below
20%, show Zoom while on a Zoom call, show a status item while a given
app is frontmost) is just `predicate → revealItemTemporarily`. This is
the cheapest unshipped roadmap item relative to ground already laid.

## Current state

(See "Why this matters" — the three pre-existing primitives and the
absence of `TriggerCondition` code.)

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build (prototype) | `xcodebuild build -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0 |

## Scope

**In scope (spike; no production feature yet)**:
- A design document (append to this file's "Findings" section or a
  `plans/029-design.md`).
- Optionally a throwaway prototype in a test/scratch file proving the
  predicate model compiles and the primitive is reachable.

**Out of scope**:
- Do NOT build the full UI/persistence/event-engine in this plan.
- Do NOT change `HIDEventManager` or `SimpleItemHider` production code.

## Git workflow

- Branch: `advisor/029-trigger-conditions-spike` (if prototyping)

## Steps

### Step 1: Define the predicate/rule model

Propose:
```swift
@MainActor
struct TriggerCondition: Codable, Identifiable {
    let id: UUID
    let name: String
    let predicate: TriggerPredicate   // enum or protocol
    let revealItemIDs: [String]       // canonicalPersistentIdentifiers
    let concealDelay: Duration?
}

enum TriggerPredicate {
    case frontmostApp(bundleID: String)
    case powerBatteryBelow(percent: Int)
    case appRunning(bundleID: String)
    // ... a small starter set; extensible
}
```
Evaluate whether a protocol (`protocol TriggerPredicate { func evaluate(_:) -> Bool }`)
or an enum (with associated values, Codable) fits better. Enum is more
Codable-friendly for persistence; protocol is more extensible. Recommend
one with trade-offs.

### Step 2: Define the engine wiring

Propose a `TriggerConditionEngine` that:
- Loads persisted `[TriggerCondition]` (per-profile — reuse `Profile`).
- Rides the existing 1s `SimpleItemHider.start()` timer (or a dedicated
  1-2s tick) rather than adding a new timer.
- On a predicate flipping true, calls
  `simpleItemHider.revealItemTemporarily(id)` then
  `scheduleTemporaryItemConceal(id)`.
- Predicate inputs (frontmost app, power state) — identify the plumbing:
  `NSWorkspace.shared.frontmostApplication` (frontmost), `IOPSCopyPowerSourcesInfo`
  (battery), `runningApplications` (app-running). Note which need
  KVO/notification subscription vs. poll.

### Step 3: List open questions

- Conceal behavior: when a predicate flips false, should the item
  conceal immediately, or respect `scheduleTemporaryItemConceal`'s menu-
  open-aware delay? (Recommend: respect the delay — never yank an item
  while its menu is open.)
- Multiple predicates matching the same item: reveal once, conceal when
  ALL flip false? (Recommend: yes — reference-count.)
- Conflict with manual reveal: if the user manually reveals the Hidden
  section, should trigger reveals still fire? (Recommend: yes, but
  non-conflicting — triggers reveal individual items, not sections.)

## Test plan

N/A — design spike. The output is the design document.

## Done criteria

- [ ] A design document exists (in this file or `029-design.md`) covering: the predicate model (Step 1), the engine wiring (Step 2), and the open questions (Step 3).
- [ ] The design cites the three pre-existing primitives (`HIDEventManager:850-939`, `SimpleItemHider:469-520`) and reuses them.
- [ ] `plans/README.md` notes the design is ready for a follow-up implementation plan.

## STOP conditions

- The predicate inputs (battery, frontmost app) require entitlements or
  frameworks Thaw doesn't already use — note the dependency; don't
  assume it's free.
- The 1s timer ride conflicts with plan 006's short-circuit — the
  trigger engine may need its own tick; note the trade-off.

## Findings

*(To be filled in by the executor after the spike.)*

## Maintenance notes

- This is a design spike — the maintainer decides whether to spawn an
  implementation plan. Strategy belongs to the maintainer.
- A reviewer should confirm the design reuses `revealItemTemporarily`
  (not a duplicate reveal path) and respects the menu-open-aware conceal.
