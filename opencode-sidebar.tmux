#!/usr/bin/env bash

# ============================================================================
# tmux-opencode - A tmux sidebar for monitoring OpenCode sessions
# https://github.com/g-battaglia/tmux-opencode
#
# Entry point for TPM (Tmux Plugin Manager).
# Reads user config, stores it in tmux env, and registers the toggle keybinding.
# ============================================================================

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ────────────────────────────────────────────────────
DEFAULT_KEY='\'
DEFAULT_WIDTH="32"
DEFAULT_REFRESH="3"
DEFAULT_CPU_THRESHOLD="5"

# ── Helpers ─────────────────────────────────────────────────────
get_option() {
  local value
  value="$(tmux show-option -gqv "$1")"
  [ -n "$value" ] && echo "$value" || echo "$2"
}

# ── Read User Config ────────────────────────────────────────────
key="$(get_option "@opencode-key" "$DEFAULT_KEY")"
width="$(get_option "@opencode-sidebar-width" "$DEFAULT_WIDTH")"
refresh="$(get_option "@opencode-refresh-interval" "$DEFAULT_REFRESH")"
cpu_threshold="$(get_option "@opencode-cpu-threshold" "$DEFAULT_CPU_THRESHOLD")"

# Store resolved config in tmux global env for render.sh to read
tmux set-option -g @opencode-sidebar-width "$width"
tmux set-option -g @opencode-refresh-interval "$refresh"
tmux set-option -g @opencode-cpu-threshold "$cpu_threshold"

# ── Register Keybinding ─────────────────────────────────────────
# Uses tmux if-shell for the toggle:
#   - check.sh returns 0 (sidebar exists)  -> close it via run-shell
#   - check.sh returns 1 (no sidebar)      -> open via split-window
#
# split-window must run as a tmux command (not inside run-shell)
# because it needs the current window context to create the pane.
tmux bind-key "$key" \
  if-shell "$CURRENT_DIR/scripts/check.sh" \
    "run-shell '$CURRENT_DIR/scripts/close.sh'" \
    "split-window -hbf -l $width '$CURRENT_DIR/scripts/render.sh'"
