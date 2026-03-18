#!/usr/bin/env bash

# render.sh - Main rendering loop for the tmux-opencode sidebar
# Runs inside the sidebar pane, refreshes periodically, handles navigation
#
# Architecture:
#   - Input via read -t 1 (returns instantly on keypress, 1s timeout on idle)
#   - Data (tmux sessions/panes/CPU) refreshed every N idle cycles
#   - Uses cursor-home + clear-to-EOL to avoid flicker (no full clear)
#   - Full frame buffered then flushed at once

# Note: NOT using set -e because read -t returns >128 on timeout
set -uo pipefail

# ── Colors (ANSI) ───────────────────────────────────────────────
RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
YELLOW=$'\033[33m'
GREEN=$'\033[32m'
RED=$'\033[31m'
CYAN=$'\033[36m'
WHITE=$'\033[37m'
BG_SELECT=$'\033[48;5;236m'
CLR=$'\033[K'

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

REFRESH_SECS="$(get_option "@opencode-refresh-interval" "3")"
CPU_THRESHOLD="$(get_option "@opencode-cpu-threshold" "5")"
WIDTH="$(get_option "@opencode-sidebar-width" "32")"
SIDEBAR_PANE="$(tmux display-message -p '#{pane_id}')"

# Self-register so check.sh/close.sh can find us
tmux set-option -g @opencode-sidebar-pane "$SIDEBAR_PANE"

# ── State ───────────────────────────────────────────────────────
cursor=0
needs_redraw=1
idle_ticks=0

declare -a item_types=()
declare -a item_targets=()
declare -a item_displays=()
declare -a item_statuses=()

# ── Cleanup ─────────────────────────────────────────────────────
cleanup() {
  tmux set-option -gu @opencode-sidebar-pane 2>/dev/null || true
  tput cnorm 2>/dev/null || true
  printf "\033[?7h"  # re-enable line wrap
}
trap 'cleanup; exit 0' EXIT INT TERM

# Hide cursor, disable line wrap
tput civis 2>/dev/null || true
printf "\033[?7l"

# ── Functions ───────────────────────────────────────────────────

get_opencode_status() {
  local pane_pid="$1"
  local pane_cmd="$2"
  local pane_id="$3"

  if [ "$pane_cmd" = "opencode" ]; then
    local oc_pid
    oc_pid="$(pgrep -P "$pane_pid" -x opencode 2>/dev/null | head -1)"
    [ -z "$oc_pid" ] && oc_pid="$pane_pid"

    local cpu
    cpu="$(ps -p "$oc_pid" -o %cpu= 2>/dev/null | tr -d ' ')"
    [ -z "$cpu" ] && return

    local cpu_int="${cpu%%.*}"
    [ -z "$cpu_int" ] && cpu_int=0

    if [ "$cpu_int" -ge "$CPU_THRESHOLD" ]; then
      echo "working"
    else
      echo "idle"
    fi
    return
  fi

  # Check exit code from wrapper (oc function)
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

collect_data() {
  # Snapshot old state to detect changes
  local old_snap=""
  local i
  for i in "${!item_displays[@]}"; do
    old_snap+="${item_displays[$i]}:${item_statuses[$i]}|"
  done

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

    item_types+=("header")
    item_targets+=("")
    item_displays+=("$session")
    item_statuses+=("")

    local windows
    windows="$(tmux list-windows -t "$session" -F '#{window_index}|#{window_name}' 2>/dev/null)" || continue

    while IFS='|' read -r win_idx win_name; do
      [ -z "$win_idx" ] && continue

      local target="${session}:${win_idx}"
      local best_status=""
      local panes
      panes="$(tmux list-panes -t "$target" -F '#{pane_id}|#{pane_pid}|#{pane_current_command}' 2>/dev/null)" || continue

      while IFS='|' read -r p_id p_pid p_cmd; do
        [ "$p_id" = "$SIDEBAR_PANE" ] && continue
        [ -z "$p_pid" ] && continue

        local status
        status="$(get_opencode_status "$p_pid" "$p_cmd" "$p_id")"

        case "$status" in
          working) best_status="working" ;;
          error)   [ "$best_status" != "working" ] && best_status="error" ;;
          idle)    [ "$best_status" != "working" ] && [ "$best_status" != "error" ] && best_status="idle" ;;
          done)    [ "$best_status" != "working" ] && [ "$best_status" != "error" ] && [ "$best_status" != "idle" ] && best_status="done" ;;
        esac
      done <<< "$panes"

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

  # Trigger redraw only if data changed
  local new_snap=""
  for i in "${!item_displays[@]}"; do
    new_snap+="${item_displays[$i]}:${item_statuses[$i]}|"
  done
  [ "$old_snap" != "$new_snap" ] && needs_redraw=1
}

