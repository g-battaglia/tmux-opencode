# tmux-opencode

A tmux sidebar plugin for monitoring [OpenCode](https://opencode.ai) sessions across all your tmux windows.

See at a glance which OpenCode instances are working, idle, or have exited with errors -- and jump to any window with a keystroke.

## Features

- **Live status indicators** for every OpenCode instance across all tmux sessions
  - `●` yellow -- OpenCode is actively working (agent running)
  - `●` green -- OpenCode is idle (waiting for input)
  - `●` red -- OpenCode exited with an error (requires shell wrapper)
- **Interactive navigation** -- move through the list with `j`/`k` or arrow keys, press `Enter` to jump to any window
- **Toggle on/off** with a single keybinding (`prefix + \`)
- **Auto-refresh** every 2 seconds (configurable)
- **Zero dependencies** -- pure bash, no external tools required

## Requirements

- tmux >= 3.2
- bash >= 4
- [OpenCode](https://opencode.ai)

## Installation

### With [TPM](https://github.com/tmux-plugins/tpm) (recommended)

Add to your `~/.tmux.conf`:

```bash
set -g @plugin 'g-battaglia/tmux-opencode'
```

Then press `prefix + I` to install.

### Manual

```bash
git clone https://github.com/g-battaglia/tmux-opencode.git ~/.tmux/plugins/tmux-opencode
```

Add to your `~/.tmux.conf`:

```bash
run-shell ~/.tmux/plugins/tmux-opencode/opencode-sidebar.tmux
```

Reload tmux config:

```bash
tmux source-file ~/.tmux.conf
```

## Usage

| Key | Action |
|-----|--------|
| `prefix + \` | Toggle sidebar open/close |
| `j` / `Down` | Move cursor down |
| `k` / `Up` | Move cursor up |
| `G` | Jump to bottom |
| `Enter` | Switch to selected window and close sidebar |
| `q` | Close sidebar |

## Status Detection

The plugin detects OpenCode status by checking the CPU usage of each OpenCode process:

- **Working** (yellow): CPU usage >= 5% (agent is running, tools executing, LLM streaming)
- **Idle** (green): CPU usage < 5% (waiting for user input)

### Error Detection (optional)

To enable red indicators for OpenCode processes that exited with an error, add this function to your `~/.zshrc` or `~/.bashrc`:

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

Then launch OpenCode with `oc` instead of `opencode`. The plugin will show:

- `●` green -- exited successfully (exit code 0)
- `●` red -- exited with error (exit code > 0)

## Configuration

Add these to your `~/.tmux.conf` **before** the plugin is loaded:

```bash
# Change the toggle key (default: \)
set -g @opencode-key '\'

# Sidebar width in columns (default: 32)
set -g @opencode-sidebar-width '32'

# Refresh interval in seconds (default: 2)
set -g @opencode-refresh-interval '2'

# CPU threshold percentage to consider OpenCode "working" (default: 5)
set -g @opencode-cpu-threshold '5'
```

## How It Works

The plugin creates a narrow pane on the left side of your current window. Inside that pane, a bash script loops every N seconds:

1. Queries all tmux sessions and windows via `tmux list-panes`
2. For each pane running `opencode`, checks CPU usage via `ps`
3. Renders a navigable list with colored status indicators
4. Listens for keyboard input for navigation and window switching

The sidebar pane filters itself out of the list automatically.

## License

[MIT](LICENSE)
