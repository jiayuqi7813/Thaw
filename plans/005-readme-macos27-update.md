# Plan 005: Update README to reflect macOS 27 support (stale-at-merge)

> **Executor instructions**: Follow this plan step by step. If anything in
> the "STOP conditions" section occurs, stop and report.

> **Drift check (run first)**: `git diff --stat 87b0e507..HEAD -- README.md`
> If `README.md` changed since this plan was written, re-read the cited
> lines before editing.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: docs
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

This branch (`feat/macos-27-experimental`) delivers macOS 27 "Golden Gate"
support — the private `MenuBarClientCore` Assessment Mode assertion is the
mechanism (see `Thaw/MenuBar/HiddenSectionPatch/ThawAssessmentModeHiding.h:10-12`).
But `README.md` still says "Thaw is a powerful menu bar management tool
for macOS 26" (`:8`), the requirements badge says "macOS 26+" (`:33`), and
the roadmap lists "macOS 27 support — compatibility with the next macOS
release" as a future item (`:149`). On merge, the published README will
under-claim support: macOS 27 users won't know the app supports their OS,
and the roadmap will advertise as "next release" a feature that already
shipped. Stale version claims are actively wrong (worse than missing).

**Timing**: this plan should land AT MERGE of the macOS 27 branch (or be
the final commit on the branch), not before — updating the README to
claim macOS 27 support while the feature is still behind a feature flag
would be premature. Confirm with the maintainer that the branch is ready
to merge before executing.

## Current state

`README.md`:
- Line 8 — "Thaw is a powerful menu bar management tool for macOS 26."
- Line 14-18 — a status banner linking to issue #687 ("For macOS 27
  (Golden Gate) status and preview builds, click here").
- Line 33 — `![Requirements](https://img.shields.io/badge/requirements-macOS%2026%2B-fa4e49?style=square)`
- Line 149 — roadmap: "- **macOS 27 support** — compatibility with the next macOS release."

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Validate README links (optional) | `grep -n "macOS 26" README.md` | shows the lines to update |

(No build/lint needed — docs-only change.)

## Scope

**In scope**:
- `README.md`

**Out of scope**:
- Do NOT touch the translations table, contributors, or star history.
- Do NOT remove the issue #687 link at `:14-18` unless the maintainer says
  the issue is closed (it may still track ongoing 27.x point-release
  fixes). Leave it; it's still useful.
- Do NOT change `FREQUENT_ISSUES.md` (separate concern).

## Git workflow

- Branch: `advisor/005-readme-macos27-update`
- Commit style: `docs(readme): reflect macOS 27 support`

## Steps

### Step 1: Update the version claim and badge

- Line 8: change "Thaw is a powerful menu bar management tool for macOS 26."
  to "Thaw is a powerful menu bar management tool for macOS 26 and 27."
  (Match the maintainer's preferred phrasing if they direct otherwise; the
  key change is that 27 is now supported, not just 26.)
- Line 33: update the requirements badge URL to
  `![Requirements](https://img.shields.io/badge/requirements-macOS%2026%2B-fa4e49?style=square)`
  — keep "macOS 26+" (27 is a superset; 26+ still correctly describes the
  minimum). No change needed here unless the maintainer wants to call out
  27 specifically. Default: leave line 33 unchanged. (Only edit if the
  maintainer directs.)

### Step 2: Move the roadmap item into the supported-features list

- Line 149: remove the roadmap line "- **macOS 27 support** — compatibility with the next macOS release."
- In the "Menu bar item management" features section (around line 108-122)
  or a new top-level "Platform support" bullet, add a supported-features
  entry: "- macOS 27 (Golden Gate) support" (place it where the maintainer
  prefers; a natural spot is right after the opening features summary).

**Verify**: `grep -n "macOS 27 support" README.md` → the roadmap line is gone; `grep -n "macOS 27" README.md` → the supported-features mention exists.

### Step 3: Confirm the issue #687 banner stays

Leave `:14-18` as-is (the banner linking to the macOS 27 status issue). It
remains useful for tracking ongoing 27.x compatibility work.

**Verify**: `grep -n "issues/687" README.md` → still present.

## Test plan

Docs-only — no tests. Verification is the `grep` checks in each step.

## Done criteria

- [ ] Line 8 says "macOS 26 and 27" (or equivalent approved phrasing).
- [ ] The roadmap no longer lists "macOS 27 support" as a future item.
- [ ] A supported-features entry mentions macOS 27.
- [ ] The issue #687 banner is unchanged.
- [ ] No files outside `README.md` are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- The maintainer has not confirmed the branch is ready to merge — do not
  claim macOS 27 support in the README prematurely. Stop and confirm.
- `README.md` has already been updated for macOS 27 since this plan was
  written (drift) — re-read and reconcile rather than re-applying.
- The issue #687 banner has been removed or changed — adapt Step 3 to the
  live state.

## Maintenance notes

- When macOS 28 support lands, repeat this pattern (update line 8, move
  the roadmap item, keep the requirements badge at the minimum supported
  version).
- A reviewer should confirm the change lands in the SAME PR that merges
  the macOS 27 branch (or as its final squash commit) — not on `development`
  ahead of the feature.
