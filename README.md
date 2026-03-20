# tmux-opencode

A tmux sidebar for monitoring [OpenCode](https://opencode.ai) instances across all your sessions.

See at a glance which OpenCode agents are working, idle, or have exited with errors — and jump to any window with a keystroke.

```
  OPENCODE
  ────────────────────────────

  my-project
  │ 0: opencode          ●    ← yellow: working
  │ 1: lazygit

  api-service
  │ 0: opencode          ●    ← green: idle
  │ 1: zsh

  frontend
  │ 0: opencode          ●    ← red: error
  │ 1: opencode          ●    ← green: idle

  ↑↓ move  enter go  q close
```

## Features

- **Live status indicators** for every OpenCode instance
  - `●` yellow — agent is actively working (CPU ≥ 5%)
  - `●` green — idle, waiting for input (CPU < 5%)
  - `●` red — exited with error (requires optional shell wrapper)
- **Interactive** — navigate with `j`/`k` or arrow keys, press `Enter` to jump
- **Toggle** with `prefix + \` (configurable)
- **Zero flicker** — synchronized output protocol + alternate screen buffer
- **Lightweight** — single batch `tmux list-panes` call per refresh cycle
- **Zero dependencies** — pure bash, works with macOS default bash 3.2

## Requirements

- tmux ≥ 3.2
- bash ≥ 3.2
- [OpenCode](https://opencode.ai)

## Installation

### With [TPM](https://github.com/tmux-plugins/tpm) (recommended)

Add to your `~/.tmux.conf`:

```tmux
set -g @plugin 'g-battaglia/tmux-opencode'
```

Press `prefix + I` to install.

### Manual

```bash
git clone https://github.com/g-battaglia/tmux-opencode.git ~/.tmux/plugins/tmux-opencode
```

Add to your `~/.tmux.conf`:

```tmux
run-shell ~/.tmux/plugins/tmux-opencode/opencode-sidebar.tmux
```

Reload: `tmux source-file ~/.tmux.conf`

## Keybindings

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `prefix + \`     | Toggle sidebar open / close             |
| `j` / `↓`        | Move cursor down                        |
| `k` / `↑`        | Move cursor up                          |
| `g`              | Jump to top                             |
| `G`              | Jump to bottom                          |
| `Enter`          | Switch to selected window, close sidebar|
| `q`              | Close sidebar                           |

## Status Detection

The plugin detects OpenCode status by checking CPU usage of each process:

- **Working** (yellow): CPU ≥ 5% — agent running, tools executing, LLM streaming
- **Idle** (green): CPU < 5% — waiting for user input

The plugin uses hysteresis to prevent status flickering near the CPU threshold: transitioning from idle to working requires CPU ≥ 5%, but transitioning back from working to idle requires CPU to drop below 2.5%. This eliminates rapid yellow/green toggling.

The current window is marked with `*`.

### Exit Code Detection

To enable red/green indicators after OpenCode exits, add this to your `~/.zshrc` or `~/.bashrc`:

```bash
source ~/.tmux/plugins/tmux-opencode/scripts/shell-hook.sh
```

The hook automatically detects when `opencode` exits and captures the exit code. No need to use a wrapper or alias — just run `opencode` as usual. The plugin will show:

- `●` green — exited successfully (exit code 0)
- `●` red — exited with error (exit code > 0)
- `●` dim — exited but no exit code available (hook not installed)

> **Note**: The hook only activates inside tmux sessions and has zero overhead for non-opencode commands.

<details>
<summary>Alternative: manual <code>oc</code> wrapper (legacy)</summary>

If you prefer not to source the hook, you can define a wrapper function instead:

```bash
oc() {
  opencode "$@"
  local code=$?
  mkdir -p /tmp/tmux-opencode
  local pane_id
  pane_id="$(tmux display-message -p '#{pane_id}' 2>/dev/null)"
  [ -n "$pane_id" ] && echo "$code" > "/tmp/tmux-opencode/${pane_id//[^%0-9]/}"
  return $code
}
```

Launch with `oc` instead of `opencode`.

</details>

## Configuration

Add to `~/.tmux.conf` **before** the plugin is loaded:

```tmux
# Toggle key (default: \)
set -g @opencode-key '\'

# Sidebar width in columns (default: 32)
set -g @opencode-sidebar-width '32'

# Data refresh interval in seconds (default: 3)
set -g @opencode-refresh-interval '3'

# CPU % threshold to consider "working" (default: 5)
set -g @opencode-cpu-threshold '5'
```

## How It Works

**Toggle architecture**: The keybinding uses tmux `if-shell` to check whether the sidebar pane exists. If it does, `close.sh` kills it. If not, `split-window` creates a left-side pane running `render.sh`.

**Render loop**: `render.sh` runs inside the sidebar pane:

1. One `tmux list-panes -a` call fetches all sessions/windows/panes in a single batch
2. For each pane running `opencode`, checks CPU via `ps` to determine working vs idle
3. Builds the entire frame in a string buffer
4. Flushes atomically using the synchronized output protocol (DEC 2026)
5. Polls for keyboard input with `read -t 1` (instant response, 1s idle timeout)
6. Refreshes data every N idle seconds (default: 3)

The sidebar pane filters itself out of the list automatically.

## License

[MIT](LICENSE)
