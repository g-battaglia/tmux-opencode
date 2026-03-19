#!/usr/bin/env bash

# ============================================================================
# render.sh - Main rendering loop for the tmux-opencode sidebar
# ============================================================================
#
# Architecture:
#   - Single `tmux list-panes -a` call per refresh (not per-session/window)
#   - Input polled via `read -t 1` (instant on keypress, 1s idle timeout)
#   - Data refreshed every N idle seconds (configurable)
#   - Synchronized output protocol (DEC 2026) for atomic frame rendering
#   - Alternate screen buffer + stty raw mode for clean I/O
#
# Compatibility:
#   - bash 3.2+ (macOS default) -- no bashisms requiring bash 4+
#   - tmux 3.2+ (for split-window -f full-width splits)
#   - macOS + Linux (ps/pgrep flags are POSIX-compatible)
# ============================================================================

# ── ANSI Escape Codes ───────────────────────────────────────────
RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
YELLOW=$'\033[33m'
GREEN=$'\033[32m'
RED=$'\033[31m'
CYAN=$'\033[36m'
WHITE=$'\033[37m'
BG_SELECT=$'\033[48;5;236m'
CLR=$'\033[K'          # clear to end of line
SYNC_START=$'\033[?2026h'  # begin synchronized output
SYNC_END=$'\033[?2026l'    # end synchronized output

# ── Symbols ─────────────────────────────────────────────────────
DOT="●"
LINE_V="│"
DASH="─"

# ── Read Config from tmux Environment ───────────────────────────
get_option() {
  local value
  value="$(tmux show-option -gqv "$1" 2>/dev/null)"
  [ -n "$value" ] && echo "$value" || echo "$2"
}

REFRESH_SECS="$(get_option "@opencode-refresh-interval" "3")"
CPU_THRESHOLD="$(get_option "@opencode-cpu-threshold" "5")"
WIDTH="$(get_option "@opencode-sidebar-width" "32")"
SIDEBAR_PANE="$(tmux display-message -p '#{pane_id}')"

# Self-register so check.sh / close.sh can find this pane
tmux set-option -g @opencode-sidebar-pane "$SIDEBAR_PANE"

# ── Precomputed Constants ───────────────────────────────────────
MAX_NAME=$((WIDTH - 10))   # max display name length
DASH_LINE=""               # precomputed separator line
for (( _i = 0; _i < WIDTH - 4; _i++ )); do
  DASH_LINE+="$DASH"
done

# ── State ───────────────────────────────────────────────────────
cursor=0
nav_count=0          # total navigable items (updated by collect_data)
needs_redraw=1
idle_ticks=0

item_types=()        # "header" | "window"
item_targets=()      # tmux target string (session:win_idx) for windows
item_displays=()     # formatted display string
item_statuses=()     # "working" | "idle" | "done" | "error" | ""

# ── Terminal Setup ──────────────────────────────────────────────
# Save terminal state, then disable echo and canonical mode.
# -echo:   prevents escape sequence bytes from leaking to display
# -icanon: character-at-a-time input (no line buffering)
# opost is kept enabled so \n translates to \r\n in output.
saved_stty="$(stty -g 2>/dev/null)"
stty -echo -icanon 2>/dev/null

printf "\033[?1049h"   # enter alternate screen buffer
printf "\033[?25l"     # hide cursor
printf "\033[?7l"      # disable line wrap

# ── Cleanup (runs on exit, interrupt, or term signal) ───────────
cleanup() {
  tmux set-option -gu @opencode-sidebar-pane 2>/dev/null || true
  printf "\033[?7h"        # re-enable line wrap
  printf "\033[?25h"       # show cursor
  printf "\033[?1049l"     # leave alternate screen buffer
  stty "$saved_stty" 2>/dev/null || stty sane 2>/dev/null
}
trap 'cleanup; exit 0' EXIT INT TERM

