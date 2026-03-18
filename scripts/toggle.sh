#!/usr/bin/env bash

# toggle.sh - Opens or closes the opencode sidebar pane

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

get_option() {
  local value
  value="$(tmux show-option -gqv "$1")"
  [ -n "$value" ] && echo "$value" || echo "$2"
}

WIDTH="$(get_option "@opencode-sidebar-width" "32")"

# Get the stored sidebar pane ID for the current window
SIDEBAR_ID="$(tmux show-option -qv @opencode-sidebar-pane 2>/dev/null)"

# Check if sidebar pane still exists
sidebar_exists() {
  [ -n "$SIDEBAR_ID" ] && tmux list-panes -F '#{pane_id}' 2>/dev/null | grep -qF "$SIDEBAR_ID"
}

if sidebar_exists; then
  # Close sidebar
  tmux kill-pane -t "$SIDEBAR_ID" 2>/dev/null
  tmux set-option -u @opencode-sidebar-pane 2>/dev/null
else
  # Remember current pane to refocus after split
  CURRENT_PANE="$(tmux display-message -p '#{pane_id}')"

  # Open sidebar: split left, full height, don't focus it yet
  SIDEBAR_ID="$(tmux split-window -hbf -l "$WIDTH" \
    -P -F '#{pane_id}' \
    "TMUX_OPENCODE_SIDEBAR=1 bash '$CURRENT_DIR/render.sh'")"

  # Store sidebar pane ID
  tmux set-option @opencode-sidebar-pane "$SIDEBAR_ID"

  # Refocus the original pane
  tmux select-pane -t "$CURRENT_PANE"
fi
