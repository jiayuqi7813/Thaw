# Plan 027: Add a `thaw://reveal-item` deep link for per-item temporary reveal

> **Executor instructions**: Follow this plan step by step.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/Utilities/SettingsURIHandler.swift" "Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift" docs/URI_SCHEMES.md`
> If any in-scope file changed since this plan was written, re-read the cited lines.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: direction (feature)
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

The README roadmap (`:152`) lists "temporarily show individual menu bar
items" as a hotkey item. The primitive already exists —
`SimpleItemHider.revealItemTemporarily(_ identifier:)`
(`SimpleItemHider.swift:469-481`) plus
`scheduleTemporaryItemConceal(_:)` (`:494-520`) — but it's invoked only
from the Thaw Bar click path. Automation users (Raycast/Alfred/Bash —
all documented as first-class in `docs/URI_SCHEMES.md:55-93`) have no
way to trigger it. This is pure surface completion against an existing
primitive AND an existing security model (`SettingsURIHandler`'s
whitelist + code-signature verification at `:176-199`). It's the
cheapest roadmap item to land. A runaway caller cannot strand items —
the reveal auto-re-conceals via `scheduleTemporaryItemConceal`.

## Current state

- `SimpleItemHider.swift:469-481` — `revealItemTemporarily(_ identifier:)`.
- `SimpleItemHider.swift:494-520` — `scheduleTemporaryItemConceal(_:)`
  (menu-open-aware re-conceal).
- `SettingsURIHandler.swift:176-199` — `isWhitelisted(bundleIdentifier:)`
  (whitelist + code-signature verification).
- `docs/URI_SCHEMES.md:13-21` — the action table (`toggle-hidden`,
  `toggle-always-hidden`, `search`, `toggle-thawbar`,
  `toggle-application-menus`, `open-settings`, `authorize`) — no
  `reveal-item`.

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/Utilities/SettingsURIHandler.swift` (add the `reveal-item` action)
- `Thaw/MenuBar/MenuBarManager.swift` or `AppDelegate.swift` (route the
  action to `simpleItemHider.revealItemTemporarily`) — find where
  existing actions are dispatched.
- `docs/URI_SCHEMES.md` (document the action)
- `ThawTests/SettingsURIHandlerTests.swift` (add cases — if it exists;
  else see STOP)

**Out of scope**:
- Do NOT add a hotkey binding (the roadmap mentions hotkeys; this plan
  is the automation/URI surface only — hotkeys are a separate plan).
- Do NOT change `revealItemTemporarily`'s conceal timing.

## Git workflow

- Branch: `advisor/027-reveal-item-deeplink`
- Commit style: `feat(uri): add thaw://reveal-item for per-item temporary reveal`

## Steps

### Step 1: Route the `reveal-item` action through the URI handler

In `SettingsURIHandler` (or wherever `thaw://` actions are dispatched —
read `AppDelegate.handleURL` or the equivalent), add a `reveal-item`
action that:
1. Calls `isWhitelisted(bundleIdentifier: sender)` — reject if not
   whitelisted.
2. Resolves the target item: accept `bundle=<bundleID>` OR
   `item-id=<uniqueIdentifier>` query params. Resolve to
   `MenuBarItemTag.canonicalPersistentIdentifier` the same way `setSection`
   does (find that resolution path in `SimpleItemHider` and reuse it).
3. Calls `appState.menuBarManager.simpleItemHider.revealItemTemporarily(identifier)`
   then `scheduleTemporaryItemConceal(identifier)`.

Reject missing/ambiguous params with a `diagLog.warning` and `false`
return.

### Step 2: Document the action in `URI_SCHEMES.md`

Add `reveal-item` to the action table (`:13-21`) with:
- params: `bundle` (preferred) or `item-id`, optional `duration` (if
  the conceal interval is overrideable — read `scheduleTemporaryItemConceal`
  to confirm; if not, omit `duration`).
- sender must be whitelisted (link to the authorize flow).

### Step 3: Add tests

In `ThawTests/SettingsURIHandlerTests.swift` (if it exists — else STOP):
- `testRevealItem_RequiresWhitelistedSender` — unwhitelisted sender → rejected.
- `testRevealItem_AcceptsBundleParam` — whitelisted sender + `bundle=...` → the hider's `revealItemTemporarily` is called with the resolved identifier (use a fake hider via plan 016's seam, or assert via a captured call).
- `testRevealItem_RejectsMissingParams` — no `bundle`/`item-id` → rejected.

**Verify**: `xcodebuild test ...` → exit 0, new tests pass.

### Step 4: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` clean.

## Test plan

- 3 new tests in `ThawTests/SettingsURIHandlerTests.swift` (listed in Step 3).
- Verification: `xcodebuild test ...` → all pass.

## Done criteria

- [ ] `thaw://reveal-item?bundle=<id>` works for a whitelisted sender.
- [ ] `docs/URI_SCHEMES.md` documents the action.
- [ ] Unwhitelisted senders and missing params are rejected.
- [ ] `xcodebuild test ...` exits 0; 3 new tests pass (or STOP if the test file is absent).
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- `ThawTests/SettingsURIHandlerTests.swift` doesn't exist — coordinate
  with plan 003 (which also adds tests there); do not create a new test
  file without an exemplar.
- `revealItemTemporarily` is `private` or not reachable from
  `SettingsURIHandler` without exposing a public method on
  `SimpleItemHider`/`MenuBarManager` — expose the minimal public method
  and note it; do not widen visibility more than needed.
- `scheduleTemporaryItemConceal` is tied to internal state that a URI
  call can't initialize — then call only `revealItemTemporarily` and let
  the existing conceal scheduling handle it; report.

## Maintenance notes

- The `duration` param (if added) must clamp to a sane range — mirror
  `tempShowInterval`'s `(0, 30)` range from `SettingsURIHandler.swift:105`.
- A reviewer should confirm a runaway caller can't strand items: the
  reveal auto-conceals via `scheduleTemporaryItemConceal`'s menu-open-
  aware delay, so repeated `reveal-item` calls just re-arm the conceal
  timer — safe.
- When the roadmap "hotkey for per-item temp show" is implemented, it
  should call the SAME `revealItemTemporarily` primitive, not duplicate.
