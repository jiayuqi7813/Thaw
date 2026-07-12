# Plan 003: Stop mislabeling non-launch failures as `HookError.launchFailed` in HookRunner

**Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving to the next step. If anything in "STOP conditions" occurs, stop and report — do not improvise. When done, update the status row for this plan in `advisor-plans/README.md`.

**Drift check (run first)**: `git diff --stat b41f1e96..HEAD -- Thaw/Utilities/HookRunner.swift`

If this file has changed since the plan was written, compare the "Current state" excerpt against the live file before proceeding. On a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug (cosmetic — error message accuracy, not a functional defect)
- **Planned at**: commit `b41f1e96`, 2026-07-11

## Why this matters

`Thaw/Utilities/HookRunner.swift`'s `run(_:context:osascriptPath:)` races a `Subprocess.run` call against a timeout task inside a `withThrowingTaskGroup`. Any error that escapes that race — including one that has nothing to do with *launching* the process, such as `Subprocess.run` throwing because a hook's stdout/stderr exceeded the 1MB `outputByteLimit` — is currently caught by a single generic `catch` and rethrown as `HookError.launchFailed(path:error:)`. That case's `description` reads `"hook launch failed for \(p): \(e)"`, which is misleading when the actual cause is an output overrun (or any other in-flight failure) rather than a failure to start the process at all. Since `HookRunner.runIfEnabled` logs this description directly to `DiagLog` on failure, a user or developer debugging a "hook launch failed" log line would incorrectly suspect the executable path/permissions rather than the hook producing too much output.

This is a low-severity, cosmetic-but-real correctness gap in error reporting — worth a one-line-ish fix, not worth leaving mislabeled indefinitely.

## Current state

File: `Thaw/Utilities/HookRunner.swift`

The race and its error handling (current committed+uncommitted state, lines ~173-201):
```swift
let outcome: RaceOutcome
do {
    outcome = try await withThrowingTaskGroup(of: RaceOutcome.self) { group in
        group.addTask {
            let result = try await Subprocess.run(
                .path(executablePath),
                arguments: Arguments(arguments),
                environment: environment,
                platformOptions: platformOptions,
                output: .string(limit: outputByteLimit),
                error: .string(limit: outputByteLimit)
            )
            return .completed(result)
        }
        group.addTask {
            try await Task.sleep(for: .seconds(clamped))
            return .timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw CancellationError()
        }
        return first
    }
} catch is CancellationError {
    throw CancellationError()
} catch {
    throw HookError.launchFailed(path: hook.path, error: error)
}
```

The `HookError` enum (lines 42-58):
```swift
enum HookError: Error, CustomStringConvertible {
    case fileMissing(path: String)
    case notExecutable(path: String)
    case launchFailed(path: String, error: Error)
    case timedOut(after: Double)
    case nonZeroExit(Int32)

    var description: String {
        switch self {
        case let .fileMissing(p): return "hook file missing: \(p)"
        case let .notExecutable(p): return "hook file not executable (run chmod +x): \(p)"
        case let .launchFailed(p, e): return "hook launch failed for \(p): \(e)"
        case let .timedOut(s): return "hook timed out after \(s)s"
        case let .nonZeroExit(s): return "hook exited with status \(s)"
        }
    }
}
```

