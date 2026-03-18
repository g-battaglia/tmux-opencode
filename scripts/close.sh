#!/usr/bin/env bash

# close.sh - Closes the sidebar pane

SIDEBAR_ID="$(tmux show-option -gqv @opencode-sidebar-pane 2>/dev/null)"

if [ -n "$SIDEBAR_ID" ]; then
  tmux kill-pane -t "$SIDEBAR_ID" 2>/dev/null
  tmux set-option -gu @opencode-sidebar-pane 2>/dev/null
fi
