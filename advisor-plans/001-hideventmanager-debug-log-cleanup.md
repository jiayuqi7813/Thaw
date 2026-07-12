# Plan 001: Remove leftover debug logging from HIDEventManager's right-click path, keep the guard-splitting refactor

**Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving to the next step. If anything in "STOP conditions" occurs, stop and report — do not improvise. When done, update the status row for this plan in `advisor-plans/README.md`.

**Drift check (run first)**: `git diff --stat b41f1e96..HEAD -- Thaw/Events/HIDEventManager.swift`

If this file has changed since the plan was written (i.e. the command above shows changes beyond the uncommitted working-tree diff described below), compare the "Current state" excerpts in this plan against the live file before proceeding. On a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: tech-debt
- **Planned at**: commit `b41f1e96`, 2026-07-11

## Why this matters

The current *uncommitted* working-tree diff to `Thaw/Events/HIDEventManager.swift` bundles two unrelated things together:

1. A real, intentional refactor: splitting one combined `guard A, B, let C else { return }` in `handleSecondaryContextMenu` into three sequential `guard`/`return` statements (one condition each), evidently done so each failure path can be individually diagnosed.
2. Throwaway `Self.diagLog.debug(...)` calls added during a prior right-click investigation (now resolved — see the Settings-reopen / right-click bug work referenced in project history), left behind in `mouseDownMonitor`, `handleControlItemContextMenu`, and `handleSecondaryContextMenu`.

Left as-is, every right-click on a menu bar item and every empty-menu-bar-space right-click will spam `DiagLog` with 4-6 debug lines per interaction, permanently, in a hot input-handling path. This is pure log noise with no ongoing diagnostic value now that the original bug is fixed, and it obscures the actually-intentional guard-splitting refactor underneath it in code review.

The fix is surgical: delete the debug lines, keep the guard restructuring (it is functionally equivalent to the old combined guard but is a legitimate readability/debuggability improvement worth keeping).

## Current state

File: `Thaw/Events/HIDEventManager.swift`

