#!/usr/bin/env bash

# render.sh - Main rendering loop for the tmux-opencode sidebar
# Runs inside the sidebar pane, refreshes periodically, handles navigation

# Note: NOT using set -e because read -t returns >128 on timeout
set -uo pipefail

# ── Colors ──────────────────────────────────────────────────────
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
YELLOW="\033[33m"
GREEN="\033[32m"
RED="\033[31m"
CYAN="\033[36m"
WHITE="\033[37m"
BG_SELECT="\033[48;5;236m"

# ── Symbols ─────────────────────────────────────────────────────
DOT="●"
LINE_V="│"
DASH="─"

# ── Config ──────────────────────────────────────────────────────
get_option() {
  local value
  value="$(tmux show-option -gqv "$1" 2>/dev/null)"
  [ -n "$value" ] && echo "$value" || echo "$2"
}

REFRESH="$(get_option "@opencode-refresh-interval" "2")"
CPU_THRESHOLD="$(get_option "@opencode-cpu-threshold" "5")"
WIDTH="$(get_option "@opencode-sidebar-width" "32")"
SIDEBAR_PANE="$(tmux display-message -p '#{pane_id}')"

# Self-register: store our pane ID so toggle.sh can find us
tmux set-option -g @opencode-sidebar-pane "$SIDEBAR_PANE"

# ── State ───────────────────────────────────────────────────────
cursor=0
declare -a item_types=()     # "header" | "window"
declare -a item_targets=()   # tmux target (session:win) for windows, empty for headers
declare -a item_displays=()  # formatted display text
declare -a item_statuses=()  # "working" | "idle" | "done" | "error" | ""

# ── Cleanup ─────────────────────────────────────────────────────
cleanup() {
  tmux set-option -gu @opencode-sidebar-pane 2>/dev/null || true
  tput cnorm 2>/dev/null || true
}
trap 'cleanup; exit 0' EXIT INT TERM

# Hide cursor
tput civis 2>/dev/null || true

# ── Functions ───────────────────────────────────────────────────

# Get the opencode process status for a pane
# Looks at pane_current_command, then checks CPU of the actual opencode PID
get_opencode_status() {
  local pane_pid="$1"
  local pane_cmd="$2"
  local pane_id="$3"

  if [ "$pane_cmd" = "opencode" ]; then
    # opencode is the foreground process -- find its actual PID
    local oc_pid
    oc_pid="$(pgrep -P "$pane_pid" -x opencode 2>/dev/null | head -1)"

    # Fallback: if pgrep didn't find a child, the shell may have been replaced
    [ -z "$oc_pid" ] && oc_pid="$pane_pid"

    local cpu
    cpu="$(ps -p "$oc_pid" -o %cpu= 2>/dev/null | tr -d ' ')"
    [ -z "$cpu" ] && return

    # Integer comparison (strip decimal)
    local cpu_int="${cpu%%.*}"
    [ -z "$cpu_int" ] && cpu_int=0

    if [ "$cpu_int" -ge "$CPU_THRESHOLD" ]; then
      echo "working"
    else
      echo "idle"
    fi
    return
  fi

  # opencode is NOT the foreground process -- check exit code from wrapper
  local exitfile="/tmp/tmux-opencode/${pane_id//[^%0-9]/}"
  if [ -f "$exitfile" ]; then
    local code
    code="$(cat "$exitfile" 2>/dev/null)"
    if [ "$code" = "0" ]; then
      echo "done"
    elif [ -n "$code" ]; then
      echo "error"
    fi
  fi
}

# Collect data from all sessions/windows/panes
collect_data() {
  item_types=()
  item_targets=()
  item_displays=()
  item_statuses=()

  local current_session current_window
  current_session="$(tmux display-message -p '#{session_name}')"
  current_window="$(tmux display-message -p '#{window_index}')"

  local sessions
  sessions="$(tmux list-sessions -F '#{session_name}' 2>/dev/null)" || return

  while IFS= read -r session; do
    [ -z "$session" ] && continue

    # Session header
    item_types+=("header")
    item_targets+=("")
    item_displays+=("$session")
    item_statuses+=("")

    # Windows in this session
    local windows
    windows="$(tmux list-windows -t "$session" -F '#{window_index}|#{window_name}' 2>/dev/null)" || continue

    while IFS='|' read -r win_idx win_name; do
      [ -z "$win_idx" ] && continue

      local target="${session}:${win_idx}"

      # Check all panes in this window for opencode
      local best_status=""
      local panes
      panes="$(tmux list-panes -t "$target" -F '#{pane_id}|#{pane_pid}|#{pane_current_command}' 2>/dev/null)" || continue

      while IFS='|' read -r p_id p_pid p_cmd; do
        # Skip the sidebar pane
        [ "$p_id" = "$SIDEBAR_PANE" ] && continue
        [ -z "$p_pid" ] && continue

        local status
        status="$(get_opencode_status "$p_pid" "$p_cmd" "$p_id")"

        # Priority: working > error > idle/done > ""
        case "$status" in
          working)
            best_status="working"
            ;;
          error)
            [ "$best_status" != "working" ] && best_status="error"
            ;;
          idle)
            [ "$best_status" != "working" ] && [ "$best_status" != "error" ] && best_status="idle"
            ;;
          done)
            [ "$best_status" != "working" ] && [ "$best_status" != "error" ] && [ "$best_status" != "idle" ] && best_status="done"
            ;;
        esac
      done <<< "$panes"

      # Mark current window
      local marker=""
      if [ "$session" = "$current_session" ] && [ "$win_idx" = "$current_window" ]; then
        marker=" *"
      fi

      item_types+=("window")
      item_targets+=("$target")
      item_displays+=("${win_idx}: ${win_name}${marker}")
      item_statuses+=("$best_status")
    done <<< "$windows"

  done <<< "$sessions"
}

