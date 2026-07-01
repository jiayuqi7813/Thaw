# Plan 001: Add AGENTS.md so agents can build, lint, and target the right branch

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 87b0e507..HEAD -- AGENTS.md`
> If `AGENTS.md` already exists or changed since this plan was written, treat
> it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

This repo has no `AGENTS.md` or `CLAUDE.md`, yet agents are already part of
the workflow (`.cursorrules` ships RTK token-compression rules;
`scripts/setup-headroom-claude.sh `configures a Claude Code CLI proxy).
`.github/CONTRIBUTING.md` lists only "Xcode 26+ / macOS 26+" and tells
contributors to run `swiftlint lint` — but CI runs `swiftlint --strict` in a
pinned Docker image, and the canonical build/test command (an `xcodebuild`
line with `CODE_SIGNING_ALLOWED=NO`) appears only in `.github/workflows/ci.yml`.
An agent executing any later plan against this repo will run the wrong lint
command, miss the copyright-header convention, and not know to PR into
`development`. This plan is the prerequisite that unblocks every other
agent-executed plan.

## Current state

- No `AGENTS.md` or `CLAUDE.md` exists at the repo root (confirmed via
  `git ls-files`).
- `.github/CONTRIBUTING.md:68-69` — prerequisites say only "Xcode 26+ /
  macOS 26+".
- `.github/CONTRIBUTING.md:88-89` — tells contributors to run `swiftlint lint`
  (CI actually runs `swiftlint --strict`).
- `.github/workflows/ci.yml:45-49` — the real lint command:
  `docker run --rm -v "$PWD:/work" -w /work ghcr.io/realm/swiftlint:0.63.3 swiftlint --strict`
- `.github/workflows/ci.yml:72-80` — the canonical build/test command.
- `.swiftformat` and `.swiftlint.yml` — the format/lint config; the
  `file_header` rule (`.swiftlint.yml:57-65`) and `--header` (`.swiftformat:18`)
  require the GPL-3.0 copyright block on every Swift file.

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Lint (local) | `swiftlint --strict` | exit 0 (if swiftlint installed) |
| Lint (CI-matching) | `docker run --rm -v "$PWD:/work" -w /work ghcr.io/realm/swiftlint:0.63.3 swiftlint --strict` | exit 0 |
| Build & test | `xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` | exit 0, tests pass |

(These are the exact commands from `.github/workflows/ci.yml`. Verification
for this docs-only plan is just "the file exists and lint still passes.")

## Scope

**In scope** (the only file you should modify):
- `AGENTS.md` (create at repo root)

**Out of scope**:
- Do NOT modify `.github/CONTRIBUTING.md` (a separate human-facing doc; keep
  it as-is).
- Do NOT modify `.cursorrules`, `.swiftlint.yml`, `.swiftformat`, or any CI
  config.
- Do NOT add a `CLAUDE.md` — `AGENTS.md` is the single file; tools that look
  for `CLAUDE.md` will be handled by the operator's symlinking if needed.

## Git workflow

- Branch: `advisor/001-agents-md`
- Commit style: conventional commits — e.g. `docs(dx): add AGENTS.md for agent-executed contributions`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Create `AGENTS.md` at the repo root

Write `AGENTS.md` with these sections (content below is the required
minimum — you may phrase naturally, but every section must be present and
the commands must be exact):

```markdown
# AGENTS.md

Guidance for AI agents (and contributors) working in this repository.

## Project

Thaw is a Swift 6.0 macOS menu bar management app (a fork of "Ice"),
SwiftUI + AppKit + a small amount of Objective-C. GPL-3.0. Targets
macOS 26+, with macOS 27 "Golden Gate" support in development on the
`feat/macos-27-experimental` branch.

## Prerequisites

- Xcode 26+ on macOS 26+. CI pins `Xcode_26.5.app`.

## Build & test (canonical command)