The relevant uncommitted diff (verified via `git diff` against the file's committed state) adds five `Self.diagLog.debug(...)` calls:

1. In the `.rightMouseDown` case of the mouse-down monitor (~line 260):
   ```swift
   case .rightMouseDown:
       let clickLocation = NSEvent.mouseLocation
       Self.diagLog.debug("mouseDownMonitor: rightMouseDown received at \(clickLocation.debugDescription)")
       if !handleControlItemContextMenu(
   ```

2. Three lines inside `handleControlItemContextMenu` (~lines 1298-1325), interleaved with a guard restructuring that extracts `controlItem` and `candidateFrame` into local `let`s before the final `shouldShowControlItemContextMenu` guard:
   ```swift
   guard #available(macOS 27, *) else {
       Self.diagLog.debug("handleControlItemContextMenu: not macOS 27, skipping")
       return false
   }
   guard let controlItem = appState.menuBarManager.section(withName: .visible)?.controlItem else {
       Self.diagLog.debug("handleControlItemContextMenu: no visible-section control item")
       return false
   }
   let candidateFrame = controlItem.window?.frame
       ?? controlItem.frame
       ?? controlItem.onScreenFrame
   Self.diagLog.debug("handleControlItemContextMenu: clickLocation=\(clickLocation.debugDescription), window.frame=\(controlItem.window?.frame.debugDescription ?? "nil"), frame=\(controlItem.frame?.debugDescription ?? "nil"), onScreenFrame=\(controlItem.onScreenFrame?.debugDescription ?? "nil")")
   guard
       Self.shouldShowControlItemContextMenu(
           usesMenuBarAgent: true,
           controlItemFrame: candidateFrame,
           clickLocation: clickLocation
       )
   else {
       Self.diagLog.debug("handleControlItemContextMenu: click outside control item frame, not consuming")
       return false
   }

   Self.diagLog.debug("handleControlItemContextMenu: showing context menu")
   Task {
       controlItem.showContextMenu(at: clickLocation)
   }
   ```

3. Three lines inside `handleSecondaryContextMenu` (~lines 1343-1365), where the diff also splits one combined guard into three sequential guards:
   ```swift
   guard appState.settings.advanced.enableSecondaryContextMenu else {
       Self.diagLog.debug("handleSecondaryContextMenu: suppressing, enableSecondaryContextMenu is false")
       return
   }
   guard
       isMouseInsideEmptyMenuBarSpace(
           appState: appState,
           screen: screen
       )
   else {
       Self.diagLog.debug("handleSecondaryContextMenu: suppressing, mouse not inside empty menu bar space")
       return
   }
   guard let mouseLocation = MouseHelpers.locationAppKit else {
       Self.diagLog.debug("handleSecondaryContextMenu: suppressing, no mouse location")
       return
   }
   ```

Note there is a pre-existing `Self.diagLog.debug("handleSecondaryContextMenu: suppressing, no menu bar items on-screen for active space")` a few lines above item 3, in an unrelated pre-existing guard that is NOT part of this diff — do not touch that one, it predates this branch.

## Repo conventions

`DiagLog` is this repo's structured logging wrapper (see `Thaw/Utilities/DiagLog.swift` if present, or its usage elsewhere in `HIDEventManager.swift`) — `.debug` calls are cheap but still allocate/format strings on every invocation, which is why hot input paths in this codebase generally avoid them except for genuinely actionable diagnostics.

## Verification commands

| Check | Command | Expected |
|---|---|---|
| Build (app target) | `xcodebuild -project Thaw.xcodeproj -scheme Thaw -configuration Debug build` | `** BUILD SUCCEEDED **` |
| No leftover debug calls | `grep -n "diagLog.debug" Thaw/Events/HIDEventManager.swift \| grep -iE "rightMouseDown received|not macOS 27, skipping|no visible-section control item|clickLocation=.*window.frame=|click outside control item frame|showing context menu|enableSecondaryContextMenu is false|mouse not inside empty menu bar space|no mouse location"` | no output (all five removed) |

## Scope

**In scope** (the only file you modify):
- `Thaw/Events/HIDEventManager.swift`

**Out of scope** (do NOT touch, even though related):
- The pre-existing `"suppressing, no menu bar items on-screen for active space"` debug line a few lines above the `handleSecondaryContextMenu` changes — it predates this branch's diff, leave it exactly as-is.
- Any other file in the uncommitted diff (`MenuBarItemTag.swift`, `MenuBarSectionController.swift`, `MenuBarItemManager.swift`, `Extensions.swift`, `MenuBarItemTagTests.swift`, `MenuBarItemSpacingManager.swift`, `HookRunner.swift`, `AppState.swift`) — those are separate findings/plans or already-reviewed clean changes.
- Do not revert the guard-splitting itself (splitting the combined guard into three sequential guards in `handleSecondaryContextMenu`, and extracting `controlItem`/`candidateFrame` into locals in `handleControlItemContextMenu`) — that structural change is intentional and should be kept, only the `diagLog.debug` calls interleaved into it should be removed.

## Git workflow

- Do not commit. This plan only needs to leave the working tree in the corrected state; the user will review and commit manually.
- Do not push, do not open a PR.

## Steps

### Step 1: Remove the `mouseDownMonitor` diagnostic line

In the `.rightMouseDown` case, delete the line:
```swift
Self.diagLog.debug("mouseDownMonitor: rightMouseDown received at \(clickLocation.debugDescription)")
```
leaving:
```swift
case .rightMouseDown:
    let clickLocation = NSEvent.mouseLocation
    if !handleControlItemContextMenu(
```

**Verify**: `grep -n "rightMouseDown received" Thaw/Events/HIDEventManager.swift` → no output

### Step 2: Remove the three `handleControlItemContextMenu` diagnostic lines, keep the guard restructuring

Delete these three lines (and only these three):
```swift
Self.diagLog.debug("handleControlItemContextMenu: not macOS 27, skipping")
```
```swift
Self.diagLog.debug("handleControlItemContextMenu: no visible-section control item")
```
```swift
Self.diagLog.debug("handleControlItemContextMenu: clickLocation=\(clickLocation.debugDescription), window.frame=\(controlItem.window?.frame.debugDescription ?? "nil"), frame=\(controlItem.frame?.debugDescription ?? "nil"), onScreenFrame=\(controlItem.onScreenFrame?.debugDescription ?? "nil")")
```
```swift
Self.diagLog.debug("handleControlItemContextMenu: click outside control item frame, not consuming")
```
```swift
Self.diagLog.debug("handleControlItemContextMenu: showing context menu")
```
(five lines total in this function — re-count: two in the split-out early guards, one after `candidateFrame`, one in the final guard's else, one before the `Task {`)

Keep the `let candidateFrame = ...` local and the restructured guards exactly as they are — only strip the `diagLog.debug` call sitting inside each guard/branch.

Resulting shape:
```swift
guard #available(macOS 27, *) else {
    return false
}
guard let controlItem = appState.menuBarManager.section(withName: .visible)?.controlItem else {
    return false
}
let candidateFrame = controlItem.window?.frame
    ?? controlItem.frame
    ?? controlItem.onScreenFrame
guard
    Self.shouldShowControlItemContextMenu(
        usesMenuBarAgent: true,
        controlItemFrame: candidateFrame,
        clickLocation: clickLocation
    )
else {
    return false
}

Task {
    controlItem.showContextMenu(at: clickLocation)
}
```

**Verify**: `grep -n "handleControlItemContextMenu:" Thaw/Events/HIDEventManager.swift` → no output (all removed; this string only appeared in the debug messages, not in code identifiers)

### Step 3: Remove the three `handleSecondaryContextMenu` diagnostic lines, keep the guard splitting

Delete:
```swift
Self.diagLog.debug("handleSecondaryContextMenu: suppressing, enableSecondaryContextMenu is false")
```
```swift
Self.diagLog.debug("handleSecondaryContextMenu: suppressing, mouse not inside empty menu bar space")
```
```swift
Self.diagLog.debug("handleSecondaryContextMenu: suppressing, no mouse location")
```

Do NOT delete the pre-existing `"suppressing, no menu bar items on-screen for active space"` line above these three — that one is not part of this diff.

Resulting shape for the three new guards:
```swift
guard appState.settings.advanced.enableSecondaryContextMenu else {
    return
}
guard
    isMouseInsideEmptyMenuBarSpace(
        appState: appState,
        screen: screen
    )
else {
    return
}
guard let mouseLocation = MouseHelpers.locationAppKit else {
    return
}
```

**Verify**: `grep -n "enableSecondaryContextMenu is false\|mouse not inside empty menu bar space\|suppressing, no mouse location" Thaw/Events/HIDEventManager.swift` → no output

### Step 4: Full build

**Verify**: `xcodebuild -project Thaw.xcodeproj -scheme Thaw -configuration Debug build` → ends with `** BUILD SUCCEEDED **`

## Test plan

No new tests needed — this is a pure deletion of logging statements with no behavioral change. Confirm no behavior changed by diffing the guard *conditions* (not the debug lines) against the original combined guard:

- [ ] `handleSecondaryContextMenu`'s three sequential guards are logically equivalent to the original `guard appState.settings.advanced.enableSecondaryContextMenu, isMouseInsideEmptyMenuBarSpace(...), let mouseLocation = MouseHelpers.locationAppKit else { return }` — same three conditions, same short-circuit order, same `return` on any failure.
- [ ] `xcodebuild ... build` exits with `** BUILD SUCCEEDED **`
- [ ] `git status` shows only `Thaw/Events/HIDEventManager.swift` modified (no other files touched)
- [ ] `advisor-plans/README.md` status row updated to DONE

## STOP conditions

Stop and report back (do not improvise) if:
- The live file's guard structure in `handleSecondaryContextMenu` or `handleControlItemContextMenu` doesn't match the "Current state" excerpts above (drift since this plan was written).
- Removing a debug line would require also removing code that has a non-logging side effect (none should — verify each deleted line is a bare `Self.diagLog.debug(...)` statement with no other work in it).
- The build fails for a reason unrelated to this file (e.g. a pre-existing unrelated build break) — report it rather than trying to fix unrelated files.

## Maintenance notes

- If the right-click/context-menu logic needs debugging again in the future, prefer adding a single well-named `DiagLog` call at a decision point rather than one per branch — the five-line version added during the original investigation was useful for that one debugging session but is not warranted as permanent logging.
- The guard-splitting kept by this plan is a net readability improvement (each failure mode is independently named by its own `guard`) — future changes to this function should preserve that structure rather than re-collapsing it into one combined guard.
