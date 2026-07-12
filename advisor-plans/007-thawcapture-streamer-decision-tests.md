# Plan 007: Add test coverage for `ThawCapture`'s stream-rebind decision logic

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md` — unless a reviewer dispatched you and told you
> they maintain the index.
>
> **Drift check (run first)**: `git diff --stat b41f1e96..HEAD -- ThawCapture/`
> If anything under `ThawCapture/` changed since this plan was written,
> compare the "Current state" excerpts below against the live code before
> proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW (extracting a pure decision function; the `SCStream`-facing
  code itself is not modified, only refactored to call the extracted
  function instead of inlining the same expression)
- **Depends on**: none
- **Category**: test coverage
- **Planned at**: commit `b41f1e96`, 2026-07-11

## Why this matters

`Thaw/Utilities/ScreenCapture.swift` (615 lines) was deleted and its contents
split into a new local Swift package, `ThawCapture/`, with a dedicated test
target (`ThawCapture/Tests/ThawCaptureTests/ThawCaptureTests.swift`, 77 new
lines). That test file exercises only pure permission/activation-policy/
logging helpers (`ScreenCapture.permissionGranted`,
`restoreActivationPolicyAfterScreenCapturePrompt`, `isProbeLoggingEnabled`).
None of the actual `SCStream`-based capture logic that was extracted from the
deleted file — `MenuBarHostingWindowStreamer` (an actor managing a persistent
`SCStream`) and `FrameCaptor`/`LatestFrameSink` — has any test coverage. A
behavior change introduced during the extraction (or in any future edit)
would only be caught by manual verification, not CI.

Testing the actual `SCStream` lifecycle end-to-end isn't practical in CI (it
needs screen-recording permission and a real display). But
`MenuBarHostingWindowStreamer`'s most bug-prone piece — the decision of
*when* to tear down and rebind the stream — is pure boolean logic over
already-known state, and it's exactly the kind of thing that's easy to get
subtly wrong in a future edit (e.g. an `||` that should be `&&`, a dropped
condition) with no observable symptom except "the menu bar icon glyph goes
stale/blank sometimes," which is hard to notice and hard to diagnose. This
plan extracts that decision into a small testable pure function and adds
tests for it — improving coverage without needing to fake `SCStream` itself.

## Current state

`ThawCapture/Sources/ThawCapture/ScreenCapture+HostingStream.swift`, inside
`actor MenuBarHostingWindowStreamer`, method `warmCapture(displayID:)`:

```swift
123:    func warmCapture(displayID: CGDirectDisplayID) async -> ScreenCapture.MenuBarHostingCapture? {
124:        guard active else {
125:            if stream != nil {
126:                await teardown()
127:            }
128:            return nil
129:        }
130:
131:        let needsBind = stream == nil
132:            || boundDisplayID != displayID
133:            || (sink?.isStopped ?? true)
134:            || Date().timeIntervalSince(lastResolve) > reresolveInterval
135:        if needsBind {
136:            await bind(displayID: displayID)
137:        }
138:
139:        guard let image = sink?.latest else {
140:            return nil
141:        }
142:        return ScreenCapture.MenuBarHostingCapture(
143:            image: image,
144:            windowFrame: boundWindowFrame,
145:            scale: boundScale
146:        )
147:    }
```

The four conditions in `needsBind` are: no stream bound yet, display changed,
the sink reported the stream stopped, or the re-resolve interval
(`reresolveInterval = 1.0`, line 102) has elapsed since `lastResolve`. This
is pure logic over primitive state (`CGWindowID?`, `CGDirectDisplayID?`,
`Bool`, two `Date`s) — nothing here touches `SCStream` directly.

There's a second similar decision inside `private func bind(displayID:)`
(lines 151-223) — the "reuse a healthy stream already bound to this same
window" check at lines 172-180:

```swift
172:        // Reuse a healthy stream already bound to this same window.
173:        if stream != nil,
174:           boundWindowID == window.windowID,
175:           boundDisplayID == displayID,
176:           !(sink?.isStopped ?? true)
177:        {
178:            boundWindowFrame = window.frame
179:            return
180:        }
```

This one is entangled with the actual `bind` flow (it needs a resolved
`window` from `ScreenCapture.getShareableContent()` first), so it's a weaker
extraction candidate than `needsBind` — see Scope below for how to handle it.

Existing test file for this package:
`ThawCapture/Tests/ThawCaptureTests/ThawCaptureTests.swift` — read it in full
first; match its style (plain `XCTestCase`, no async/actor gymnastics in the
current tests since they only test synchronous pure functions).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build + test whole app (includes local package tests) | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, all tests pass |
| Test the package standalone (faster iteration) | `cd ThawCapture && swift test` | exit 0, all tests pass |
| Lint | `swiftlint --strict` | exit 0 |

Try the standalone `swift test` first for fast iteration; still run the full
`xcodebuild test` before declaring done, since that's the command in
`AGENTS.md` and what CI actually runs.

## Scope

**In scope**:
- `ThawCapture/Sources/ThawCapture/ScreenCapture+HostingStream.swift` —
  extract the `needsBind` boolean expression (lines 131-134) into a
  `nonisolated static func` (e.g. `static func needsBind(hasStream: Bool,
  boundDisplayID: CGDirectDisplayID?, requestedDisplayID: CGDirectDisplayID,
  sinkStopped: Bool, timeSinceLastResolve: TimeInterval, reresolveInterval:
  TimeInterval) -> Bool`) on `MenuBarHostingWindowStreamer` (or as a free
  function/extension in the same file — match whichever is more idiomatic
  given how `FrameCaptor`/other types in this file expose their pure helpers,
  check e.g. `ScreenCapture+Internal.swift` for precedent of extracted static
  decision functions). Call the extracted function from `warmCapture`
  instead of inlining the expression — behavior must be identical, this is a
  pure refactor plus new tests, not a logic change.
- `ThawCapture/Tests/ThawCaptureTests/ThawCaptureTests.swift` — add tests for
  the extracted function.

**Out of scope**:
- The "reuse a healthy stream" check inside `bind(displayID:)` (lines
  172-180) — leave as-is. It's tangled with the async `getShareableContent()`
  call and window resolution; extracting it would require restructuring
  `bind` itself, which risks the exact "silent behavior change during
  refactor" this plan is trying to guard against elsewhere. If, while doing
  Step 1, you find an easy, low-risk way to extract this one too without
  touching the surrounding async flow, you may do it — but if it requires
  reshaping `bind`'s control flow, stop that part and report it as a
  follow-up suggestion instead.
- Any change to `FrameCaptor`, `LatestFrameSink`, or actual `SCStream`
  creation/teardown code — not testable in CI, not part of this plan.
- The permission/policy tests already in `ThawCaptureTests.swift` — don't
  touch, don't duplicate.
- `MenuBarItemImageCache.swift` — separate plan (004) covers that file.

## Git workflow

- Branch: `advisor/007-thawcapture-decision-tests`
- One commit, e.g. `test(capture): extract and cover stream rebind decision logic`
- Do NOT push or open a PR.

## Steps

### Step 1: Extract `needsBind` into a pure, testable function

In `ScreenCapture+HostingStream.swift`, add a `nonisolated static func` (name
suggestion: `shouldRebind`) that takes the four inputs listed above as plain
parameters and returns the same `Bool` the current inline expression
computes. Replace the inline expression at lines 131-134 with a call to this
function, passing `stream == nil` as `hasStream`, `boundDisplayID`,
`displayID` as `requestedDisplayID`, `sink?.isStopped ?? true` as
`sinkStopped`, and `Date().timeIntervalSince(lastResolve)` /
`reresolveInterval` for the interval comparison. Keep the actor's own state
access exactly as it is today — only the boolean combination logic moves
into the static function.

**Verify**: `cd ThawCapture && swift build` → exit 0.

### Step 2: Add tests for all four trigger conditions plus the negative case

In `ThawCaptureTests.swift`, add one test per condition:
1. `hasStream == false` → `true` regardless of other inputs.
2. `boundDisplayID != requestedDisplayID` (with `hasStream == true`) → `true`.
3. `sinkStopped == true` (with matching display, has stream) → `true`.
4. `timeSinceLastResolve > reresolveInterval` (with matching display, stream
   present, sink not stopped) → `true`.
5. Negative case: all four conditions false (has stream, matching display,
   sink not stopped, time since resolve below interval) → `false`.

Use plain numeric/enum literals for `CGDirectDisplayID` (it's a `UInt32`
typealias) — no real display or `SCStream` needed since you're calling the
extracted static function directly.

**Verify**: `cd ThawCapture && swift test` → all pass, including the 5 new tests.

### Step 3: Full build and test

**Verify**: `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` → exit 0.

## Test plan

- 5 new tests in `ThawCaptureTests.swift` per Step 2, one per truth-table
  row of the extracted decision function.
- Follow the existing file's plain `XCTestCase` style (no mocks needed —
  the extracted function takes only value types).
- Verification: `swift test` (fast) and the full `xcodebuild test` command
  (authoritative) both pass.

## Done criteria

- [ ] `cd ThawCapture && swift test` exits 0, includes the 5 new tests
- [ ] `xcodebuild test ...` (full command above) exits 0
- [ ] `swiftlint --strict` exits 0
- [ ] The extracted function is `nonisolated` and takes only value-type
      parameters (no `SCStream`/`actor` state dependency) — confirm by
      reading its signature
- [ ] `warmCapture`'s behavior is unchanged — confirm by re-reading the
      diff and checking it's a pure call-site substitution, not a logic edit
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `advisor-plans/README.md` status row for 007 updated

## STOP conditions

Stop and report back (do not improvise) if:

- `warmCapture`'s `needsBind` expression has drifted from the 4-condition
  form shown above (e.g. a 5th condition was added) — re-derive the extracted
  function's parameter list from the actual current code rather than forcing
  it to match this plan's assumption.
- Extracting the function requires making `MenuBarHostingWindowStreamer`'s
  private state (`stream`, `sink`, `boundDisplayID`, `lastResolve`,
  `reresolveInterval`) any more visible than it already needs to be to call
  a `static func` on the same type from an instance method — if Swift's
  actor isolation rules make this awkward (e.g. static func can't be
  `nonisolated` for some reason encountered), stop and report the exact
  compiler error rather than weakening actor isolation to work around it.
- The "reuse a healthy stream" logic in `bind` turns out to be easy to break
  while extracting `needsBind` (e.g. because they share more state than this
  plan assumed) — stop before touching `bind` and report what you found.

## Maintenance notes

- If `MenuBarHostingWindowStreamer` grows more rebind conditions in the
  future, add them to the extracted function's parameter list and its test
  truth table together — don't let a 6th condition sneak back into an inline
  expression with no test.
- The "reuse a healthy stream" check in `bind` (out of scope here) remains an
  untested piece of this actor. If a future session has more room to
  restructure `bind` itself, extracting that check too would close the
  remaining gap in this file's decision logic.
- This plan does not address `FrameCaptor`/`LatestFrameSink`'s actual
  `SCStream` sample-buffer handling (`stream(_:didOutputSampleBuffer:of:)`,
  the frame-status/type filtering in `LatestFrameSink.stream`) — that logic
  is tightly coupled to `CMSampleBuffer`/`SCStream` types and wasn't judged
  worth the mocking effort in this pass; flag it if a future audit finds a
  bug there, since it currently has zero coverage.