# Count navigable items (windows only, not headers)
count_navigable() {
  local count=0
  for t in "${item_types[@]}"; do
    [ "$t" = "window" ] && count=$((count + 1))
  done
  echo "$count"
}

# Get the tmux target for the item at the current cursor position
get_selected_target() {
  local nav=0
  for i in "${!item_types[@]}"; do
    if [ "${item_types[$i]}" = "window" ]; then
      if [ "$nav" -eq "$cursor" ]; then
        echo "${item_targets[$i]}"
        return
      fi
      nav=$((nav + 1))
    fi
  done
}

# Render the sidebar
render() {
  printf "\033[2J\033[H"  # clear + home

  # Header
  printf "\n"
  printf "  ${BOLD}${CYAN}OPENCODE${RESET}\n"
  printf "  ${DIM}"
  local i
  for ((i = 0; i < WIDTH - 4; i++)); do
    printf "%s" "$DASH"
  done
  printf "${RESET}\n"

  local nav=0
  local prev_type=""

  for i in "${!item_types[@]}"; do
    local type="${item_types[$i]}"
    local display="${item_displays[$i]}"
    local status="${item_statuses[$i]}"

    if [ "$type" = "header" ]; then
      # Add spacing between sessions
      [ -n "$prev_type" ] && printf "\n"
      printf "  ${BOLD}${WHITE}%s${RESET}\n" "$display"
    elif [ "$type" = "window" ]; then
      # Status indicator
      local indicator=" "
      case "$status" in
        working) indicator="${YELLOW}${DOT}${RESET}" ;;
        idle)    indicator="${GREEN}${DOT}${RESET}" ;;
        done)    indicator="${GREEN}${DOT}${RESET}" ;;
        error)   indicator="${RED}${DOT}${RESET}" ;;
      esac

      # Truncate long names
      local max_len=$((WIDTH - 8))
      if [ "${#display}" -gt "$max_len" ]; then
        display="${display:0:$((max_len - 1))}.."
      fi

      # Render line (highlighted if selected)
      if [ "$nav" -eq "$cursor" ]; then
        printf "  ${BG_SELECT}${WHITE}${LINE_V} %-$((WIDTH - 6))s %b ${RESET}\n" "$display" "$indicator"
      else
        printf "  ${DIM}${LINE_V}${RESET} %-$((WIDTH - 6))s %b\n" "$display" "$indicator"
      fi

      nav=$((nav + 1))
    fi

    prev_type="$type"
  done

  # Footer
  printf "\n"
  printf "  ${DIM}j/k move  enter go  q close${RESET}\n"
}

# Switch to the selected window and close sidebar
switch_to_selected() {
  local target
  target="$(get_selected_target)"
  [ -z "$target" ] && return

  local session="${target%%:*}"
  tmux switch-client -t "$session" 2>/dev/null || true
  tmux select-window -t "$target" 2>/dev/null || true
  tmux kill-pane -t "$SIDEBAR_PANE" 2>/dev/null || true
  exit 0
}

# ── Main Loop ───────────────────────────────────────────────────

while true; do
  collect_data

  # Clamp cursor
  max="$(count_navigable)"
  [ "$max" -eq 0 ] && max=1
  [ "$cursor" -ge "$max" ] && cursor=$((max - 1))
  [ "$cursor" -lt 0 ] && cursor=0

  render

  # Wait for input or refresh timeout
  key=""
  IFS= read -rsn1 -t "$REFRESH" key
  read_exit=$?

  if [ "$read_exit" -eq 0 ]; then
    # Got input
    if [ -z "$key" ]; then
      # Enter key (empty string, exit 0)
      switch_to_selected
    else
      case "$key" in
        j) cursor=$((cursor + 1)) ;;
        k) cursor=$((cursor - 1)) ;;
        G) cursor=$(($(count_navigable) - 1)) ;;  # go to bottom
        q)
          tmux kill-pane -t "$SIDEBAR_PANE" 2>/dev/null || true
          exit 0
          ;;
        $'\x1b')
          # Escape sequence -- read arrow keys
          seq=""
          IFS= read -rsn2 -t 0.1 seq 2>/dev/null || true
          case "$seq" in
            '[A') cursor=$((cursor - 1)) ;;  # Up
            '[B') cursor=$((cursor + 1)) ;;  # Down
          esac
          ;;
      esac
    fi
  fi
  # else: timeout, just refresh
done