count_navigable() {
  local count=0
  for t in "${item_types[@]}"; do
    [ "$t" = "window" ] && count=$((count + 1))
  done
  echo "$count"
}

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

# Build entire frame into a buffer, flush at once (zero flicker)
render() {
  local buf=""
  local max_name=$((WIDTH - 10))

  buf+="\033[H"  # cursor home (overwrite in place, no clear)
  buf+="\n"
  buf+="  ${BOLD}${CYAN}OPENCODE${RESET}${CLR}\n"
  buf+="  ${DIM}"
  local i
  for ((i = 0; i < WIDTH - 4; i++)); do
    buf+="$DASH"
  done
  buf+="${RESET}\n"

  local nav=0
  local prev_type=""

  for i in "${!item_types[@]}"; do
    local type="${item_types[$i]}"
    local display="${item_displays[$i]}"
    local status="${item_statuses[$i]}"

    if [ "$type" = "header" ]; then
      [ -n "$prev_type" ] && buf+="\n"
      buf+="  ${BOLD}${WHITE}${display}${RESET}${CLR}\n"

    elif [ "$type" = "window" ]; then
      local indicator=" "
      case "$status" in
        working) indicator="${YELLOW}${DOT}${RESET}" ;;
        idle)    indicator="${GREEN}${DOT}${RESET}" ;;
        done)    indicator="${GREEN}${DOT}${RESET}" ;;
        error)   indicator="${RED}${DOT}${RESET}" ;;
      esac

      # Truncate
      if [ "${#display}" -gt "$max_name" ]; then
        display="${display:0:$((max_name - 2))}.."
      fi

      # Pad to fixed width
      local padded
      padded="$(printf "%-${max_name}s" "$display")"

      if [ "$nav" -eq "$cursor" ]; then
        buf+="  ${BG_SELECT}${WHITE}${LINE_V} ${padded}  ${indicator}  ${RESET}${CLR}\n"
      else
        buf+="  ${DIM}${LINE_V}${RESET} ${padded}  ${indicator}${CLR}\n"
      fi

      nav=$((nav + 1))
    fi

    prev_type="$type"
  done

  buf+="\n"
  buf+="  ${DIM}↑↓ move  enter go  q close${RESET}${CLR}\n"
  buf+="\033[J"  # clear everything below

  printf "%b" "$buf"
}

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

# Initial data load
collect_data
needs_redraw=1

while true; do
  # Clamp cursor
  max="$(count_navigable)"
  [ "$max" -eq 0 ] && max=1
  [ "$cursor" -ge "$max" ] && cursor=$((max - 1))
  [ "$cursor" -lt 0 ] && cursor=0

  # Redraw only when needed
  if [ "$needs_redraw" -eq 1 ]; then
    render
    needs_redraw=0
  fi

  # Wait for input (instant on keypress, 1s timeout on idle)
  # Capture exit code BEFORE || true masks it:
  #   0   = got a character (or Enter which gives empty string)
  #   1   = EOF
  #   >128 = timeout
  key=""
  rc=0
  IFS= read -rsn1 -t 1 key || rc=$?

  if [ "$rc" -gt 128 ]; then
    # Timeout -- no input for 1 second, count toward data refresh
    idle_ticks=$((idle_ticks + 1))
    if [ "$idle_ticks" -ge "$REFRESH_SECS" ]; then
      idle_ticks=0
      collect_data
    fi
  elif [ -z "$key" ]; then
    # Enter key (read returned 0 with empty string)
    switch_to_selected
  else
    # Got a character
    case "$key" in
      j) cursor=$((cursor + 1)); needs_redraw=1 ;;
      k) cursor=$((cursor - 1)); needs_redraw=1 ;;
      G) cursor=$(($(count_navigable) - 1)); needs_redraw=1 ;;
      g) cursor=0; needs_redraw=1 ;;
      q)
        tmux kill-pane -t "$SIDEBAR_PANE" 2>/dev/null || true
        exit 0
        ;;
      $'\x1b')
        # Arrow key: ESC [ A/B
        bracket=""
        IFS= read -rsn1 -t 1 bracket 2>/dev/null || true
        if [ "$bracket" = "[" ]; then
          arrow=""
          IFS= read -rsn1 -t 1 arrow 2>/dev/null || true
          case "$arrow" in
            A) cursor=$((cursor - 1)); needs_redraw=1 ;;  # Up
            B) cursor=$((cursor + 1)); needs_redraw=1 ;;  # Down
          esac
        fi
        ;;
    esac
    idle_ticks=0
  fi
done
