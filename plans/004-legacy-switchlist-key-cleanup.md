# Plan 004: Clean up the legacy binary switch-list UserDefaults key and add a migration test

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift ThawTests/MenuBarItemTagTests.swift`
> If either in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug + tests
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

`SimpleItemHider.loadOrder` migrates two early-macOS-27-preview keys
(`Thaw.simpleSectionAssignment`, `Thaw.simpleSectionOrder`) and correctly
deletes them after migration. But the even-older binary switch-list key
`Thaw.simpleHiddenItemIdentifiers` is only **read** to seed `map[.hidden]`
— it is never deleted. Two compounding problems:

1. Every launch, if `map` is empty (e.g. the user cleared their hidden
   items), `loadOrder` re-reads the stale legacy key and silently re-seeds
   `map[.hidden]` — so clearing hidden items doesn't stick if the legacy
   key still holds data.
2. The migration never completes; reverting Thaw to an older build
   re-reads a half-written state.

The fix is one `defaults.removeObject(forKey:)` call matching the existing
cleanup for the two sibling keys, plus one migration test mirroring the
existing `testLoadOrderMigratesLegacyKeysIntoSharedOrder`.

## Current state

`Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift`:

- Line 46 — `private static let legacyHiddenKey = "Thaw.simpleHiddenItemIdentifiers"`
- Lines 49-52 — `oldAssignmentKey` / `oldOrderKey` (the two preview-build keys).
- Lines 336-341 — the cleanup for the two preview keys:
  ```swift
  if hadLegacyData {
      let raw = Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) })
      defaults.set(raw, forKey: orderKey)
      defaults.removeObject(forKey: oldAssignmentKey)
      defaults.removeObject(forKey: oldOrderKey)
  }
  ```
- Lines 343-349 — the legacy switch-list migration that READS but never
  CLEANS:
  ```swift
  // One-time migration from the even-older binary switch-list key.
  if map.isEmpty,
     let legacy = defaults.stringArray(forKey: legacyHiddenKey),
     !legacy.isEmpty
  {
      map[.hidden] = MenuBarItemTag.canonicalPersistentIdentifiers(legacy)
  }
  ```

The existing migration test: `ThawTests/MenuBarItemTagTests.swift` around
line 1102-1124 — `testLoadOrderMigratesLegacyKeysIntoSharedOrder` seeds
`Thaw.simpleSectionOrder` and asserts both `oldAssignmentKey` and
`oldOrderKey` are removed. It never seeds `legacyHiddenKey`, so the
binary-switch-list path has no test.

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift`
- `ThawTests/MenuBarItemTagTests.swift`

