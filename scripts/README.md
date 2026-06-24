# Scripts

Helper scripts for local Thaw development and Claude Code tooling.

## `thaw-devrun.sh`

Builds the **Debug** configuration and runs it from `/Applications/Thaw Debug.app`.

On macOS 27, menu bar items need a clean code identity and a canonical `/Applications` install path. Running straight from DerivedData can cause Thaw’s own icon to disappear when items are hidden. This script:

1. Builds the Debug scheme
2. Quits any running Thaw Debug instance (app + XPC service)
3. Replaces `/Applications/Thaw Debug.app` with the fresh build
4. Launches it

```bash
./scripts/thaw-devrun.sh
```

First launch after install: grant **Accessibility** and **Screen Recording** when prompted.

## `thaw-reset.sh`

Resets Thaw’s local macOS state for a clean test run.

**Default** — quits Thaw, clears TCC permissions (Accessibility, Screen Recording, etc.), and deletes UserDefaults.

**`--hard`** — also removes logs, Application Support data, and saved window state.

```bash
./scripts/thaw-reset.sh
./scripts/thaw-reset.sh --hard
```

Thaw will re-prompt for permissions on the next launch.

## `setup-headroom-claude.sh`

One-shot setup for **Headroom** token compression with the **Claude Code CLI** (terminal). Does not apply to Claude Desktop in normal subscription mode — Desktop routes API traffic directly and ignores `ANTHROPIC_BASE_URL`.

The script:

1. Installs `headroom-ai[proxy,mcp]` (micromamba, pip, or pipx)
2. Configures `~/.claude/settings.json` via `headroom init claude -g`
3. Registers the Headroom MCP server with an absolute binary path
4. Installs `~/.local/bin/claude-headroom` (proxy + claude launcher)
5. Starts the proxy on port 8787 if needed
6. Runs `headroom doctor`

### Installers

| Flag | Behavior |
|------|----------|
| `--installer auto` | micromamba → pipx → pip (default) |
| `--installer micromamba` | Isolated conda env (`--env`, default: `headroom`) |
| `--installer pip` | `python3 -m pip install --user` |
| `--installer pipx` | Isolated pipx app |

### Examples

```bash
./scripts/setup-headroom-claude.sh
./scripts/setup-headroom-claude.sh --installer pip --python python3.12
./scripts/setup-headroom-claude.sh --installer micromamba --env base
./scripts/setup-headroom-claude.sh --check          # verify only
./scripts/setup-headroom-claude.sh --skip-install   # configure, don't reinstall
```

### Daily use

```bash
claude-headroom              # start proxy + claude with compression
claude-headroom -- --resume <session-id>
```

Or run `claude` directly when the proxy is already up.
