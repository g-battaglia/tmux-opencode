#!/usr/bin/env bash

# tmux-opencode: sidebar plugin for monitoring OpenCode sessions
# https://github.com/g-battaglia/tmux-opencode

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default options
default_key='\'
default_width="32"
default_refresh="2"
default_cpu_threshold="5"

# Read user-configurable options
get_option() {
  local option="$1"
  local default="$2"
  local value
  value="$(tmux show-option -gqv "$option")"
  if [ -z "$value" ]; then
    echo "$default"
  else
    echo "$value"
  fi
}

key="$(get_option "@opencode-key" "$default_key")"
width="$(get_option "@opencode-sidebar-width" "$default_width")"
refresh="$(get_option "@opencode-refresh-interval" "$default_refresh")"
cpu_threshold="$(get_option "@opencode-cpu-threshold" "$default_cpu_threshold")"

# Store config in tmux env for scripts to read
tmux set-option -g @opencode-sidebar-width "$width"
tmux set-option -g @opencode-refresh-interval "$refresh"
tmux set-option -g @opencode-cpu-threshold "$cpu_threshold"

# Register keybinding
tmux bind-key "$key" run-shell "$CURRENT_DIR/scripts/toggle.sh"