**Out of scope**:
- Do NOT touch `oldAssignmentKey`/`oldOrderKey` handling (it's correct).
- Do NOT change the `orderKey` ("MenuBarItemManager.savedSectionOrder") or
  its sharing semantics.
- Do NOT migrate any other UserDefaults keys.

## Git workflow

- Branch: `advisor/004-legacy-switchlist-key-cleanup`
- Commit style: `fix(hider): delete legacy simpleHiddenItemIdentifiers key after migration`

## Steps

### Step 1: Delete `legacyHiddenKey` after migrating from it

In `SimpleItemHider.loadOrder` (around line 343-349), after seeding
`map[.hidden]` from the legacy key, remove the legacy key from defaults —
but ONLY when the migration actually ran (i.e. inside the `if map.isEmpty`
block, after seeding). The intent: once we've absorbed the legacy list
into the unified order, the legacy key is no longer authoritative and
should not re-seed on future launches.

Change the block at lines 343-349 to:
```swift
// One-time migration from the even-older binary switch-list key.
if map.isEmpty,
   let legacy = defaults.stringArray(forKey: legacyHiddenKey),
   !legacy.isEmpty
{
    map[.hidden] = MenuBarItemTag.canonicalPersistentIdentifiers(legacy)
    // The legacy key has been absorbed into the unified order; remove it
    // so a future empty map doesn't silently re-seed from stale data.
    defaults.removeObject(forKey: legacyHiddenKey)
}
```

**Verify**: `grep -n "removeObject(forKey: legacyHiddenKey)" Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift` → 1 match.

### Step 2: Add a migration test mirroring the existing one

In `ThawTests/MenuBarItemTagTests.swift`, find `testLoadOrderMigratesLegacyKeysIntoSharedOrder`
(around line 1102-1124) and read it to learn the exact pattern (how it
seeds UserDefaults, calls `SimpleItemHider.loadOrder()`, and asserts
removal). Add a new test immediately after it:

```swift
func testLoadOrderMigratesLegacyHiddenKeyAndRemovesIt() throws {
    let defaults = UserDefaults.standard
    let legacyHiddenKey = "Thaw.simpleHiddenItemIdentifiers"

    // Clean slate.
    defaults.removeObject(forKey: legacyHiddenKey)
    defaults.removeObject(forKey: "MenuBarItemManager.savedSectionOrder")
    defer {
        defaults.removeObject(forKey: legacyHiddenKey)
        defaults.removeObject(forKey: "MenuBarItemManager.savedSectionOrder")
    }

    // Seed the binary switch-list with a couple of canonical identifiers.
    defaults.set(["com.example.app::item1", "com.example.app::item2"],
                 forKey: legacyHiddenKey)

    // loadOrder should absorb them into the .hidden section.
    let order = SimpleItemHider.loadOrder()
    XCTAssertEqual(order[.hidden]?.count, 2)

    // The legacy key must be removed so it can't re-seed on a later launch.
    XCTAssertNil(defaults.stringArray(forKey: legacyHiddenKey),
                 "legacyHiddenKey must be removed after migration")
}
```

Match the existing test's `@MainActor` annotation, `import` lines, and
`XCTAssert*` style exactly (read the existing test first; if it uses a
non-defaults-backed test UserDefaults, mirror that instead of
`UserDefaults.standard`).

**Verify**: `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` → exit 0, new test passes.

### Step 3: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` → no leftover diffs.

## Test plan

- New test `testLoadOrderMigratesLegacyHiddenKeyAndRemovesIt` in
  `ThawTests/MenuBarItemTagTests.swift`, modeled after
  `testLoadOrderMigratesLegacyKeysIntoSharedOrder`.
- Cases: (a) legacy key is seeded → `loadOrder()` returns it under
  `.hidden`; (b) after `loadOrder()`, the legacy key is `nil`.
- Verification: `xcodebuild test ...` → all pass including the new test.

## Done criteria

- [ ] `defaults.removeObject(forKey: legacyHiddenKey)` is called in `loadOrder` after the migration seeds `map[.hidden]`.
- [ ] New test `testLoadOrderMigratesLegacyHiddenKeyAndRemovesIt` exists and passes.
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- The existing `testLoadOrderMigratesLegacyKeysIntoSharedOrder` test uses a
  pattern you can't mirror (e.g. a custom UserDefaults suite not available
  to a new test) — report the pattern and ask; do not invent a different
  test harness.
- `SimpleItemHider.loadOrder()` is not `static` or has a different
  signature than the test assumes — report the actual signature and stop.
- `MenuBarItemTag.canonicalPersistentIdentifiers(_:)` does not accept a
  `[String]` — report the actual signature.

## Maintenance notes

- This completes the three-key migration trilogy
  (`oldAssignmentKey`, `oldOrderKey`, `legacyHiddenKey` all now removed
  after migration). A future PR that drops migration support for very old
  installs can remove the whole `loadOrder` migration block.
- A reviewer should confirm the `removeObject` is INSIDE the
  `if map.isEmpty, let legacy ..., !legacy.isEmpty` guard — placing it
  outside would delete the key even when it was empty/absent (harmless but
  misleading).
