# Plan 031: Document teardown/undo and env vars for `setup-headroom-claude.sh`

> **Executor instructions**: Follow this plan step by step.

> **Drift check (run first)**:
> `git diff --stat 87b0e507..HEAD -- scripts/setup-headroom-claude.sh scripts/README.md`
> If either file changed since this plan was written, re-read the cited lines.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `87b0e507`, 2026-07-01

## Why this matters

`scripts/setup-headroom-claude.sh` (477 lines, new on this branch) is a
one-shot Headroom + Claude Code CLI setup. Two DX gaps:

1. **No teardown/undo documented**: `headroom init claude -g` (`:422`)
   sets global `~/.claude/settings.json` `ANTHROPIC_BASE_URL` to the
   proxy, rerouting ALL `claude` CLI traffic (not just the
   `claude-headroom` launcher). The proxy is started via `nohup … &`
   (`:437-448`) and never stopped. `print_next_steps` (`:351-374`)
   documents daily use but has NO instruction to stop the proxy or
   restore `settings.json`. If the proxy dies or the machine reboots,
   plain `claude` breaks with connection-refused until `settings.json`
   is restored — and the user has no documented way to undo the global
   reroute.

2. **Undocumented env vars**: `:32-35` reads `HEADROOM_ENV`,
   `HEADROOM_PORT`, `INSTALLER`, `PIP_PYTHON` from the environment, but
   neither `usage()` (`:44-55`) nor `scripts/README.md:50-67` documents
   them (only the flag forms are). A user who exports `HEADROOM_PORT=9000`
   gets a different port than a teammate running `--port 8787` with no
   explanation.

## Current state

- `scripts/setup-headroom-claude.sh:422` — `headroom init claude -g`.
- `:437-448` — `nohup "$HEADROOM_BIN" proxy --port "$HEADROOM_PORT" … &`.
- `:319-329` — `read_settings_base_url` confirms `ANTHROPIC_BASE_URL` is
  the persisted lever.
- `:351-374` — `print_next_steps` (no undo section).
- `:32-35` — env var reads.

## Commands you will need

| Purpose | Command | Expected on success |
|--------|---------|---------------------|
| Script syntax check | `bash -n scripts/setup-headroom-claude.sh` | exit 0 |
| `--check` still works | `./scripts/setup-headroom-claude.sh --check` (only if headroom installed) | exit 0 |

## Scope

**In scope**:
- `scripts/setup-headroom-claude.sh` (add a "Stop / undo" block to `print_next_steps`; add env vars to `usage()`)
- `scripts/README.md` (document env vars + teardown)

**Out of scope**:
- Do NOT change the script's install/configure behavior — only docs.
- Do NOT add an `--uninstall` flag (a separate enhancement; this plan
  documents the manual undo path; an `--uninstall` flag can be a
  follow-up).

## Git workflow

- Branch: `advisor/031-headroom-script-dx`
- Commit style: `docs(scripts): document headroom teardown/undo and env vars`

## Steps

### Step 1: Add a "Stop / undo" block to `print_next_steps`

In `scripts/setup-headroom-claude.sh`'s `print_next_steps` (`:351-374`),
append a block:

```bash
Stop / undo:
  pkill -f 'headroom proxy'                                    # stop the proxy
  # Restore plain `claude` (removes the global ANTHROPIC_BASE_URL reroute):
  ${HEADROOM_BIN} init claude -g --undo   # if headroom supports --undo
  # or manually: edit ~/.claude/settings.json and remove ANTHROPIC_BASE_URL

Note: \`headroom init claude -g\` reroutes ALL \`claude\` usage through the
proxy (not just the \`claude-headroom\` launcher). If the proxy is down,
plain \`claude\` will fail until settings.json is restored.
```

If `headroom init claude -g --undo` is not a real command (verify by
running `headroom init claude --help` if headroom is installed, or check
headroom's docs), document the manual `settings.json` edit as the
primary path and note the `--undo` flag as "if supported."

**Verify**: `bash -n scripts/setup-headroom-claude.sh` → exit 0.

### Step 2: Document env vars in `usage()` and `scripts/README.md`

In `usage()` (`:44-55`), add an "Environment variables" section:
```
Environment variables (flags override these):
  HEADROOM_ENV      Micromamba env name (default: headroom)
  HEADROOM_PORT     Proxy port (default: 8787)
  INSTALLER         auto | micromamba | pip | pipx
  PIP_PYTHON        Python binary for pip/pipx
```

In `scripts/README.md`, add the same table to the `setup-headroom-claude.sh`
section (after the Examples, `:60-67`).

### Step 3: Optionally have `--check` verify the launcher

If time permits, extend `--check` (`:378-405`) to also verify
`~/.local/bin/claude-headroom` exists and points at the recorded
`HEADROOM_BIN` (read from `~/.config/headroom/setup.env`). This is a
small robustness addition; skip if it complicates the check path.

**Verify**: `bash -n scripts/setup-headroom-claude.sh` → exit 0; `./scripts/setup-headroom-claude.sh --check` (if headroom installed) → exit 0.

## Test plan

- No automated tests for the script (it's a contributor tooling script).
- Verification: `bash -n` (syntax) + a manual read of the rendered
  `print_next_steps` / `usage` output.

## Done criteria

- [ ] `print_next_steps` includes a "Stop / undo" block with the `pkill` and `settings.json` restore path.
- [ ] `usage()` and `scripts/README.md` document the 4 env vars.
- [ ] A warning notes that `-g` reroutes ALL `claude` usage.
- [ ] `bash -n scripts/setup-headroom-claude.sh` exits 0.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- `headroom init claude -g --undo` is not a real command and the manual
  `settings.json` edit is ambiguous (e.g. headroom adds other settings
  too) — document the safest manual restore (remove the
  `ANTHROPIC_BASE_URL` key and any proxy-specific keys headroom added;
  point to headroom's own docs for the canonical undo).
- The script has changed substantially since this plan was written
  (drift) — re-read and adapt.

## Maintenance notes

- An `--uninstall` flag (automating the teardown) is a natural follow-up
  — note it as deferred.
- A reviewer should run `./scripts/setup-headroom-claude.sh --check`
  after the change and confirm the output is accurate.
- The supply-chain dimension (the script installs an unpinned PyPI
  package and routes API traffic through it) is a separate consideration
  — this plan documents the DX/teardown, not the supply-chain posture.
  The maintainer may want to pin the headroom version in a follow-up.