```
xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Use this exact invocation. `CODE_SIGNING_ALLOWED=NO` is required for
unsigned CI-style builds.

## Lint & format

- SwiftLint (must pass `--strict`, matching CI):
  ```
  swiftlint --strict
  ```
  CI runs it in `ghcr.io/realm/swiftlint:0.63.3`. Config: `.swiftlint.yml`.
- SwiftFormat (run before committing; idempotent):
  ```
  swiftformat .
  ```
  Config: `.swiftformat`.

## Code conventions

- **Copyright header required on every Swift file** (enforced by SwiftLint
  `file_header` + SwiftFormat `--header`). The exact block:
  ```
  //
  //  <FILENAME>
  //  Project: Thaw
  //
  //  Copyright (Ice) © 2023–2025 Jordan Baird
  //  Copyright (Thaw) © 2026 Toni Förster
  //  Licensed under the GNU GPLv3
  ```
- 4-space indentation (no tabs). Trailing commas mandatory. Implicit self
  (`--self remove`). K&R braces. No line-length limit.
- Conventional commit messages: `fix(scope):`, `feat(scope):`,
  `test(scope):`, `docs(scope):`, `chore(scope):`.

## Git workflow

- Branch from and PR into `stonerl/Thaw:development` (NOT `main`).
- Do not commit translations — those are managed via Crowdin.

## macOS 27-specific invariants (read before touching hiding code)

The `feat/macos-27-experimental` branch rebuilds menu bar hiding on a
private `MenuBarClientCore` "Assessment Mode" assertion. Code that touches
hiding MUST respect:

- **Pass ordering is load-bearing**: `SimpleItemHider.applyExperimentalWindowHiding`
  runs backends in order plist → CGS → AX → position-lock. Reordering
  regresses the iStat-ghosting fix. See `Thaw/MenuBar/HiddenSectionPatch/SimpleItemHider.swift`.
- **macOS 27 gating**: `SimpleItemHider` is created only on macOS 27+
  (see `Thaw/MenuBar/MenuBarManager.swift`). macOS 26 keeps its native
  section machinery — do not port 27-only code paths to 26.
- **Private-API coupling**: `ThawAssessmentModeHidingActivate` wraps a
  private framework; every call is `@try/@catch`-guarded and degrades to
  "hiding inert" if the classes are renamed. Preserve that guard.
- **`TrailingItemPreferredPositions`** in `com.apple.MenuBarAgent`'s
  preferences domain is the only per-item control surface on macOS 27.

## Verification

Before declaring done, run both:
```
swiftlint --strict
xcodebuild test -project Thaw.xcodeproj -scheme Thaw -derivedDataPath Build/ -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```
```

**Verify**: `test -f AGENTS.md && grep -q "CODE_SIGNING_ALLOWED=NO" AGENTS.md` → exit 0.

### Step 2: Confirm lint still passes (the new file is Markdown; SwiftLint ignores it, but confirm nothing regressed)

**Verify**: `swiftlint --strict` → exit 0 (no new violations; `AGENTS.md` is not in the `included` list in `.swiftlint.yml`, which covers only `MenuBarItemService`, `Shared`, `Thaw`).

## Done criteria

- [ ] `AGENTS.md` exists at the repo root.
- [ ] It contains the canonical `xcodebuild` line (with `CODE_SIGNING_ALLOWED=NO`).
- [ ] It documents `swiftlint --strict`, `swiftformat .`, the copyright header, the `development` PR target, and the macOS 27 hiding invariants.
- [ ] `swiftlint --strict` exits 0.
- [ ] No files outside the in-scope list are modified (`git status` shows only `AGENTS.md`).
- [ ] `plans/README.md` status row updated.

## STOP conditions

- `AGENTS.md` already exists at the repo root (someone added it since this plan was written).
- `swiftlint --strict` reports violations you cannot attribute to this plan's change (stop — there may be a pre-existing issue; report it rather than fixing unrelated code).

## Maintenance notes

- When the build command, SwiftLint version, or copyright year changes in CI/config, update `AGENTS.md` in the same PR.
- When a new macOS-27-only invariant is added to the hiding pipeline, add a bullet to the "macOS 27-specific invariants" section so future agents don't violate it.
- A reviewer should confirm the `xcodebuild` line matches `.github/workflows/ci.yml:72-80` byte-for-byte (modulo shell quoting).
