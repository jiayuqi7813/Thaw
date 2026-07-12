# Plan 002: Remove stray `default.profraw` and gitignore the pattern

**Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving to the next step. If anything in "STOP conditions" occurs, stop and report — do not improvise. When done, update the status row for this plan in `advisor-plans/README.md`.

**Drift check (run first)**: `git diff --stat b41f1e96..HEAD -- .gitignore`

If `.gitignore` has changed since this plan was written beyond the uncommitted state described below, compare its current tail against the excerpt in "Current state" before proceeding. On a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `b41f1e96`, 2026-07-11

## Why this matters

Commit `b41f1e96` ("chore(dev): ignore .build artifacts and enable Debug malloc stack logging") enabled Debug malloc stack logging, which causes LLVM/Swift code-coverage-adjacent tooling to drop a `default.profraw` file at the repo root on some build/test invocations. That commit did not add `*.profraw` to `.gitignore`, so the file now sits in the repo root as an untracked, unignored 0-byte file (confirmed via `ls -la default.profraw` → 0 bytes, and `git status` shows it as `??`).

Left as-is, `git status` will show this file as untracked on every future clean-build cycle for any developer with the same tooling behavior, adding friction (either it gets accidentally `git add -A`'d into a commit, or every contributor has to remember to ignore it manually).

## Current state

- File `default.profraw` exists at the repo root, 0 bytes, untracked, not covered by any `.gitignore` pattern.
- `.gitignore` (repo root) currently ends with (tail, exact content as of `b41f1e96`):
  ```
  MenuBarModel/.build/
  MenuBarModel/.swiftpm/
  ThawCtl/.build/
  xcode-skills
  xcuserdata/
  ```
  There is no `*.profraw` or `*.gcda`/`*.gcno`-style coverage-artifact pattern anywhere in the file.

## Verification commands

| Check | Command | Expected |
|---|---|---|
| File removed | `git status --porcelain -- default.profraw` | no output |
| Pattern present | `grep -n "profraw" .gitignore` | one match |
| Pattern effective | `touch /tmp/thaw-profraw-test.profraw 2>/dev/null; cp /tmp/thaw-profraw-test.profraw ./default.profraw 2>/dev/null; git status --porcelain -- default.profraw; rm -f default.profraw /tmp/thaw-profraw-test.profraw` | no output from the `git status` line (file is ignored) |

## Scope

**In scope** (the only paths you touch):
- `default.profraw` (delete)
- `.gitignore` (add one line)

**Out of scope**:
- Do not touch any other `.gitignore` entry or reorder existing lines.
- Do not investigate or change the malloc-stack-logging setup from `b41f1e96` itself — that behavior is intentional; only the missing ignore pattern is the gap here.

## Git workflow

- Do not commit. Leave the working tree in the corrected state for the user to review and commit manually.
- Do not push, do not open a PR.

## Steps

### Step 1: Delete the stray artifact

Delete `default.profraw` from the repo root. This is an untracked file (`git status` shows it as `??`), so a plain filesystem delete is sufficient — no `git rm` needed.

**Verify**: `test -f default.profraw && echo "STILL EXISTS" || echo "removed"` → `removed`

### Step 2: Add `*.profraw` to `.gitignore`

Add a new line `*.profraw` to `.gitignore`. Place it near the other build-artifact patterns (e.g. next to `*.dSYM` / `build/` block), not at the very end after unrelated entries like `xcuserdata/`.

**Verify**: `grep -n "profraw" .gitignore` → shows the new line

### Step 3: Confirm the pattern actually ignores future `.profraw` files

**Verify**: run the "Pattern effective" command from the table above → no `git status` output for the test file (confirms the glob matches at repo root; `.profraw` files from `xcodebuild`/`swift test` always land at the invocation's working directory, which for this repo's tooling is the repo root, so a root-level unanchored `*.profraw` pattern is correct — do not anchor it with a leading `/` unless you confirm profraw files never appear in subdirectories for this repo's build tooling).

## Test plan

Not applicable — this is a hygiene-only change (file deletion + ignore pattern), no code behavior changes.

- [ ] `git status --porcelain` shows no `default.profraw` entry
- [ ] `.gitignore` contains a `*.profraw` line
- [ ] `git status` after creating a throwaway `.profraw` file at repo root shows it as ignored, not untracked
- [ ] `advisor-plans/README.md` status row updated to DONE

## STOP conditions

Stop and report back if:
- `default.profraw` is not 0 bytes / has meaningful content when you check it (re-verify with `ls -la default.profraw` before deleting — if it's grown since this plan was written, it may be a live/needed artifact and deleting it should be confirmed with the user first).
- `.gitignore`'s current tail doesn't match the "Current state" excerpt (drift).

## Maintenance notes

- If future contributors see other coverage/profiling artifacts (`.gcda`, `.gcno`, `*.profdata`) appear untracked at the repo root, extend the same pattern rather than one-off deleting them each time.
