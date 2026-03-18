#!/usr/bin/env bash

# check.sh - Returns 0 if sidebar exists, 1 if not
# Used by tmux if-shell to decide open vs close

SIDEBAR_ID="$(tmux show-option -gqv @opencode-sidebar-pane 2>/dev/null)"

if [ -n "$SIDEBAR_ID" ] && tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$SIDEBAR_ID"; then
  exit 0  # sidebar exists
else
  # Clean stale option
  tmux set-option -gu @opencode-sidebar-pane 2>/dev/null
  exit 1  # sidebar doesn't exist
fi