# ── Status Detection ────────────────────────────────────────────
# Determine the opencode status for a single pane.
#   - If opencode is the foreground command: check CPU to distinguish
#     "working" (agent active, CPU >= threshold) from "idle" (waiting).
#   - If opencode is NOT running: check /tmp exit code file left by
#     the optional `oc` wrapper to distinguish "done" from "error".
get_opencode_status() {
  local pane_pid="$1" pane_cmd="$2" pane_id="$3"

  if [ "$pane_cmd" = "opencode" ]; then
    # Find the actual opencode PID (child of the shell)
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

  # Opencode not running -- check exit code from `oc` wrapper
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

# ── Data Collection ─────────────────────────────────────────────
# Queries tmux for all sessions, windows, and panes in a single batch,
# then checks opencode status for each relevant pane.
# Sets needs_redraw=1 only if the data actually changed.
collect_data() {
  local old_snap=""
  local i
  for i in "${!item_displays[@]}"; do
    old_snap+="${item_displays[$i]}:${item_statuses[$i]}|"
  done

  item_types=()
  item_targets=()
  item_displays=()
  item_statuses=()
  nav_count=0

  # Fetch current session/window for the * marker
  local current_session current_window
  current_session="$(tmux display-message -p '#{session_name}' 2>/dev/null)" || current_session=""
  current_window="$(tmux display-message -p '#{window_index}' 2>/dev/null)" || current_window=""

  # Single batch call: all panes across all sessions
  local all_panes
  all_panes="$(tmux list-panes -a -F \
    '#{session_name}|#{window_index}|#{window_name}|#{pane_id}|#{pane_pid}|#{pane_current_command}' \
    2>/dev/null)" || return

  local prev_session="" prev_window=""

  while IFS='|' read -r sess win_idx win_name p_id p_pid p_cmd; do
    [ -z "$sess" ] && continue
    [ "$p_id" = "$SIDEBAR_PANE" ] && continue

    # New session header
    if [ "$sess" != "$prev_session" ]; then
      prev_session="$sess"
      prev_window=""
      item_types+=("header")
      item_targets+=("")
      item_displays+=("$sess")
      item_statuses+=("")
    fi

    # New window entry
    if [ "$sess:$win_idx" != "$prev_session:$prev_window" ]; then
      prev_window="$win_idx"

      local marker=""
      if [ "$sess" = "$current_session" ] && [ "$win_idx" = "$current_window" ]; then
        marker=" *"
      fi

      item_types+=("window")
      item_targets+=("${sess}:${win_idx}")
      item_displays+=("${win_idx}: ${win_name}${marker}")
      item_statuses+=("")
      nav_count=$((nav_count + 1))
    fi

    # Check opencode status and merge into the window's status
    local status
    status="$(get_opencode_status "$p_pid" "$p_cmd" "$p_id")"
    [ -z "$status" ] && continue

    # Find the last window entry index and update its status
    local last_idx=$(( ${#item_statuses[@]} - 1 ))
    local cur="${item_statuses[$last_idx]}"

    # Priority: working > error > idle > done
    case "$status" in
      working) item_statuses[$last_idx]="working" ;;
      error)   [ "$cur" != "working" ] && item_statuses[$last_idx]="error" ;;
      idle)    [ "$cur" != "working" ] && [ "$cur" != "error" ] && item_statuses[$last_idx]="idle" ;;
      done)    [ -z "$cur" ] && item_statuses[$last_idx]="done" ;;
    esac
  done <<< "$all_panes"

  # Only trigger redraw if data changed
  local new_snap=""
  for i in "${!item_displays[@]}"; do
    new_snap+="${item_displays[$i]}:${item_statuses[$i]}|"
  done
  [ "$old_snap" != "$new_snap" ] && needs_redraw=1
}

# ── Navigation Helpers ──────────────────────────────────────────

