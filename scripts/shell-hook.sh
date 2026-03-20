#!/usr/bin/env bash

# ============================================================================
# shell-hook.sh - Automatic exit code capture for tmux-opencode
# ============================================================================
#
# Source this file in your ~/.zshrc or ~/.bashrc:
#
#   source ~/.tmux/plugins/tmux-opencode/scripts/shell-hook.sh
#
# This hook automatically captures the exit code of `opencode` commands
# and writes it to /tmp/tmux-opencode/ so the sidebar can show red/green
# indicators after the process exits — no need to use an `oc` wrapper.
#
# How it works:
#   - zsh:  Uses precmd hook to check $? after each command
#   - bash: Uses PROMPT_COMMAND to check $? after each command
#   - Both: Reads the last command from history to detect if it was `opencode`
#
# Compatibility: bash 3.2+ (macOS default), zsh 5.0+
# ============================================================================

# Only activate inside tmux
[ -z "$TMUX" ] && return 0

_tmux_opencode_hook() {
  local last_exit=$?

  # Get the last command executed (first word only)
  local last_cmd=""
  if [ -n "$ZSH_VERSION" ]; then
    # zsh: $history array, most recent entry
    last_cmd="${history[$HISTCMD]}"
  elif [ -n "$BASH_VERSION" ]; then
    # bash: HISTCMD-1 because PROMPT_COMMAND runs before the new entry
    last_cmd="$(HISTTIMEFORMAT='' builtin history 1 2>/dev/null)"
    # Strip leading whitespace and history number
    last_cmd="${last_cmd#"${last_cmd%%[! ]*}"}"  # ltrim
    last_cmd="${last_cmd#*[0-9] }"               # remove "  123  " prefix
    last_cmd="${last_cmd#"${last_cmd%%[! ]*}"}"  # ltrim again
  fi

  # Extract first word (the command name)
  local cmd_name="${last_cmd%% *}"
  # Also handle paths like /usr/local/bin/opencode
  cmd_name="${cmd_name##*/}"

  # Only act on opencode commands
  [ "$cmd_name" != "opencode" ] && return "$last_exit"

  # Write exit code to the shared location
  local pane_id
  pane_id="$(tmux display-message -p '#{pane_id}' 2>/dev/null)" || return "$last_exit"
  [ -z "$pane_id" ] && return "$last_exit"

  mkdir -p /tmp/tmux-opencode 2>/dev/null
  echo "$last_exit" > "/tmp/tmux-opencode/${pane_id//[^%0-9]/}"

  return "$last_exit"
}

# Register the hook for the appropriate shell
if [ -n "$ZSH_VERSION" ]; then
  # zsh: add to precmd_functions array (avoids overwriting existing hooks)
  autoload -Uz add-zsh-hook 2>/dev/null
  if typeset -f add-zsh-hook > /dev/null 2>&1; then
    add-zsh-hook precmd _tmux_opencode_hook
  else
    # Fallback if add-zsh-hook is not available
    precmd_functions+=(_tmux_opencode_hook)
  fi
elif [ -n "$BASH_VERSION" ]; then
  # bash: prepend to PROMPT_COMMAND so we capture $? before other hooks modify it
  if [ -z "$PROMPT_COMMAND" ]; then
    PROMPT_COMMAND="_tmux_opencode_hook"
  else
    PROMPT_COMMAND="_tmux_opencode_hook;${PROMPT_COMMAND}"
  fi
fi
