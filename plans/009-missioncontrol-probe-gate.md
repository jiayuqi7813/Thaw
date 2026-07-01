# Plan 009: Gate the 10Hz Mission Control probe to "panel actually visible"

> **Executor instructions**: Follow this plan step by step. This touches a
> timing-sensitive probe; read "STOP conditions" carefully.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- "Thaw/MenuBar/Appearance/MenuBarOverlayPanel.swift"`
> If the file changed since this plan was written, re-read the cited lines.

## Status

- **Priority**: P3
- **Effort**: S-M
- **Risk**: MED
- **Depends on**: none
- **Category**: perf (pre-existing)
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

`MenuBarOverlayPanel` runs a `Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()`
(`:392-427`) per panel that calls `Bridging.getWindowBounds(for: windowID)`
ten times per second per display — continuously, forever — to detect
Mission Control via probe-window displacement. The probe window is created
unconditionally in `init` (`:315-338`), so every per-display panel runs
the probe even when no appearance is configured and the panel is hidden.
On a 2-display system that's 20 WindowServer IPC calls/sec of steady-state
work. A separate 60s `applicationMenuFrame` timer (`:519-527`) also runs
per panel.

## Current state

`Thaw/MenuBar/Appearance/MenuBarOverlayPanel.swift`:
- `:315-338` — `missionControlProbeWindow` created unconditionally in `init`.
- `:392-427` — `Timer.publish(every: 0.1)` calls `Bridging.getWindowBounds(for: windowID)`
  ten times/sec; `:415` uses a `displacedSince` threshold of 0.1s to detect
  Mission Control.
- `:519-527` — 60s `Timer.publish` for `applicationMenuFrame` refresh.
- `:567-571` — the panel's alpha is already toggled by
  `isMenuBarHiddenBySystem`/`isMissionControlActive`, so a visibility gate
  for the probe is straightforward.

**Note**: This is a **pre-existing** mechanism (the probe predates the
branch's +571 churn). The branch added the sinks and AX-walk refreshes
(plan 008) but did not introduce the probe. Still worth fixing because
the branch makes the panel more active.

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |
| Lint | `swiftlint --strict` | exit 0 |

## Scope

**In scope**:
- `Thaw/MenuBar/Appearance/MenuBarOverlayPanel.swift`

**Out of scope**:
- Do NOT lower the 0.1s poll rate — Mission Control detection is
  timing-sensitive (the `displacedSince` threshold at `:415`); changing
  the rate could miss or delay MC activation. Gate visibility instead.
- Do NOT remove the 60s `applicationMenuFrame` timer (separate concern).
- Do NOT change the probe-window creation mechanism.

## Git workflow

- Branch: `advisor/009-missioncontrol-probe-gate`
- Commit style: `perf(overlay): pause Mission Control probe while the panel is hidden`

## Steps

### Step 1: Pause the 0.1s probe timer when the panel is not visible

Find the `Timer.publish(every: 0.1, ...).autoconnect()` at `:392-427` and
store its publisher/cancellable so it can be cancelled/resumed. Gate it on
the panel's visibility: when the panel is hidden
(`isMenuBarHiddenBySystem` || `isMissionControlActive` || no appearance
configured || `alphaValue == 0`), cancel/pause the probe; resume it on
`needsShow` / when the panel becomes visible.

The existing alpha-toggle logic at `:567-571` is the model: wherever the
panel's alpha is set to 0, also pause the probe; wherever it's set to 1,
resume the probe. Use `Combine`'s `connect()`/`cancel()` on the
`Autoconnect`-wrapped publisher, or convert to a manually-managed
`Timer.scheduledTimer` that you `invalidate()`/recreate.

**Escape hatch**: if the `Timer.publish` publisher is hard to pause
precisely (Combine autoconnect is finicky), the MINIMUM acceptable change
is an early-return at the top of the per-tick closure when the panel is
hidden — that still avoids the `Bridging.getWindowBounds` IPC even if the
timer keeps firing. Ship that if the connect/cancel approach proves risky.

**Verify**: build → exit 0. Manually confirm: with no appearance configured, the probe stops calling `getWindowBounds` (add a temporary `diagLog.debug` in the tick and confirm it stops); with an appearance configured and the panel visible, MC detection still works (invoke Mission Control and confirm the panel hides).

### Step 2: Run the test suite

**Verify**: `xcodebuild test ...` → exit 0.

### Step 3: Lint and format

**Verify**: `swiftlint --strict` → exit 0; `swiftformat .` → no leftover diffs.

## Test plan

- No direct panel tests exist. Verification is the existing suite + a
  manual MC-detection smoke test (the timing sensitivity makes a unit
  test low-value here).

## Done criteria

- [ ] The 0.1s probe does not call `Bridging.getWindowBounds` while the panel is hidden / no appearance configured.
- [ ] Mission Control detection still works when the panel is visible (manual smoke test).
- [ ] `xcodebuild test ...` exits 0.
- [ ] `swiftlint --strict` exits 0; `swiftformat .` clean.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- Pausing the probe causes Mission Control detection to miss or lag — the
  probe must be running BEFORE MC starts (the displacement is what
  signals MC). If pausing-on-hidden means the probe isn't running when MC
  fires, STOP. The safe fallback is the early-return-in-tick approach
  (keep the timer running but skip the IPC when hidden) — but even that
  must resume the IPC the moment the panel shows. If neither is safe,
  report and abandon; the steady-state cost is real but not worth
  breaking MC detection.
- The `Timer.publish`/Combine plumbing resists clean connect/cancel —
  take the early-return-in-tick escape hatch and note it in the commit.

## Maintenance notes

- If the panel's visibility model changes (e.g. a new "always probe"
  diagnostic mode), ensure the gate respects it.
- A reviewer should manually invoke Mission Control on a multi-display
  setup after this change and confirm the panel still hides correctly —
  timing-sensitive code must be validated on real hardware.
- This is a pre-existing mechanism; if a future macOS build provides a
  proper Mission Control notification (replacing the probe-window hack),
  delete the probe entirely.
