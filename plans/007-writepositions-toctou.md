# Plan 007: Drop the TOCTOU file write in `TrailingItemPositionStore.writePositions`

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- Thaw/MenuBar/HiddenSectionPatch/TrailingItemPositionStore.swift`
> If the file changed since this plan was written, compare the "Current
> state" excerpt against the live code before proceeding.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: MED
- **Depends on**: none
- **Category**: bug + perf
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

`TrailingItemPositionStore.writePositions` writes the
`TrailingItemPreferredPositions` dictionary to `com.apple.MenuBarAgent`'s
preferences domain via TWO mechanisms on every call: first
`CFPreferencesSetValue` + `CFPreferencesSynchronize` (the cross-process
API), then a direct `NSMutableDictionary(contentsOfFile:)` read +
`plist.write(toFile:atomically:)` (a "fallback so MenuBarAgent sees the
change even if CFPreferences sync doesn't propagate"). Two problems:

1. **TOCTOU race**: between the file read (`:479`) and the
   `plist.write` (`:481`), `MenuBarAgent` (a separate process that
   continuously rewrites this same plist) may have written new position
   data that the read-modify-write silently clobbers — scrambling the bar
   order or dropping items the agent just placed. The sibling
   `MenuBarAgentPositionStore` writes CFPreferences-only and does NOT
   touch the file directly (see `:436-446`).
2. **Per-change cost**: every position lock/hide/show serializes the whole
   plist AND does a full atomic file write (fsync) on top of the
   CFPreferences sync. With `enableExperimentalWindowHiding` on, this runs
   every 1s tick.

## Current state

`Thaw/MenuBar/HiddenSectionPatch/TrailingItemPositionStore.swift:462-482`:
```swift
func writePositions(_ dict: [String: Int]) {
    // CFPreferences path.
    CFPreferencesSetValue(
        Self.positionKey as CFString,
        dict as CFPropertyList,
        Self.agentDomain,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    )
    CFPreferencesSynchronize(
        Self.agentDomain,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    )
    // Direct plist write fallback so MenuBarAgent sees the change even
    // if CFPreferences sync doesn't propagate cross-process.
    let plistPath = ("~/Library/Preferences/\(Self.agentDomain as String).plist" as NSString).expandingTildeInPath
    let plist = (NSMutableDictionary(contentsOfFile: plistPath) as NSMutableDictionary?) ?? NSMutableDictionary()
    plist[Self.positionKey] = dict
    plist.write(toFile: plistPath, atomically: true)
}
```

Sibling for comparison — `Thaw/MenuBar/MenuBarItems/MenuBarAgentPositionStore.swift:436-446`
writes CFPreferences only (no direct file write).

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/MenuBar/HiddenSectionPatch/TrailingItemPositionStore.swift`

**Out of scope**:
- Do NOT change `readPositions` (`:431-460`) — its file fallback is a READ
  (safe) and is the documented way to handle CFPreferences read gaps.
- Do NOT change `MenuBarAgentPositionStore` (it's already correct; it's
  the exemplar).
- Do NOT touch the callers (`lockVisiblePositions`, `hideItems`, `showItems`,
  `restoreAll`, `restoreAllHiddenItems`) — they call `writePositions` and
  should keep working.

## Git workflow

- Branch: `advisor/007-writepositions-toctou`
- Commit style: `fix(hider): only fall back to direct plist write when CFPreferencesSynchronize fails`

## Steps

### Step 1: Gate the direct file write behind `CFPreferencesSynchronize` failure

`CFPreferencesSynchronize` returns a `Bool` (true = synchronized
successfully). Change `writePositions` so the direct file write only
happens when synchronization returned false:

```swift
func writePositions(_ dict: [String: Int]) {
    CFPreferencesSetValue(
        Self.positionKey as CFString,
        dict as CFPropertyList,
        Self.agentDomain,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    )
    let synced = CFPreferencesSynchronize(
        Self.agentDomain,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    )
    // Direct plist write fallback ONLY when CFPreferences sync failed to
    // propagate cross-process. The read-modify-write below is not safe to
    // run unconditionally: MenuBarAgent rewrites this plist continuously,
    // and a read-then-write races its writes (clobbering just-applied
    // positions).
    guard !synced else { return }
    let plistPath = ("~/Library/Preferences/\(Self.agentDomain as String).plist" as NSString).expandingTildeInPath
    let plist = (NSMutableDictionary(contentsOfFile: plistPath) as NSMutableDictionary?) ?? NSMutableDictionary()
    plist[Self.positionKey] = dict
    plist.write(toFile: plistPath, atomically: true)
    diagLog.warning("writePositions: CFPreferencesSynchronize failed; used direct plist fallback")
}
```

Note: `CFPreferencesSynchronize` is documented to return true on success.
In practice on macOS 26/27 it nearly always succeeds for
`kCFPreferencesAnyHost`, so the fallback becomes rare — which is the goal.

**Verify**: build → exit 0. `grep -n "guard !synced" Thaw/MenuBar/HiddenSectionPatch/TrailingItemPositionStore.swift` → 1 match.

### Step 2: Confirm the existing tests still pass

`ThawTests/CGSWindowHiderTests.swift` and any test that exercises
`TrailingItemPositionStore` indirectly (none direct — see plan 017) must
still pass. The behavior change is: on the happy path (sync succeeds) the
file is no longer written; tests that asserted a file write would need
updating, but there are no such tests (the store has no direct tests).

**Verify**: `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` → exit 0.

### Step 3: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` → no leftover diffs.

## Test plan

- No direct tests exist for `TrailingItemPositionStore` (plan 017 adds
  them). The verification gate here is the existing suite.
- If plan 017 has landed, add a case: inject an `Environment` whose
  `writePositions` fake returns `synced = true` and assert the file-write
  path is NOT invoked; then `synced = false` and assert it IS invoked.
  (This requires `writePositions` to be injectable — coordinate with plan 017.)

## Done criteria

- [ ] The direct `plist.write(toFile:atomically:)` only runs when `CFPreferencesSynchronize` returns false.
- [ ] `writePositions` no longer does an unconditional read-modify-write of the plist file.
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- The code at `:462-482` doesn't match the excerpt (drift).
- `CFPreferencesSynchronize` does not return `Bool` in this SDK (it
  should, but if the signature changed, stop and report).
- A maintainer confirms the direct file write is REQUIRED on their test
  hardware because CFPreferences sync is unreliable there — in that case,
  do NOT remove the unconditional write; instead, make the read-modify-
  write race-safe (e.g. read the dict, merge rather than overwrite, and
  write under a `Flock` on the plist file). Report and stop before
  choosing this path.

## Maintenance notes

- If a future macOS build makes CFPreferences sync unreliable for
  `com.apple.MenuBarAgent`, the fallback still fires — this plan does not
  remove the fallback, only gates it.
- A reviewer should manually verify (on a real macOS 27 build with the
  experimental flag on) that item ordering still propagates to
  MenuBarAgent after this change — the CFPreferences path is the
  documented primary mechanism, but a real-device smoke test is the only
  proof.
- Coordinate with plan 017 (TrailingItemPositionStore tests): the
  `writePositions` function may need an `Environment` seam to test the
  gated fallback; do that in 017, not here.
