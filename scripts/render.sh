#!/usr/bin/env bash

# render.sh - Main rendering loop for the tmux-opencode sidebar
# Runs inside the sidebar pane, refreshes periodically, handles navigation
#
# Architecture:
#   - Input via read -t 1 (returns instantly on keypress, 1s timeout on idle)
#   - Data (tmux sessions/panes/CPU) refreshed every N idle cycles
#   - Synchronized output protocol (DEC 2026) for zero-flicker rendering
#   - Alternate screen buffer for clean canvas

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

# Synchronized output sequences (Alacritty, kitty, iTerm2, etc.)
SYNC_START=$'\033[?2026h'
SYNC_END=$'\033[?2026l'

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

item_types=()
item_targets=()
item_displays=()
item_statuses=()

# ── Terminal Setup ──────────────────────────────────────────────
# Save terminal state and disable echo + canonical mode
# -echo: prevents arrow key bytes from appearing on screen
# -icanon: char-at-a-time input (no line buffering)
# Keeps opost enabled so \n works correctly in output
saved_stty="$(stty -g 2>/dev/null)"
stty -echo -icanon 2>/dev/null

# Enter alternate screen buffer (like vim/less/htop)
printf "\033[?1049h"
# Hide cursor
printf "\033[?25l"
# Disable line wrap
printf "\033[?7l"

# ── Cleanup ─────────────────────────────────────────────────────
cleanup() {
  tmux set-option -gu @opencode-sidebar-pane 2>/dev/null || true
  printf "\033[?7h"        # re-enable line wrap
  printf "\033[?25h"       # show cursor
  printf "\033[?1049l"     # leave alternate screen buffer
  stty "$saved_stty" 2>/dev/null || stty sane 2>/dev/null  # restore terminal
}
trap 'cleanup; exit 0' EXIT INT TERM

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
  current_session="$(tmux display-message -p '#{session_name}' 2>/dev/null)" || current_session=""
  current_window="$(tmux display-message -p '#{window_index}' 2>/dev/null)" || current_window=""

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
  local t
  for t in "${item_types[@]}"; do
    [ "$t" = "window" ] && count=$((count + 1))
  done
  echo "$count"
}

get_selected_target() {
  local nav=0
  local i
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

render() {
  local buf=""
  local max_name=$((WIDTH - 10))
  local line_width=$((WIDTH - 2))

  # Begin synchronized output (terminal holds display until SYNC_END)
  buf+="${SYNC_START}"

  buf+="\033[H"  # cursor home
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
      # Determine indicator color and char separately (no embedded RESET)
      local ind_color="" ind_char=" "
      case "$status" in
        working) ind_color="$YELLOW"; ind_char="$DOT" ;;
        idle)    ind_color="$GREEN";  ind_char="$DOT" ;;
        done)    ind_color="$GREEN";  ind_char="$DOT" ;;
        error)   ind_color="$RED";    ind_char="$DOT" ;;
      esac

      # Truncate
      if [ "${#display}" -gt "$max_name" ]; then
        display="${display:0:$((max_name - 2))}.."
      fi

      # Pad to fixed width
      local padded
      padded="$(printf "%-${max_name}s" "$display")"

      if [ "$nav" -eq "$cursor" ]; then
        # Selected: BG_SELECT spans entire line including after the dot
        buf+="  ${BG_SELECT}${WHITE}${LINE_V} ${padded}  ${ind_color}${ind_char}${BG_SELECT}  ${RESET}${CLR}\n"
      else
        buf+="  ${DIM}${LINE_V}${RESET} ${padded}  ${ind_color}${ind_char}${RESET}${CLR}\n"
      fi

      nav=$((nav + 1))
    fi

    prev_type="$type"
  done

  buf+="\n"
  buf+="  ${DIM}↑↓ move  enter go  q close${RESET}${CLR}\n"
  buf+="\033[J"  # clear everything below

  # End synchronized output (terminal flushes entire frame at once)
  buf+="${SYNC_END}"

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
  #   rc=0    -> got a character (or Enter = empty string with rc=0)
  #   rc=1    -> EOF (tmux resize, signals, etc.) -- IGNORE, do not exit
  #   rc>128  -> timeout (no input)
  key=""
  rc=0
  IFS= read -rsn1 -t 1 key || rc=$?

  if [ "$rc" -gt 128 ]; then
    # Timeout -- count toward data refresh
    idle_ticks=$((idle_ticks + 1))
    if [ "$idle_ticks" -ge "$REFRESH_SECS" ]; then
      idle_ticks=0
      collect_data
    fi
  elif [ "$rc" -eq 1 ]; then
    # EOF -- ignore (tmux resize, focus event, etc.)
    :
  elif [ "$rc" -eq 0 ] && [ -z "$key" ]; then
    # Enter key (rc=0, empty string)
    switch_to_selected
  elif [ "$rc" -eq 0 ] && [ -n "$key" ]; then
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