`Subprocess.run(...)` (swift-subprocess package, tag `0.4`) can throw for multiple distinct reasons that this generic `catch` conflates: failure to exec the target binary at all (a genuine launch failure), and failures that occur after the process has already started (e.g. an output-collection limit being exceeded, per the package's `.string(limit:)` output configuration used here). Only the former is accurately described as "hook launch failed."

## Verification commands

| Check | Command | Expected |
|---|---|---|
| Build | `xcodebuild -project Thaw.xcodeproj -scheme Thaw -configuration Debug build` | `** BUILD SUCCEEDED **` |
| New case present | `grep -n "case runFailed" Thaw/Utilities/HookRunner.swift` | one match |
| Old mislabel gone from generic path | `grep -n "throw HookError.launchFailed(path: hook.path, error: error)" Thaw/Utilities/HookRunner.swift` | no output |

## Scope

**In scope** (the only file you modify):
- `Thaw/Utilities/HookRunner.swift`

**Out of scope**:
- Do not change `Thaw/MenuBar/Spacing/MenuBarItemSpacingManager.swift`'s analogous error handling (its `MenuBarItemSpacingError.processRun` case wraps the same class of error, but that file is not part of this finding — leave it untouched unless the user asks for a matching fix there separately).
- Do not change the `outputByteLimit` value or add new limit-detection logic — this plan only renames/reclassifies the error case, it does not attempt to distinguish *which* underlying cause occurred (swift-subprocess `0.4` does not expose a typed "output limit exceeded" error distinct from other run failures, so precise sub-classification is out of scope).
- Do not touch `fileMissing`, `notExecutable`, `timedOut`, or `nonZeroExit` cases.

## Git workflow

- Do not commit. Leave the working tree in the corrected state for the user to review and commit manually.
- Do not push, do not open a PR.

## Steps

### Step 1: Add a new `runFailed` case to `HookError`, keep `launchFailed` for its original, narrower purpose

`Subprocess.run(...)`'s own throw already only fires when the process genuinely fails to be created/exec'd or fails during I/O collection — the current code has no path that distinguishes these today, so rather than inventing a distinction the swift-subprocess `0.4` API cannot report, rename the generic catch-all to a name that's honest about covering both: `runFailed`. Update the enum:

```swift
enum HookError: Error, CustomStringConvertible {
    case fileMissing(path: String)
    case notExecutable(path: String)
    case runFailed(path: String, error: Error)
    case timedOut(after: Double)
    case nonZeroExit(Int32)

    var description: String {
        switch self {
        case let .fileMissing(p): return "hook file missing: \(p)"
        case let .notExecutable(p): return "hook file not executable (run chmod +x): \(p)"
        case let .runFailed(p, e): return "hook failed to run for \(p): \(e)"
        case let .timedOut(s): return "hook timed out after \(s)s"
        case let .nonZeroExit(s): return "hook exited with status \(s)"
        }
    }
}
```

(`launchFailed` is removed entirely and replaced by `runFailed` — there is exactly one call site producing this case, changed in Step 2, so this is a clean rename, not an additive case.)

**Verify**: `grep -n "case launchFailed\|case runFailed" Thaw/Utilities/HookRunner.swift` → shows only `case runFailed(path: String, error: Error)`

### Step 2: Update the throw site to use the new case

Change:
```swift
} catch {
    throw HookError.launchFailed(path: hook.path, error: error)
}
```
to:
```swift
} catch {
    throw HookError.runFailed(path: hook.path, error: error)
}
```

**Verify**: `grep -n "HookError.runFailed(path: hook.path, error: error)" Thaw/Utilities/HookRunner.swift` → one match

### Step 3: Check for any other reference to `.launchFailed` in the codebase (tests, callers)

**Verify**: `grep -rn "launchFailed" Thaw ThawTests MenuBarModel 2>/dev/null` → no output. If this returns matches, update each one to `.runFailed` (same associated values, same meaning) — do not leave a dangling reference to the removed case.

### Step 4: Full build

**Verify**: `xcodebuild -project Thaw.xcodeproj -scheme Thaw -configuration Debug build` → ends with `** BUILD SUCCEEDED **`

## Test plan

No existing test exercises `HookError` case matching by name (confirm via Step 3's repo-wide grep). No new test is required for a pure rename, but if `ThawTests` has a `HookRunnerTests.swift` or similar that asserts on `HookError.description` strings, update any assertion that references the old `"hook launch failed for"` string to `"hook failed to run for"`.

- [ ] `xcodebuild ... build` exits with `** BUILD SUCCEEDED **`
- [ ] `grep -rn "launchFailed" Thaw ThawTests MenuBarModel` returns no matches
- [ ] `git status` shows only `Thaw/Utilities/HookRunner.swift` modified (or that file plus a test file, only if Step 3 found a reference)
- [ ] `advisor-plans/README.md` status row updated to DONE

## STOP conditions

Stop and report back if:
- Step 3's grep finds references to `.launchFailed` outside `HookRunner.swift` in a file not anticipated by this plan (e.g. a `HookScript` settings UI that surfaces this error case to end users with different wording expectations) — report the location rather than guessing at the right replacement text.
- The live `HookError` enum doesn't match the "Current state" excerpt (drift).

## Maintenance notes

- If swift-subprocess ever adds a typed way to distinguish "failed to exec" from "failed during I/O" (it does not as of tag `0.4`), it would be worth re-splitting `runFailed` back into more specific cases at that point — this plan intentionally does not attempt to guess at that distinction now.