get_selected_target() {
  local nav=0 i
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

# ── Rendering ───────────────────────────────────────────────────
# Builds the entire frame into a string buffer, then flushes it inside
# a synchronized output block so the terminal renders it atomically.
render() {
  local buf=""

  buf+="${SYNC_START}"     # tell terminal: hold display
  buf+="\033[H"            # cursor home (overwrite in place)

  # Title
  buf+="\n"
  buf+="  ${BOLD}${CYAN}OPENCODE${RESET}${CLR}\n"
  buf+="  ${DIM}${DASH_LINE}${RESET}\n"

  local nav=0
  local prev_type=""
  local i

  for i in "${!item_types[@]}"; do
    local type="${item_types[$i]}"
    local display="${item_displays[$i]}"
    local status="${item_statuses[$i]}"

    if [ "$type" = "header" ]; then
      [ -n "$prev_type" ] && buf+="\n"
      buf+="  ${BOLD}${WHITE}${display}${RESET}${CLR}\n"

    elif [ "$type" = "window" ]; then
      # Indicator color and symbol (kept separate to avoid RESET inside BG_SELECT)
      local ind_color="" ind_char=" "
      case "$status" in
        working) ind_color="$YELLOW"; ind_char="$DOT" ;;
        idle)    ind_color="$GREEN";  ind_char="$DOT" ;;
        done)    ind_color="$GREEN";  ind_char="$DOT" ;;
        error)   ind_color="$RED";    ind_char="$DOT" ;;
      esac

      # Truncate long names
      if [ "${#display}" -gt "$MAX_NAME" ]; then
        display="${display:0:$((MAX_NAME - 2))}.."
      fi

      # Pad name to fixed width (no subshell fork)
      local padded=""
      printf -v padded "%-${MAX_NAME}s" "$display"

      if [ "$nav" -eq "$cursor" ]; then
        buf+="  ${BG_SELECT}${WHITE}${LINE_V} ${padded}  ${ind_color}${ind_char}${BG_SELECT}  ${RESET}${CLR}\n"
      else
        buf+="  ${DIM}${LINE_V}${RESET} ${padded}  ${ind_color}${ind_char}${RESET}${CLR}\n"
      fi

      nav=$((nav + 1))
    fi

    prev_type="$type"
  done

  # Footer
  buf+="\n"
  buf+="  ${DIM}↑↓ move  enter go  q close${RESET}${CLR}\n"
  buf+="\033[J"            # clear any leftover lines below

  buf+="${SYNC_END}"       # tell terminal: flush now
  printf "%b" "$buf"
}

# ── Main Loop ───────────────────────────────────────────────────

collect_data
needs_redraw=1

while true; do
  # Clamp cursor to valid range
  [ "$nav_count" -eq 0 ] && nav_count=1
  [ "$cursor" -ge "$nav_count" ] && cursor=$((nav_count - 1))
  [ "$cursor" -lt 0 ] && cursor=0

  # Redraw only when data or cursor changed
  if [ "$needs_redraw" -eq 1 ]; then
    render
    needs_redraw=0
  fi

  # Read one character with 1-second timeout.
  # Exit codes:  0 = got input | 1 = EOF (ignore) | >128 = timeout
  key=""
  rc=0
  IFS= read -rsn1 -t 1 key || rc=$?

  if [ "$rc" -gt 128 ]; then
    # Timeout (no keypress for 1s) -- refresh data periodically
    idle_ticks=$((idle_ticks + 1))
    if [ "$idle_ticks" -ge "$REFRESH_SECS" ]; then
      idle_ticks=0
      collect_data
    fi

  elif [ "$rc" -eq 1 ]; then
    # EOF from tmux resize / focus event -- safe to ignore
    :

  elif [ "$rc" -eq 0 ] && [ -z "$key" ]; then
    # Enter key (exit code 0 with empty string)
    switch_to_selected

  elif [ "$rc" -eq 0 ]; then
    # Regular keypress
    case "$key" in
      j) cursor=$((cursor + 1)); needs_redraw=1 ;;
      k) cursor=$((cursor - 1)); needs_redraw=1 ;;
      G) cursor=$((nav_count - 1)); needs_redraw=1 ;;
      g) cursor=0; needs_redraw=1 ;;
      q)
        tmux kill-pane -t "$SIDEBAR_PANE" 2>/dev/null || true
        exit 0
        ;;
      $'\x1b')
        # Arrow keys arrive as ESC [ A/B
        bracket=""
        IFS= read -rsn1 -t 1 bracket 2>/dev/null || true
        if [ "$bracket" = "[" ]; then
          arrow=""
          IFS= read -rsn1 -t 1 arrow 2>/dev/null || true
          case "$arrow" in
            A) cursor=$((cursor - 1)); needs_redraw=1 ;;
            B) cursor=$((cursor + 1)); needs_redraw=1 ;;
          esac
        fi
        ;;
    esac
    idle_ticks=0
  fi
done
