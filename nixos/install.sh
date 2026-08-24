#!/usr/bin/env bash
set -euo pipefail

DISK=/dev/nvme0n1
MAPPER=cryptroot
LUKS_PASSFILE=/tmp/dotfiles-luks
REPO_URL=https://github.com/gaavin/dotfiles.git
NIX_EXTRA=(--extra-experimental-features "nix-command flakes")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS=""
INSTALL_PASSWORDS_RUN=/run/nixos-install-passwords
INSTALLER_NIX_STORE=""
HOST=""
STEP_N=0
STEP_TOTAL=0
BUILD_PID=""
SLEEP_INHIBIT_PID=""
INSTALL_ABORTED=0
UI_SWAP_RENDERED=""
UI_CPU_RENDERED=""
UI_STACK_HEIGHT=0
UI_STACK_LAST=""
CPU_USAGE=0
CPU_PREV_TOTAL=""
CPU_PREV_IDLE=""
CPU_SAMPLES=()

die() {
  if command -v gum >/dev/null 2>&1; then
    gum log --level error "$1"
  else
    echo "$1" >&2
  fi
  exit 1
}

cleanup() {
  if [[ -n ${BUILD_PID:-} ]] && kill -0 "$BUILD_PID" 2>/dev/null; then
    kill "$BUILD_PID" 2>/dev/null || true
    wait "$BUILD_PID" 2>/dev/null || true
  fi
  BUILD_PID=""
  if [[ ${INSTALL_ABORTED:-0} -eq 1 ]]; then
    abort_cleanup
    ui_abort
  else
    reset_zram_swap
  fi
  if [[ -n ${SECRETS:-} && -d $SECRETS ]]; then
    rm -rf "$SECRETS"
  fi
  if [[ -d ${INSTALL_PASSWORDS_RUN:-/run/nixos-install-passwords} ]]; then
    rm -rf "$INSTALL_PASSWORDS_RUN"
  fi
  if [[ -d /mnt/run/nixos-install-passwords ]]; then
    rm -rf /mnt/run/nixos-install-passwords
  fi
  rm -f "$LUKS_PASSFILE" /mnt/root/chpasswd
  stop_sleep_inhibit
}

# Like macOS caffeinate: block sleep/suspend/idle while installing.
# Do not inhibit shutdown — reboot after install must still work.
start_sleep_inhibit() {
  [[ -n ${SLEEP_INHIBIT_PID:-} ]] && return 0
  command -v systemd-inhibit >/dev/null 2>&1 || return 0
  systemd-inhibit \
    --what=idle:sleep:handle-lid-switch:handle-suspend-key:handle-hibernate-key \
    --who="nixos-install.sh" \
    --why="NixOS installation in progress" \
    --mode=block \
    sleep infinity &
  SLEEP_INHIBIT_PID=$!
}

stop_sleep_inhibit() {
  if [[ -n ${SLEEP_INHIBIT_PID:-} ]] && kill -0 "$SLEEP_INHIBIT_PID" 2>/dev/null; then
    kill "$SLEEP_INHIBIT_PID" 2>/dev/null || true
    wait "$SLEEP_INHIBIT_PID" 2>/dev/null || true
  fi
  SLEEP_INHIBIT_PID=""
}

on_interrupt() {
  INSTALL_ABORTED=1
  exit 130
}

nix_flake() {
  local -a args=("${NIX_EXTRA[@]}")
  [[ -n ${INSTALLER_NIX_STORE:-} ]] && args+=(--store "$INSTALLER_NIX_STORE")
  command nix "${args[@]}" "$@"
}

UI_WIDTH=64
UI_PAD_H=2
UI_MARGIN_SECTION="1 0 0 0"
UI_MARGIN_TIGHT="0 0 0 0"
UI_MARGIN_BOX="1 0 1 0"
UI_MARGIN_BEFORE="1 0 0 0"
UI_MARGIN_AFTER="0 0 1 0"
UI_MARGIN_STACK_GAP="0 0 0 0"
UI_MARGIN_LIVE_TOP="1 0 0 0"
UI_CPU_GRAPH_SAMPLES=36
UI_BUILD_LINES=6
NIXOS_VERSION="26.11 unstable"
ZRAM_ALGORITHM=lz4
ZRAM_MEMORY_PERCENT=100
ZRAM_SWAP_PRIORITY=100
SWAP_ZRAM_KIND=zram
SWAP_DISK_KIND=swap
SWAP_DISK_DETAIL=partition
PLANNED_ESP_BYTES=$((2 * 1024 * 1024 * 1024))
PLANNED_SWAP_BYTES=$((8 * 1024 * 1024 * 1024))
# Asahi leaves alignment gaps; only the largest free region is used for NixOS.
AIR_MIN_FREE_BYTES=$((20 * 1024 * 1024 * 1024))
C_ACCENT=39
C_SUCCESS=42
C_WARN=214
C_DANGER=196
C_MUTED=245
C_TEXT=252
C_VIOLET=141

# ASCII-only UI glyphs. Linux VT has no emoji font; many Unicode symbols are
# missing or double-width. Keep every marker one column for alignment.
UI_OK='+'
UI_WARN='!'
UI_FAIL='x'
UI_MARK='>'
UI_BULLET='*'
UI_PART='o'
UI_LUKS='#'
UI_VOL='v'
UI_ZRAM='z'
UI_SWAP='s'
UI_PROMPT='> '

theme() {
  export GUM_INPUT_CURSOR_FOREGROUND="$C_ACCENT"
  export GUM_INPUT_PROMPT_FOREGROUND="$C_ACCENT"
  export GUM_INPUT_HEADER_FOREGROUND="$C_VIOLET"
  export GUM_INPUT_WIDTH="$UI_WIDTH"
  export GUM_INPUT_CHAR_LIMIT="512"
  export GUM_INPUT_PROMPT="$UI_PROMPT"
  export GUM_INPUT_PLACEHOLDER_FOREGROUND="$C_MUTED"
  export GUM_CONFIRM_PROMPT_FOREGROUND="$C_WARN"
  export GUM_CONFIRM_SELECTED_FOREGROUND="15"
  export GUM_CONFIRM_SELECTED_BACKGROUND="$C_ACCENT"
  export GUM_CONFIRM_UNSELECTED_FOREGROUND="$C_MUTED"
  export GUM_SPIN_SPINNER="dot"
  export GUM_SPIN_TITLE_FOREGROUND="$C_ACCENT"
  export GUM_LOG_LEVEL="info"
}

host_arch() {
  case $(uname -m) in
    x86_64) echo "x86_64-linux" ;;
    aarch64) echo "aarch64-linux" ;;
    *) echo "$(uname -m)-linux" ;;
  esac
}

host_icon() {
  case $1 in
    mina) echo "M" ;;
    air) echo "A" ;;
    *) echo "$UI_BULLET" ;;
  esac
}

ui_ansi() {
  printf '\033[%sm%s\033[0m' "$1" "$2"
}

ui_faint() {
  ui_ansi "2" "$1"
}

# Single-column ASCII markers only.
ui_installer_icon() {
  case $1 in
    *Password*) printf '%s' "$UI_BULLET" ;;
    *destructive*) printf '%s' "$UI_WARN" ;;
    *LUKS*) printf '%s' "$UI_LUKS" ;;
    *Encrypt*) printf '%s' "$UI_BULLET" ;;
    *Format*) printf '=' ;;
    *firmware*) printf '-' ;;
    *Install*) printf '%s' "$UI_OK" ;;
    *) printf '%s' "$UI_MARK" ;;
  esac
}

ui_installer_color() {
  case $1 in
    *destructive*) echo "$C_DANGER" ;;
    *Encrypt*|*LUKS*) echo "$C_VIOLET" ;;
    *Install*) echo "$C_SUCCESS" ;;
    *Password*) echo "$C_ACCENT" ;;
    *) echo "$C_TEXT" ;;
  esac
}

ui_banner() {
  local host=$1 installer=$2
  local line icon color
  local -a body=(
    "$(ui_ansi "1;38;5;${C_ACCENT}" "NixOS")"
    "$(ui_ansi "2;38;5;${C_VIOLET}" "${UI_BULLET} Version $NIXOS_VERSION")"
    "$(ui_faint "$(host_icon "$host") $host / $(host_arch)")"
  )

  if [[ -n $installer ]]; then
    body+=("" "$(ui_ansi "1;38;5;${C_ACCENT}" "${UI_BULLET} Installer")")
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      line="${line#- }"
      icon="$(ui_installer_icon "$line")"
      color="$(ui_installer_color "$line")"
      body+=("$(ui_ansi "38;5;${color}" "  ${icon} ${line}")")
    done <<< "$installer"
  fi

  gum style \
    --border rounded \
    --border-foreground "$C_ACCENT" \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --margin "$UI_MARGIN_SECTION" \
    "${body[@]}"
}

ui_section_line() {
  local marker=$1
  shift
  gum style \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --margin "$UI_MARGIN_SECTION" \
    "$(ui_ansi "1;38;5;${C_ACCENT}" "$marker") $*"
}

ui_ok() {
  ui_line "$(ui_ansi "38;5;${C_SUCCESS}" "${UI_OK} $1")"
}

ui_warn() {
  ui_line "$(ui_ansi "38;5;${C_WARN}" "${UI_WARN} $1")"
}

ui_abort() {
  local msg
  msg="$(gum style \
    --border rounded \
    --border-foreground "$C_WARN" \
    --foreground "$C_WARN" \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --margin "$UI_MARGIN_SECTION" \
    "${UI_FAIL} Installation aborted." \
    "$(ui_faint "Re-run ./nixos/install.sh to resume.")")"
  ui_tty_write "${msg}"$'\n'
}

ui_line() {
  gum style \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --margin "$UI_MARGIN_TIGHT" \
    "$@"
}

ui_step() {
  STEP_N=$((STEP_N + 1))
  ui_section_line "$UI_MARK" \
    "$(ui_ansi "1;38;5;${C_ACCENT}" "$STEP_N/$STEP_TOTAL") $(ui_ansi "1;38;5;${C_TEXT}" "$1")"
}

ui_spin() {
  local title=$1
  shift
  local log status=0 pid i=0 pad line
  local -a frames=('|' '/' '-' '\')
  log="$(mktemp)"
  pad="$(printf '%*s' "$UI_PAD_H" '')"

  "$@" >"$log" 2>&1 &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    line="${pad}$(ui_ansi "38;5;${C_VIOLET}" "${frames[i]}") $(ui_ansi "38;5;${C_ACCENT}" "$title")"
    if [[ -e /dev/tty ]]; then
      printf '\r\033[K%s' "$line" >/dev/tty 2>/dev/null || printf '\r\033[K%s' "$line" >&2
    else
      printf '\r\033[K%s' "$line" >&2
    fi
    i=$(((i + 1) % ${#frames[@]}))
    sleep 0.1
  done

  wait "$pid" || status=$?

  if [[ -e /dev/tty ]]; then
    printf '\r\033[K' >/dev/tty 2>/dev/null || printf '\r\033[K' >&2
  else
    printf '\r\033[K' >&2
  fi

  if ((status == 0)); then
    ui_line "$(ui_ansi "38;5;${C_SUCCESS}" "${UI_OK}") $(ui_ansi "38;5;${C_TEXT}" "$title")"
  else
    ui_line "$(ui_ansi "38;5;${C_DANGER}" "${UI_FAIL}") $(ui_ansi "38;5;${C_TEXT}" "$title")"
    cat "$log" >&2
  fi
  rm -f "$log"
  return "$status"
}

ui_tty() {
  if [[ -e /dev/tty ]]; then
    printf '%s\n' "$@" >/dev/tty
  else
    printf '%s\n' "$@" >&2
  fi
}

ui_tty_write() {
  if [[ -e /dev/tty ]]; then
    printf '%b' "$1" >/dev/tty 2>/dev/null || printf '%b' "$1" >&2
  else
    printf '%b' "$1" >&2
  fi
}

ui_box_line_count() {
  local text=$1
  while [[ $text == *$'\n' ]]; do
    text="${text%$'\n'}"
  done
  if [[ -z $text ]]; then
    echo 0
    return
  fi
  awk 'END {print NR}' <<< "$text"
}

# Redraw swap/build on /dev/tty in one write. Never clear line-by-line with
# separate tput calls — that leaves blank intermediate frames that screencasts
# and the eye read as flicker. Skip paint when content is unchanged.
ui_live_stack_paint() {
  local rendered=$1
  local new_lines clear_lines
  local seq=""

  [[ $rendered == "${UI_STACK_LAST}" ]] && return 0

  new_lines="$(ui_box_line_count "$rendered")"
  clear_lines=$UI_STACK_HEIGHT

  # Hide cursor for the paint, move to stack top, erase downward, write body.
  seq=$'\033[?25l'
  if ((clear_lines > 0)); then
    seq+=$'\033['"${clear_lines}"$'A\033[0J'
  fi
  seq+="${rendered}"$'\n'
  seq+=$'\033[?25h'

  if [[ -e /dev/tty ]]; then
    # %s only: do not reinterpret escapes inside gum output.
    printf '%s' "$seq" >/dev/tty 2>/dev/null || printf '%s' "$seq" >&2
  else
    printf '%s' "$seq" >&2
  fi

  UI_STACK_HEIGHT=$new_lines
  UI_STACK_LAST=$rendered
}

ui_live_stack_combine() {
  local build_rendered=${1:-}
  local -a parts=()

  [[ -n ${UI_SWAP_RENDERED:-} ]] && parts+=("$UI_SWAP_RENDERED")
  [[ -n ${UI_CPU_RENDERED:-} ]] && parts+=("$UI_CPU_RENDERED")
  [[ -n $build_rendered ]] && parts+=("$build_rendered")

  if ((${#parts[@]} == 0)); then
    printf ''
  elif ((${#parts[@]} == 1)); then
    printf '%s' "${parts[0]}"
  else
    local IFS=$'\n'
    printf '%s' "${parts[*]}"
  fi
}

ui_cpu_tick() {
  local _ user nice system idle iowait total idle_sum delta_total delta_idle usage

  read -r _ user nice system idle iowait _ _ _ _ _ < <(grep '^cpu ' /proc/stat)
  total=$((user + nice + system + idle + iowait))
  idle_sum=$((idle + iowait))

  if [[ -n ${CPU_PREV_TOTAL:-} ]]; then
    delta_total=$((total - CPU_PREV_TOTAL))
    delta_idle=$((idle_sum - CPU_PREV_IDLE))
    if ((delta_total > 0)); then
      usage=$((100 - (delta_idle * 100 / delta_total)))
      ((usage < 0)) && usage=0
      ((usage > 100)) && usage=100
      CPU_USAGE=$usage
      CPU_SAMPLES+=("$usage")
      if ((${#CPU_SAMPLES[@]} > UI_CPU_GRAPH_SAMPLES)); then
        CPU_SAMPLES=("${CPU_SAMPLES[@]:1}")
      fi
    fi
  fi

  CPU_PREV_TOTAL=$total
  CPU_PREV_IDLE=$idle_sum
}

ui_box_label() {
  ui_ansi "38;5;${C_MUTED}" "${UI_MARK} $1"
}

ui_cpu_sparkline() {
  local usage chars='_.:-=+*#' spark='' idx

  for usage in "${CPU_SAMPLES[@]}"; do
    idx=$((usage * 7 / 100))
    ((idx > 7)) && idx=7
    spark+="${chars:idx:1}"
  done
  printf '%s' "$spark"
}

ui_cpu_box_render() {
  local spark pct margin body width

  spark="$(ui_cpu_sparkline)"
  pct=${CPU_USAGE:-0}
  width=$((UI_WIDTH - UI_PAD_H * 2 - 10))
  if ((${#spark} < width)); then
    spark+="$(printf '%*s' "$((width - ${#spark}))" '' | tr ' ' '_')"
  elif ((${#spark} > width)); then
    spark="${spark: -width}"
  fi

  if ((${#CPU_SAMPLES[@]} == 0)); then
    body="$(ui_faint "  $spark")"
  else
    body="$(ui_ansi "38;5;${C_VIOLET}" "$(printf '  %2s%%' "$pct")") $(ui_faint "$spark")"
  fi

  if [[ -z ${UI_SWAP_RENDERED:-} ]]; then
    margin=$UI_MARGIN_LIVE_TOP
  else
    margin=$UI_MARGIN_STACK_GAP
  fi

  UI_CPU_RENDERED="$(gum style \
    --border rounded \
    --border-foreground "$C_MUTED" \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --margin "$margin" \
    --foreground "$C_TEXT" \
    "$(ui_box_label cpu)" \
    "$body")"
}

ui_live_stack_refresh() {
  local build_rendered=${1:-}

  if [[ $(swap_active_bytes) -gt 0 ]]; then
    ui_swap_box_render || true
  fi
  ui_cpu_tick
  ui_cpu_box_render
  ui_live_stack_paint "$(ui_live_stack_combine "$build_rendered")"
}

ui_build_read_lines() {
  local log=$1
  local -n _lines=$2
  local -a raw=()

  _lines=()
  [[ -f $log ]] || return 0

  mapfile -t raw < <(
    tr '\r' '\n' <"$log" |
      sed -e 's/[[:space:]]*$//' |
      awk 'NF' |
      tail -n "$UI_BUILD_LINES"
  )

  _lines=( "${raw[@]}" )
}

ui_build_box_render() {
  local -n _lines=$1
  local body rendered margin

  if ((${#_lines[@]} > 0)); then
    body="$(printf '%s\n' "${_lines[@]}")"
    body="${body%$'\n'}"
  else
    body="$(ui_faint 'starting…')"
  fi

  margin=$UI_MARGIN_STACK_GAP
  [[ -z ${UI_SWAP_RENDERED:-} ]] && margin=$UI_MARGIN_LIVE_TOP

  rendered="$(gum style \
    --border rounded \
    --border-foreground "$C_MUTED" \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --margin "$margin" \
    --foreground "$C_TEXT" \
    "$(ui_box_label build)" \
    "$body")"

  ui_live_stack_refresh "$rendered"
}

ui_build_show_errors() {
  local log=$1
  [[ -f $log ]] || return 0
  tail -20 "$log" >&2 || true
}

ui_build_box() {
  local log status=0 pid
  local -a lines=()
  log="$(mktemp)"

  CPU_SAMPLES=()
  CPU_PREV_TOTAL=""
  CPU_PREV_IDLE=""
  CPU_USAGE=0

  ui_build_box_render lines

  # Do not wrap with stdbuf: it sets LD_PRELOAD=libstdbuf.so, which nixos-install
  # children inherit and cannot load against the target /nix/store (harmless ERROR spam).
  "$@" >"$log" 2>&1 &
  pid=$!
  BUILD_PID=$pid

  while kill -0 "$pid" 2>/dev/null; do
    ui_build_read_lines "$log" lines
    ui_build_box_render lines
    sleep 0.2
  done

  wait "$pid" || status=$?
  BUILD_PID=""

  ui_build_read_lines "$log" lines
  ui_build_box_render lines

  if ((status != 0)); then
    ui_build_show_errors "$log"
    rm -f "$log"
    return "$status"
  fi

  rm -f "$log"
  return 0
}

disk_short() {
  basename "$DISK"
}

fmt_size() {
  local bytes=$1
  if [[ ! $bytes =~ ^[0-9]+$ ]]; then
    echo "$bytes"
    return
  fi
  awk -v b="$bytes" 'BEGIN {
    split("B KiB MiB GiB TiB", u, " ")
    i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    if (i == 1) printf "%.0f%s", b, u[i]
    else printf "%.1f%s", b, u[i]
  }'
}

swapon_table() {
  swapon --noheadings --raw --bytes --show=NAME,TYPE,SIZE,USED,PRIO 2>/dev/null ||
    swapon --noheadings --raw --show=NAME,TYPE,SIZE,USED,PRIO 2>/dev/null
}

parse_size_to_bytes() {
  local raw=$1
  if [[ $raw =~ ^[0-9]+$ ]]; then
    echo "$raw"
    return
  fi
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --from=iec-i "$raw" 2>/dev/null && return
  fi
  awk -v s="$raw" 'BEGIN {
    if (match(s, /^([0-9]+(\.[0-9]+)?)([KMGTP]?i?B?)$/, m)) {
      v = m[1] + 0
      u = m[3]
      if (u ~ /^K/) v *= 1024
      else if (u ~ /^M/) v *= 1024^2
      else if (u ~ /^G/) v *= 1024^3
      else if (u ~ /^T/) v *= 1024^4
      else if (u ~ /^P/) v *= 1024^5
      printf "%.0f", v
    }
  }'
}

swap_used_bytes() {
  local name=$1 from_swapon=$2
  local base="${name##*/}" dev used_kb parsed orig

  if [[ $from_swapon =~ ^[0-9]+$ && $from_swapon -gt 0 ]]; then
    echo "$from_swapon"
    return
  fi

  if [[ -n $from_swapon && $from_swapon != "-" ]]; then
    parsed="$(parse_size_to_bytes "$from_swapon" 2>/dev/null || true)"
    if [[ $parsed =~ ^[0-9]+$ && $parsed -gt 0 ]]; then
      echo "$parsed"
      return
    fi
  fi

  for dev in "$name" "/dev/$base"; do
    while read -r fname _ _ used_kb _; do
      [[ $fname == "$dev" ]] || continue
      [[ $used_kb =~ ^[0-9]+$ && $used_kb -gt 0 ]] || continue
      echo $((used_kb * 1024))
      return
    done < /proc/swaps
  done

  if [[ $base == zram* && -r /sys/block/$base/mm_stat ]]; then
    read -r orig _ <<<"$(< /sys/block/$base/mm_stat)"
    if [[ $orig =~ ^[0-9]+$ && $orig -gt 0 ]]; then
      echo "$orig"
      return
    fi
  fi

  echo 0
}

disk_size_human() {
  fmt_size "$(disk_size_bytes)"
}

disk_size_bytes() {
  local size
  size="$(lsblk -n -b -d -o SIZE "$DISK" 2>/dev/null || echo 0)"
  [[ $size =~ ^[0-9]+$ ]] || size=0
  echo "$size"
}

# parted -m prints sizes with a unit suffix (34s, 17408B). Strip it.
air_parted_int() {
  local v=${1%%[A-Za-z]*}
  [[ $v =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$v"
}

air_sector_bytes() {
  local short sys
  short="$(disk_short)"
  sys="/sys/block/${short}/queue/logical_block_size"
  if [[ -r $sys ]]; then
    cat "$sys"
  else
    echo 512
  fi
}

# Each line: start_sector end_sector size_sectors (inclusive end, from parted).
air_free_regions_sectors() {
  local line start end size start_s end_s size_s
  command -v parted >/dev/null 2>&1 || return 0
  while IFS= read -r line; do
    [[ $line == *:free\; ]] || continue
    IFS=: read -r _ start end size _ <<<"$line"
    start_s="$(air_parted_int "$start")" || continue
    end_s="$(air_parted_int "$end")" || continue
    size_s="$(air_parted_int "$size")" || continue
    printf '%s %s %s\n' "$start_s" "$end_s" "$size_s"
  done < <(parted -ms "$DISK" unit s print free 2>/dev/null || true)
}

# Largest free GPT gap: "start_sector end_sector size_bytes"
air_largest_free_region() {
  local start_s end_s size_s sector_b size_b
  local best_start="" best_end="" best_bytes=0

  sector_b="$(air_sector_bytes)"
  [[ $sector_b =~ ^[0-9]+$ && $sector_b -gt 0 ]] || sector_b=512

  while read -r start_s end_s size_s; do
    [[ $start_s =~ ^[0-9]+$ && $end_s =~ ^[0-9]+$ && $size_s =~ ^[0-9]+$ ]] || continue
    size_b=$((size_s * sector_b))
    if ((size_b > best_bytes)); then
      best_bytes=$size_b
      best_start=$start_s
      best_end=$end_s
    fi
  done < <(air_free_regions_sectors)

  ((best_bytes > 0)) || return 1
  printf '%s %s %s\n' "$best_start" "$best_end" "$best_bytes"
}

disk_air_free_bytes() {
  local installable
  installable="$(air_installable_bytes)"
  if ((installable > 0)); then
    echo "$installable"
    return
  fi

  local disk_bytes used_bytes=0
  disk_bytes="$(disk_size_bytes)"
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    NAME= SIZE= TYPE=
    eval "$line"
    [[ ${TYPE:-} == part ]] || continue
    [[ $SIZE =~ ^[0-9]+$ ]] || continue
    used_bytes=$((used_bytes + SIZE))
  done < <(disk_lsblk)
  echo $((disk_bytes - used_bytes))
}

disk_planned_luks_bytes() {
  local host=$1
  if [[ $host == mina ]]; then
    echo $(( $(disk_size_bytes) - PLANNED_ESP_BYTES ))
  else
    disk_air_free_bytes
  fi
}

disk_planned_root_bytes() {
  local luks_bytes=$1
  echo $((luks_bytes - PLANNED_SWAP_BYTES))
}

disk_planned_total_bytes() {
  local host=$1
  if [[ $host == mina ]]; then
    disk_size_bytes
  else
    disk_planned_luks_bytes air
  fi
}

disk_planned_layout() {
  local host=$1 luks_bytes root_bytes luks_h root_h swap_h

  luks_bytes="$(disk_planned_luks_bytes "$host")"
  root_bytes="$(disk_planned_root_bytes "$luks_bytes")"
  luks_h="$(fmt_size "$luks_bytes")"
  root_h="$(fmt_size "$root_bytes")"
  swap_h="$(fmt_size "$PLANNED_SWAP_BYTES")"

  if [[ $host == mina ]]; then
    ui_diff_add "${UI_PART} ESP     $(fmt_size "$PLANNED_ESP_BYTES")  vfat  /efi$(disk_mount_opts_suffix /efi)"
    ui_diff_add "${UI_LUKS} nixos   ${luks_h}  LUKS  cryptroot"
  else
    ui_diff_add "${UI_LUKS} nixos   ${luks_h}  LUKS  cryptroot  (free space)"
  fi
  ui_diff_add "  ${UI_VOL} swap  ${swap_h}"
  ui_diff_add "  ${UI_VOL} root  ${root_h}  xfs  /$(disk_mount_opts_suffix /)"
}

ui_diff_ctx() {
  printf '%s\n' "$(ui_ansi "38;5;${C_MUTED}" "  $1")"
}

ui_diff_del() {
  printf '%s\n' "$(ui_ansi "38;5;${C_DANGER}" "- $1")"
}

ui_diff_add() {
  printf '%s\n' "$(ui_ansi "38;5;${C_SUCCESS}" "+ $1")"
}

ui_diff_mod() {
  printf '%s\n' "$(ui_ansi "38;5;${C_WARN}" "~ $1")"
}

part_label_display() {
  local label=$1 parttypename=$2 name=$3
  if [[ -n $label && $label != "-" ]]; then
    echo "$label"
  elif [[ -n $parttypename && $parttypename != "-" ]]; then
    echo "$parttypename"
  else
    echo "$name"
  fi
}

# Only the Asahi-chosen ESP is mounted at /efi. nixos-labelled slices are
# previous Linux installs and will be removed. Everything else stays put.
part_role_air() {
  local partuuid=$1 esp_uuid=$2 partlabel=$3
  if [[ -n $esp_uuid && -n $partuuid && $partuuid == "$esp_uuid" ]]; then
    echo esp
  elif [[ ${partlabel:-} == nixos ]]; then
    echo linux
  else
    echo preserved
  fi
}

disk_lsblk() {
  lsblk -P -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINT,TYPE,PARTTYPENAME,PKNAME,PARTUUID "$DISK" 2>/dev/null || true
}

disk_entry_desc() {
  local name=$1 size=$2 fstype=$3 label=$4 partlabel=$5 mount=$6 type=$7
  local title size_h spec icon

  title="$(part_label_display "$partlabel" "" "$name")"
  if [[ $title == "$name" && -n $label && $label != "-" ]]; then
    title="$label"
  fi
  if [[ $type == part && $fstype == crypto_LUKS && ( -z $partlabel || $partlabel == "-" ) && $title == "$name" ]]; then
    title="nixos"
  fi

  size_h="$(fmt_size "$size")"
  spec="${title}  ${size_h}"
  [[ -n $fstype && $fstype != "-" ]] && spec="$spec  ${fstype}"
  [[ -n $mount && $mount != "-" ]] && spec="$spec  ${mount}"

  case $type in
    crypt) icon="$UI_LUKS" ;;
    lvm) icon="$UI_VOL" ;;
    part) icon="$UI_PART" ;;
    *) icon="$UI_MARK" ;;
  esac

  printf '%s %s' "$icon" "$spec"
}

# Keep in sync with hosts/mina/default.nix (ESP) and configuration.nix (root).
disk_planned_mount_opts() {
  case $1 in
    /efi) echo "umask=0077" ;;
    /) echo "relatime,lazytime" ;;
  esac
}

disk_mount_opts_suffix() {
  local mount=$1 opts
  opts="$(disk_planned_mount_opts "$mount")"
  [[ -n $opts ]] && printf '  (%s)' "$opts"
}

disk_build_parent_map() {
  local -n out=$1
  local -n typemap=$2
  local line crypt_name= luks_part= name pk

  while IFS= read -r line; do
    [[ -z $line ]] && continue
    NAME= SIZE= FSTYPE= LABEL= PARTLABEL= MOUNTPOINT= TYPE= PARTTYPENAME= PKNAME= PARTUUID=
    eval "$line"
    [[ -n ${NAME:-} ]] || continue
    out[$NAME]=${PKNAME:-}
    typemap[$NAME]=${TYPE:-}
    [[ ${TYPE:-} == crypt ]] && crypt_name=$NAME
    [[ ${TYPE:-} == part && ${FSTYPE:-} == crypto_LUKS ]] && luks_part=$NAME
  done < <(disk_lsblk)

  for name in "${!out[@]}"; do
    [[ ${typemap[$name]} == crypt && -z ${out[$name]} && -n $luks_part ]] &&
      out[$name]=$luks_part
  done

  for name in "${!out[@]}"; do
    [[ ${typemap[$name]} == lvm && $name == *-* && -z ${out[$name]} ]] &&
      out[$name]="${name%-*}"
  done

  for name in "${!out[@]}"; do
    [[ ${typemap[$name]} != lvm || $name != *-* ]] && continue
    pk=${out[$name]}
    [[ -n $pk && -z ${out[$pk]:-} && -n $crypt_name ]] && out[$name]=$crypt_name
  done

  for name in "${!out[@]}"; do
    [[ ${typemap[$name]} == lvm && $name != *-* && -z ${out[$name]} && -n $crypt_name ]] &&
      out[$name]=$crypt_name
  done
}

disk_tree_depth() {
  local name=$1
  local -n parents=$2
  local depth=0 pk="${parents[$name]:-}"

  while [[ -n $pk ]]; do
    depth=$((depth + 1))
    [[ $pk == "$(disk_short)" ]] && break
    pk="${parents[$pk]:-}"
  done

  echo "$depth"
}

disk_display_indent() {
  local depth=$1
  if (( depth > 0 )); then
    disk_diff_indent $((depth - 1))
  else
    disk_diff_indent 0
  fi
}

disk_diff_indent() {
  printf '%*s' "$(( ${1:-0} * 2 ))" ''
}

disk_diff_header() {
  local host=$1 disk_name now_h planned_h
  disk_name="$(disk_short)"
  now_h="$(disk_size_human)"
  planned_h="$(fmt_size "$(disk_planned_total_bytes "$host")")"
  ui_diff_ctx "${disk_name} / ${now_h}"
  ui_diff_ctx "planned / ${planned_h}"
  ui_diff_ctx ""
}

mina_disk_diff() {
  local line removed=0 depth indent spec
  local -A pkmap=()
  local -A devtypes=()

  disk_build_parent_map pkmap devtypes

  {
    disk_diff_header mina

    while IFS= read -r line; do
      [[ -z $line ]] && continue
      NAME= SIZE= FSTYPE= LABEL= PARTLABEL= MOUNTPOINT= TYPE= PARTTYPENAME= PKNAME= PARTUUID=
      eval "$line"
      [[ ${TYPE:-} == disk ]] && continue
      case ${TYPE:-} in
        part | crypt | lvm) ;;
        *) continue ;;
      esac
      [[ ${TYPE:-} == lvm && $NAME != *-* ]] && continue
      removed=1
      depth="$(disk_tree_depth "$NAME" pkmap)"
      indent="$(disk_display_indent "$depth")"
      spec="$(disk_entry_desc "$NAME" "$SIZE" "$FSTYPE" "$LABEL" "$PARTLABEL" "$MOUNTPOINT" "$TYPE")"
      ui_diff_del "${indent}${spec}"
    done < <(disk_lsblk)

    if [[ $removed -eq 0 ]]; then
      ui_diff_ctx "(empty disk)"
    fi

    ui_diff_ctx ""
    disk_planned_layout mina
  }
}

ui_disk_diff_box() {
  local rendered
  rendered="$(gum style \
    --border rounded \
    --border-foreground "$C_MUTED" \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --margin "$UI_MARGIN_TIGHT" \
    --foreground "$C_TEXT" \
    "$(ui_box_label storage)" \
    "$1")"
  ui_tty_write "${rendered}"$'\n'
}

air_disk_diff() {
  local esp_uuid=${1:-}
  local line indent spec role
  local -A pkmap=()
  local -A devtypes=()

  disk_build_parent_map pkmap devtypes

  {
    disk_diff_header air

    while IFS= read -r line; do
      [[ -z $line ]] && continue
      NAME= SIZE= FSTYPE= LABEL= PARTLABEL= MOUNTPOINT= TYPE= PARTTYPENAME= PKNAME= PARTUUID=
      eval "$line"
      [[ ${TYPE:-} == disk ]] && continue
      [[ ${TYPE:-} == part ]] || continue
      indent="$(disk_display_indent "$(disk_tree_depth "$NAME" pkmap)")"
      spec="$(disk_entry_desc "$NAME" "$SIZE" "$FSTYPE" "$LABEL" "$PARTLABEL" "$MOUNTPOINT" "$TYPE")"
      role="$(part_role_air "${PARTUUID:-}" "$esp_uuid" "${PARTLABEL:-}")"
      case $role in
        esp) ui_diff_mod "${indent}${spec}  -> /efi (mount only, never format)" ;;
        linux) ui_diff_del "${indent}${spec}  (remove previous install)" ;;
        preserved) ui_diff_ctx "${indent}${spec}" ;;
      esac
    done < <(disk_lsblk)

    ui_diff_ctx ""
    disk_planned_layout air
  }
}

ask_password() {
  local dest=$1 header=$2 pass pass2
  while true; do
    pass="$(gum input --password --header "$header" --placeholder "password" --char-limit 0)" || exit 1
    if [[ -z $pass ]]; then
      ui_warn "Password cannot be empty"
      continue
    fi
    pass2="$(gum input --password --header "Confirm $header" --placeholder "confirm" --char-limit 0)" || exit 1
    if [[ $pass != "$pass2" ]]; then
      ui_warn "Passwords do not match"
      continue
    fi
    printf '%s' "$pass" >"$dest"
    chmod 600 "$dest"
    unset pass pass2
    return
  done
}

confirm() {
  if [[ ${INSTALL_YES:-} == 1 ]]; then
    return
  fi
  gum confirm --default=false --affirmative "Continue ->" --negative "${UI_FAIL} Cancel" "$1" || {
    ui_ok "Cancelled"
    exit 1
  }
}

detect_host() {
  if [[ -f /proc/device-tree/chosen/asahi,efi-system-partition ]]; then
    echo air
  elif [[ $(uname -m) == x86_64 ]]; then
    echo mina
  else
    die "unknown machine"
  fi
}

copy_repo() {
  mkdir -p /mnt/home/max
  rm -rf /mnt/home/max/dotfiles
  if [[ -f $REPO_ROOT/nixos/flake.nix ]]; then
    ui_spin "Copying configuration..." cp -a "$REPO_ROOT" /mnt/home/max/dotfiles
  elif command -v git >/dev/null 2>&1; then
    ui_spin "Cloning configuration..." git clone "$REPO_URL" /mnt/home/max/dotfiles
  else
    ui_spin "Cloning configuration..." \
      nix_flake shell nixpkgs#git --command git clone "$REPO_URL" /mnt/home/max/dotfiles
  fi
}

# Match hosts/air/default.nix LVM layout without fetching Disko (live tmpfs is tiny).
air_lvm_format_mount() {
  local mapper=/dev/mapper/$MAPPER

  [[ -b $mapper ]] || die "LUKS mapper missing: $mapper"
  command -v pvcreate >/dev/null && command -v vgcreate >/dev/null &&
    command -v lvcreate >/dev/null && command -v mkfs.xfs >/dev/null ||
    die "missing lvm/xfs tools"

  wipefs -a "$mapper" >/dev/null 2>&1 || true
  pvcreate -ff -y "$mapper" >/dev/null
  vgcreate -y air "$mapper" >/dev/null
  lvcreate -y -L 8G -n swap air >/dev/null
  lvcreate -y -l 100%FREE -n root air >/dev/null
  udevadm settle 2>/dev/null || true

  [[ -b /dev/mapper/air-swap && -b /dev/mapper/air-root ]] ||
    die "air LVs not found after lvcreate"

  mkswap /dev/mapper/air-swap >/dev/null
  mkfs.xfs -f /dev/mapper/air-root >/dev/null
  mkdir -p /mnt
  mount /dev/mapper/air-root /mnt
  swapon /dev/mapper/air-swap
}

# Live ISO /nix/store is a busy overlay (this script + gum run from it). Never
# umount it. Mount a second disk-backed overlay and point nix-daemon at it.
installer_stop_nix_daemon() {
  systemctl stop nix-daemon.service nix-daemon.socket 2>/dev/null || true
  pkill -TERM nix-daemon 2>/dev/null || true
  sleep 1
}

installer_start_nix_daemon() {
  local conf_dir=$1 state_dir=$2
  export NIX_CONF_DIR=$conf_dir
  export NIX_STATE_DIR=$state_dir
  NIX_CONF_DIR=$conf_dir NIX_STATE_DIR=$state_dir nix-daemon &
}

installer_wait_nix_daemon_ready() {
  local i
  for i in {1..50}; do
    nix "${NIX_EXTRA[@]}" --store "$INSTALLER_NIX_STORE" store info >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  die "nix-daemon did not become ready for installer store"
}

use_target_backed_nix() {
  local scratch=/mnt/.installer-nix
  local merged=$scratch/merged
  local upper=$scratch/store
  local work=$scratch/work
  local conf=$scratch/nix-conf
  local state=$scratch/var/nix
  local lower=/nix/.ro-store
  local old_upper=/nix/.rw-store/store

  if [[ -n ${INSTALLER_NIX_STORE:-} ]] && mountpoint -q "$INSTALLER_NIX_STORE"; then
    export TMPDIR=/mnt/var/tmp
    export TMP=/mnt/var/tmp
    export TEMP=/mnt/var/tmp
    export NIX_BUILD_TOP=/mnt/var/tmp
    return 0
  fi

  mountpoint -q /mnt || die "/mnt not mounted (need target root before nix work)"
  [[ -d $lower ]] || die "live ISO missing $lower"

  mkdir -p "$upper" "$work" "$merged" "$conf" "$state" /mnt/var/tmp /mnt/tmp
  chmod 1777 /mnt/var/tmp /mnt/tmp

  export TMPDIR=/mnt/var/tmp
  export TMP=/mnt/var/tmp
  export TEMP=/mnt/var/tmp
  export NIX_BUILD_TOP=/mnt/var/tmp

  if [[ -d $old_upper ]] && [[ -n $(ls -A "$old_upper" 2>/dev/null || true) ]]; then
    ui_spin "Copying nix store cache to target disk..." \
      cp -a "$old_upper"/. "$upper/"
  fi

  mount -t overlay overlay \
    -o "lowerdir=${lower},upperdir=${upper},workdir=${work}" \
    "$merged" || die "could not mount disk-backed nix store at $merged"

  cat >"$conf/nix.conf" <<EOF
experimental-features = nix-command flakes
store = $merged
EOF

  INSTALLER_NIX_STORE=$merged
  export INSTALLER_NIX_STORE
  export NIX_CONF_DIR=$conf
  export NIX_STATE_DIR=$state

  installer_stop_nix_daemon
  installer_start_nix_daemon "$conf" "$state"
  ui_spin "Waiting for nix-daemon on target disk..." installer_wait_nix_daemon_ready

  local avail_h
  avail_h="$(fmt_size "$(df -B1 --output=avail /mnt | tail -1 | tr -d ' ')")"
  ui_ok "nix store on target disk (${avail_h} free)"
}

restore_live_nix_store() {
  local scratch=/mnt/.installer-nix
  local merged=$scratch/merged

  [[ -n ${INSTALLER_NIX_STORE:-} || -d $scratch ]] || return 0

  installer_stop_nix_daemon
  if mountpoint -q "$merged" 2>/dev/null; then
    umount "$merged" 2>/dev/null || umount -l "$merged" 2>/dev/null || true
  fi
  INSTALLER_NIX_STORE=""
  unset NIX_CONF_DIR NIX_STATE_DIR
  systemctl start nix-daemon.service 2>/dev/null || true
}

cleanup_installer_nix_scratch() {
  restore_live_nix_store
  if [[ -d /mnt/.installer-nix ]]; then
    ui_spin "Removing installer scratch store on target..." rm -rf /mnt/.installer-nix
  fi
  rm -rf /mnt/var/tmp/nix-build-* /mnt/tmp/nix-build-* 2>/dev/null || true
}

expand_live_tmpfs_store() {
  enable_zram_swap || true
  if mountpoint -q /nix/.rw-store 2>/dev/null; then
    # Stretch tmpfs with zram backing so early gum/disko fetches can finish.
    mount -o remount,size=90% /nix/.rw-store 2>/dev/null ||
      mount -o remount,size=6G /nix/.rw-store 2>/dev/null || true
  fi
  reclaim_live_store || true
}

luks_format_open() {
  local part=$1
  local pbsz

  # Apple NVMe is 4096/4096; never fall back to 512-byte LUKS sectors on it.
  pbsz="$(blockdev --getpbsz "$part" 2>/dev/null || echo 0)"
  if [[ $pbsz == 4096 ]]; then
    cryptsetup luksFormat --type luks2 --sector-size 4096 --batch-mode \
      --key-file "$SECRETS/luks" "$part" ||
      die "LUKS format with 4096-byte sectors failed (disk physical sector size is 4096)"
  elif ! cryptsetup luksFormat --type luks2 --sector-size 4096 --batch-mode \
    --key-file "$SECRETS/luks" "$part"; then
    ui_warn "LUKS 4096-byte sectors not accepted, retrying with defaults"
    cryptsetup luksFormat --type luks2 --batch-mode --key-file "$SECRETS/luks" "$part"
  fi
  cryptsetup open --key-file "$SECRETS/luks" "$part" "$MAPPER"
  rm -f "$SECRETS/luks"
}

disko_run() {
  if [[ $HOST == air && $1 == *destroy* ]]; then
    die "refusing Disko destroy on air"
  fi
  ui_spin "Formatting and mounting..." \
    nix_flake run github:nix-community/disko/latest -- \
    --mode "$1" \
    "${@:2}" \
    --flake "path:$SCRIPT_DIR#$HOST"
}

air_part_state() {
  lsblk -n -b -r -o TYPE,PARTUUID,START,SIZE,FSTYPE,PARTLABEL "$DISK" |
    awk '$1 == "part" { print $2, $3, $4, $5, $6 }'
}

air_part_state_preserved() {
  lsblk -n -b -r -o TYPE,PARTUUID,START,SIZE,FSTYPE,PARTLABEL "$DISK" |
    awk '$1 == "part" && $6 != "nixos" { print $2, $3, $4, $5, $6 }'
}

air_linux_part_numbers() {
  lsblk -n -r -o TYPE,NAME,PARTLABEL "$DISK" |
    awk '$1 == "part" && $3 == "nixos" { sub(/^.*p/, "", $2); print $2 }'
}

# Bytes in nixos-labelled slices from a prior install (reclaimable on retry).
air_linux_reclaim_bytes() {
  local num dev bytes total=0
  while read -r num; do
    [[ -n $num ]] || continue
    dev="${DISK}p${num}"
    [[ -b $dev ]] || dev="${DISK}${num}"
    [[ -b $dev ]] || continue
    bytes="$(lsblk -n -b -d -o SIZE "$dev" 2>/dev/null || echo 0)"
    [[ $bytes =~ ^[0-9]+$ ]] || continue
    total=$((total + bytes))
  done < <(air_linux_part_numbers)
  echo "$total"
}

# GPT free gaps plus any nixos slice we will delete before installing.
air_installable_bytes() {
  local free_bytes=0 reclaim_bytes start_s end_s size_s

  if read -r start_s end_s free_bytes < <(air_largest_free_region); then
    :
  else
    free_bytes=0
  fi
  reclaim_bytes="$(air_linux_reclaim_bytes)"
  echo $((free_bytes + reclaim_bytes))
}

air_firmware_has_camera() {
  local cpio=$1
  cpio -t --quiet <"$cpio" 2>/dev/null | grep -qE '(^|\./)vendorfw/apple/isp_.*\.dat$'
}

air_find_appleh13camerad() {
  local candidate f
  if [[ -n ${APPLEH13CAMERAD:-} && -f $APPLEH13CAMERAD ]]; then
    printf '%s\n' "$APPLEH13CAMERAD"
    return 0
  fi
  for candidate in \
    "$REPO_ROOT/appleh13camerad" \
    "$HOME/appleh13camerad" \
    /tmp/appleh13camerad; do
    [[ -f $candidate ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  for f in /run/media/*/*/appleh13camerad /run/media/*/appleh13camerad; do
    [[ -f $f ]] || continue
    printf '%s\n' "$f"
    return 0
  done
  return 1
}

# Merge ISP calibration from macOS appleh13camerad when the ESP bundle lacks it.
air_ensure_camera_firmware() {
  local fw_dir=$1 esp_cpio=${2:-}
  local cpio="$fw_dir/firmware.cpio" cam tmp work

  [[ -f $cpio ]] || return 0

  if air_firmware_has_camera "$cpio"; then
    ui_ok "camera ISP firmware present"
    return 0
  fi

  cam=$(air_find_appleh13camerad || true)
  if [[ -z $cam ]]; then
    ui_warn "camera calibration missing from firmware.cpio (webcam will be low quality)"
    ui_faint "Copy /usr/sbin/appleh13camerad from macOS, set APPLEH13CAMERAD, re-run install."
    return 0
  fi

  ui_step "Merge camera firmware"
  tmp=$(mktemp -d)
  work="$tmp/work"
  mkdir -p "$work"
  (
    cd "$work"
    cpio -id --no-absolute-filenames --quiet <"$cpio"
    mkdir -p isp-in
    cp "$cam" isp-in/appleh13camerad
    nix shell "${NIX_EXTRA[@]}" nixpkgs#asahi-fwextract --command \
      python3 - isp-in vendorfw <<'PY'
import sys
from pathlib import Path
from asahi_firmware.isp import ISPFWCollection

source, dest = Path(sys.argv[1]), Path(sys.argv[2])
col = ISPFWCollection(str(source))
files = col.files()
if not files:
    raise SystemExit("no ISP calibration extracted from appleh13camerad")
for name, fwf in files:
    out = dest / name
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(fwf.data)
PY
    find vendorfw -print0 | cpio -o --null --quiet -H newc >firmware.cpio.new
    mv firmware.cpio.new "$cpio"
  ) || die "failed to merge camera ISP calibration"

  if [[ -n $esp_cpio && -f $esp_cpio && $esp_cpio != "$cpio" ]]; then
    ui_spin "Updating ESP firmware.cpio..." cp "$cpio" "$esp_cpio"
  fi
  ui_ok "camera ISP calibration merged"
}

# Tear down a partial/failed install so the nixos GPT slice can be recreated.
air_teardown_linux_stack() {
  swapoff /dev/mapper/air-swap 2>/dev/null || true
  swapoff /dev/disk/by-partlabel/nixos 2>/dev/null || true
  if mountpoint -q /mnt/efi 2>/dev/null; then
    umount /mnt/efi 2>/dev/null || true
  fi
  if mountpoint -q /mnt 2>/dev/null; then
    umount /mnt 2>/dev/null || true
  fi
  vgchange -an air 2>/dev/null || true
  cryptsetup close "$MAPPER" 2>/dev/null || true
  restore_live_nix_store 2>/dev/null || true
}

air_remove_linux_partitions() {
  local esp_dev=$1
  local -a nums=()
  local num dev preserved_before removed=0

  mapfile -t nums < <(air_linux_part_numbers)
  ((${#nums[@]} > 0)) || return 0

  ui_ok "removing ${#nums[@]} previous Linux partition(s)"
  preserved_before="$(air_part_state_preserved)"
  air_teardown_linux_stack

  for num in "${nums[@]}"; do
    dev="$(readlink -f "${DISK}p${num}" 2>/dev/null || true)"
    [[ -n $dev ]] || dev="$(readlink -f "${DISK}${num}" 2>/dev/null || true)"
    [[ -n $dev ]] || die "could not resolve partition ${num} on $DISK"
    [[ $dev != "$esp_dev" ]] || die "refusing to delete ESP partition"
    ui_spin "Deleting partition ${num}..." sgdisk "$DISK" -d "$num"
    removed=1
  done

  if ((removed)); then
    partprobe "$DISK"
    udevadm settle
    air_assert_preserved "$preserved_before" "$(air_part_state_preserved)"
  fi
}

air_assert_preserved() {
  local before=$1 after=$2 line
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    if ! grep -Fxq "$line" <<<"$after"; then
      die "existing partition changed: $line"
    fi
  done <<<"$before"
}

air_assert_esp() {
  local esp_uuid=$1
  local esp=/dev/disk/by-partuuid/$esp_uuid
  local parent fstype

  [[ -n $esp_uuid ]] || die "Asahi ESP partuuid is empty"
  [[ -b $esp ]] || die "ESP not found: $esp_uuid"
  fstype="$(lsblk -n -o FSTYPE "$esp")"
  [[ $fstype == vfat ]] || die "ESP is not vfat (got ${fstype:-unknown}): $esp_uuid"
  parent="$(lsblk -n -o PKNAME "$esp")"
  [[ $parent == "$(disk_short)" ]] || die "ESP $esp_uuid is on $parent, not $(disk_short)"
}

# Re-check that macOS/Asahi slices and the shared ESP are still intact.
air_safety_check() {
  local before=$1 esp_uuid=$2
  air_assert_preserved "$before" "$(air_part_state)"
  air_assert_esp "$esp_uuid"
}

swap_active_bytes() {
  swapon --noheadings --raw --bytes --show=SIZE 2>/dev/null | awk '{s+=$1} END {print s+0}'
}

zram_compression() {
  local dev=$1
  local algo sys

  [[ -n $dev ]] || {
    echo "$ZRAM_ALGORITHM"
    return
  }

  sys="/sys/block/$dev/comp_algorithm"
  [[ -f $sys ]] || {
    echo "$ZRAM_ALGORITHM"
    return
  }
  algo=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$sys")
  echo "${algo:-$ZRAM_ALGORITHM}"
}

swap_size_for() {
  local name=$1
  local raw_size=$2
  local base="${name##*/}"
  local sys size_bytes

  if [[ $base == zram* ]]; then
    sys="/sys/block/$base/disksize"
    if [[ -f $sys ]]; then
      size_bytes=$(<"$sys")
      if [[ $size_bytes =~ ^[0-9]+$ && $size_bytes -gt 0 ]]; then
        fmt_size "$size_bytes"
        return
      fi
    fi
  fi

  if [[ $raw_size =~ ^[0-9]+$ && $raw_size -gt 0 ]]; then
    fmt_size "$raw_size"
    return
  fi

  if [[ -n $raw_size && $raw_size != "-" ]]; then
    echo "$raw_size"
    return
  fi

  if [[ -b $name ]]; then
    size_bytes=$(lsblk -n -b -o SIZE "$name" 2>/dev/null | head -n1)
    if [[ $size_bytes =~ ^[0-9]+$ && $size_bytes -gt 0 ]]; then
      fmt_size "$size_bytes"
      return
    fi
  fi

  echo "unknown"
}

swap_chart_row() {
  local icon=$1 size=$2 kind=$3 detail=$4 color=$5 size_w=$6 kind_w=$7 detail_w=$8
  printf '%s\n' "$(
    ui_ansi "38;5;${color}" "$(
      printf '  %s  %*s  %-*s  %-*s' "$icon" "$size_w" "$size" "$kind_w" "$kind" "$detail_w" "$detail"
    )"
  )"
}

collect_swap_lines() {
  local name type size_bytes used_bytes base algo size_h used_h size_label
  local -a icons=() sizes=() kinds=() details=() colors=()
  local size_w=0 kind_w detail_w row i

  kind_w=${#SWAP_DISK_KIND}
  if ((${#SWAP_ZRAM_KIND} > kind_w)); then
    kind_w=${#SWAP_ZRAM_KIND}
  fi
  detail_w=${#SWAP_DISK_DETAIL}

  while read -r name type size_bytes used_bytes _ _; do
    [[ -n $name ]] || continue
    base="${name##*/}"
    size_h="$(swap_size_for "$name" "$size_bytes")"
    used_bytes="$(swap_used_bytes "$name" "$used_bytes")"
    if [[ $used_bytes =~ ^[0-9]+$ ]]; then
      used_h="$(fmt_size "$used_bytes")"
      size_label="${used_h}/${size_h}"
    else
      size_label="$size_h"
    fi
    if [[ $base == zram* ]]; then
      algo="$(zram_compression "$base")"
      [[ ${#algo} -gt $detail_w ]] && detail_w=${#algo}
      icons+=("$UI_ZRAM")
      sizes+=("$size_label")
      kinds+=("$SWAP_ZRAM_KIND")
      details+=("$algo")
      colors+=("$C_VIOLET")
    else
      icons+=("$UI_SWAP")
      sizes+=("$size_label")
      kinds+=("$SWAP_DISK_KIND")
      details+=("$SWAP_DISK_DETAIL")
      colors+=("$C_SUCCESS")
    fi
  done < <(swapon_table)

  for size_h in "${sizes[@]}"; do
    if ((${#size_h} > size_w)); then
      size_w=${#size_h}
    fi
  done

  for i in "${!icons[@]}"; do
    swap_chart_row "${icons[$i]}" "${sizes[$i]}" "${kinds[$i]}" "${details[$i]}" \
      "${colors[$i]}" "$size_w" "$kind_w" "$detail_w"
  done
}

ui_swap_box_render() {
  local body
  body="$(collect_swap_lines)"
  [[ -n $body ]] || return 1
  UI_SWAP_RENDERED="$(gum style \
    --border rounded \
    --border-foreground "$C_MUTED" \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --margin "$UI_MARGIN_LIVE_TOP" \
    --foreground "$C_TEXT" \
    "$(ui_box_label swap)" \
    "$body")"
}

ui_swap_box() {
  ui_swap_box_render || return 1
  ui_live_stack_refresh ""
}

reset_zram_swap() {
  local dev sys name

  while IFS= read -r dev; do
    [[ -n $dev ]] || continue
    swapoff "$dev" 2>/dev/null || true
  done < <(swapon --noheadings --show=NAME 2>/dev/null | grep -E 'zram[0-9]+$' || true)

  for sys in /sys/block/zram*; do
    [[ -e $sys/disksize ]] || continue
    name=$(basename "$sys")
    swapoff "/dev/$name" 2>/dev/null || true
    if [[ -e $sys/reset ]]; then
      echo 1 >"$sys/reset" 2>/dev/null || echo 0 >"$sys/reset" 2>/dev/null || true
    else
      echo 0 >"$sys/disksize" 2>/dev/null || true
    fi
  done

  if [[ -d /sys/module/zram ]]; then
    rmmod zram 2>/dev/null || true
  fi
}

live_store_avail() {
  if [[ -n ${INSTALLER_NIX_STORE:-} ]] && mountpoint -q "$INSTALLER_NIX_STORE"; then
    df -B1 --output=avail /mnt | tail -1 | tr -d ' '
  else
    df -B1 --output=avail /nix 2>/dev/null | tail -1 | tr -d ' '
  fi
}

reclaim_live_store() {
  pkill -TERM nixos-install 2>/dev/null || true
  pkill -TERM -f 'nix.*(build|copy)' 2>/dev/null || true
  sleep 0.5

  rm -rf /nix/var/nix/builds/* 2>/dev/null || true
  rm -rf /tmp/nix-* 2>/dev/null || true

  if command -v nix-collect-garbage >/dev/null 2>&1; then
    nix-collect-garbage -d >/dev/null 2>&1 || true
  elif command -v nix >/dev/null 2>&1; then
    nix store gc >/dev/null 2>&1 || true
  fi
}

deactivate_all_swap() {
  local dev sys name

  while IFS= read -r dev; do
    [[ -n $dev ]] || continue
    swapoff "$dev" 2>/dev/null || true
  done < <(swapon --noheadings --show=NAME 2>/dev/null || true)

  for sys in /sys/block/zram*; do
    [[ -e $sys/disksize ]] || continue
    if [[ -e $sys/reset ]]; then
      echo 1 >"$sys/reset" 2>/dev/null || echo 0 >"$sys/reset" 2>/dev/null || true
    else
      echo 0 >"$sys/disksize" 2>/dev/null || true
    fi
  done

  if [[ -d /sys/module/zram ]]; then
    rmmod zram 2>/dev/null || true
  fi
}

abort_cleanup() {
  reclaim_live_store
  restore_live_nix_store
  deactivate_all_swap
  if mountpoint -q /mnt/efi 2>/dev/null; then
    umount /mnt/efi 2>/dev/null || true
  fi
}

prepare_live_environment() {
  local avail min_free=$((8 * 1024 * 1024 * 1024))

  if mountpoint -q /mnt; then
    if [[ -n ${INSTALLER_NIX_STORE:-} ]] && mountpoint -q "$INSTALLER_NIX_STORE"; then
      export TMPDIR=/mnt/var/tmp
      export TMP=/mnt/var/tmp
      export TEMP=/mnt/var/tmp
      export NIX_BUILD_TOP=/mnt/var/tmp
      mkdir -p /mnt/var/tmp
      chmod 1777 /mnt/var/tmp
    else
      use_target_backed_nix
    fi
  else
    expand_live_tmpfs_store
  fi

  ui_spin "Reclaiming space on live system..." reclaim_live_store

  avail=$(live_store_avail)
  avail=${avail:-0}
  if ((avail < min_free)); then
    ui_warn "only $(fmt_size "$avail") free on /nix - large builds may fail"
  else
    ui_ok "$(fmt_size "$avail") free for nix fetches/builds"
  fi
}

enable_zram_swap() {
  local dev=/dev/zram0 mem_kb size_bytes

  reset_zram_swap
  sleep 0.2

  modprobe zram num_devices=1 2>/dev/null || return 1
  [[ -e /sys/block/zram0/disksize ]] || return 1

  echo "$ZRAM_ALGORITHM" > /sys/block/zram0/comp_algorithm 2>/dev/null ||
    echo lzo > /sys/block/zram0/comp_algorithm 2>/dev/null || true

  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  size_bytes=$((mem_kb * 1024 * ZRAM_MEMORY_PERCENT / 100))
  if ! echo "$size_bytes" > /sys/block/zram0/disksize 2>/dev/null; then
    reset_zram_swap
    return 1
  fi

  mkswap "$dev" >/dev/null 2>&1 || {
    reset_zram_swap
    return 1
  }
  swapon -p "$ZRAM_SWAP_PRIORITY" "$dev" 2>/dev/null || swapon "$dev" 2>/dev/null || {
    reset_zram_swap
    return 1
  }
}

activate_target_swap() {
  local dev activated=0

  vgchange -ay >/dev/null 2>&1 || true
  udevadm settle 2>/dev/null || true

  for dev in /dev/mapper/mina-swap /dev/mapper/air-swap; do
    [[ -b $dev ]] || continue
    if swapon "$dev" 2>/dev/null; then
      activated=1
    fi
  done

  while IFS= read -r dev; do
    [[ -n $dev && -b $dev ]] || continue
    if swapon "$dev" 2>/dev/null; then
      activated=1
    fi
  done < <(lsblk -pn -o NAME,FSTYPE | awk '$2 == "swap" {print $1}')

  [[ $activated -eq 1 ]]
}

ensure_swap() {
  enable_zram_swap || true
  activate_target_swap || true

  if [[ $(swap_active_bytes) -gt 0 ]]; then
    ui_swap_box
    return 0
  fi
  ui_warn "swap is off - install may run out of memory"
  return 1
}

hash_password() {
  local passfile=$1
  if command -v mkpasswd >/dev/null 2>&1; then
    mkpasswd -m yescrypt -s <"$passfile"
  elif command -v openssl >/dev/null 2>&1; then
    openssl passwd -6 -stdin <"$passfile"
  else
    nix_flake shell nixpkgs#mkpasswd --command mkpasswd -m yescrypt -s <"$passfile"
  fi
}

# Hash files live only under /run (tmpfs): 0700 dir, 0600 files. Mirrored to
# /mnt/run so nixos-install activation can read them in the target chroot.
# configuration.nix points hashedPasswordFile at these paths when they exist.
write_install_passwords() {
  local root_hash max_hash
  local target_run=/mnt/run/nixos-install-passwords

  root_hash="$(hash_password "$SECRETS/root")"
  max_hash="$(hash_password "$SECRETS/max")"
  [[ -n $root_hash && -n $max_hash ]] || die "failed to hash install passwords"

  rm -rf "$INSTALL_PASSWORDS_RUN" "$target_run"
  mkdir -p "$INSTALL_PASSWORDS_RUN" "$target_run"
  chmod 700 "$INSTALL_PASSWORDS_RUN" "$target_run"

  local old_umask
  old_umask="$(umask)"
  umask 077
  printf '%s' "$root_hash" >"$INSTALL_PASSWORDS_RUN/root.hash"
  printf '%s' "$max_hash" >"$INSTALL_PASSWORDS_RUN/max.hash"
  umask "$old_umask"
  chmod 600 "$INSTALL_PASSWORDS_RUN/root.hash" "$INSTALL_PASSWORDS_RUN/max.hash"

  cp -a "$INSTALL_PASSWORDS_RUN/root.hash" "$INSTALL_PASSWORDS_RUN/max.hash" "$target_run/"
  chmod 700 "$target_run"
  chmod 600 "$target_run/root.hash" "$target_run/max.hash"
}

# Passwords come from hashedPasswordFile during nixos-install; here we only
# fix home ownership and refuse to continue if max still has no password.
finalize_users() {
  local status
  ui_spin "Finalizing user accounts..." \
    nixos-enter --root /mnt -- chown -R max:users /home/max

  status="$(nixos-enter --root /mnt -- passwd -S max 2>/dev/null || true)"
  if ! [[ $status =~ [[:space:]]P[[:space:]] ]]; then
    die "max password is not set after install (passwd -S: ${status:-unknown})"
  fi
}

install_system() {
  local flake=/mnt/home/max/dotfiles/nixos
  local -a install_args=(
    --impure
    --no-root-password
    --no-channel-copy
    --root /mnt
    --flake "path:$flake#$HOST"
  )

  systemctl restart systemd-timesyncd || true
  ui_step "Install NixOS"
  if [[ $HOST == air ]]; then
    ui_ok "linux-asahi + Plasma build on target disk (slow, large)"
    # 8GB Air: one heavy derivation at a time keeps peak TMPDIR down.
    install_args+=(--max-jobs 1)
    export NIX_BUILD_CORES="${NIX_BUILD_CORES:-2}"
  fi
  prepare_live_environment
  ensure_swap
  write_install_passwords
  # --impure: configuration.nix gates hashedPasswordFile on /run pathExists
  ui_build_box nixos-install "${install_args[@]}" || die "failed to install system"
  finalize_users
  cleanup_installer_nix_scratch
}

install_mina() {
  command -v nixos-install >/dev/null || die "nixos-install not found"
  [[ -b $DISK ]] || die "$DISK not found"

  ui_step "Set up the disks (destructive)"
  ui_disk_diff_box "$(mina_disk_diff)"
  confirm "This WIPES $DISK."

  disko_run destroy,format,mount --yes-wipe-all-disks

  mountpoint -q /mnt || die "/mnt not mounted"
  use_target_backed_nix
  copy_repo
  install_system
}

install_air() {
  local esp_uuid esp part fw candidate before after nixos_dev esp_dev
  local free_start free_end free_bytes part_bytes

  command -v nixos-install >/dev/null || die "nixos-install not found"
  command -v cryptsetup >/dev/null && command -v sgdisk >/dev/null ||
    die "missing cryptsetup/sgdisk"
  command -v parted >/dev/null || die "missing parted (needed to find free space)"
  [[ -b $DISK ]] || die "$DISK not found"

  esp_uuid="$(tr -d '\0' < /proc/device-tree/chosen/asahi,efi-system-partition)"
  esp=/dev/disk/by-partuuid/$esp_uuid
  air_assert_esp "$esp_uuid"
  esp_dev="$(readlink -f "$esp")"

  # j313 / Apple NVMe: logical and physical are 4096; LUKS must match.
  [[ $(cat /sys/block/"$(disk_short)"/queue/physical_block_size) == 4096 ]] ||
    die "expected 4096-byte physical sectors on $DISK"
  [[ $(cat /sys/block/"$(disk_short)"/queue/logical_block_size) == 4096 ]] ||
    die "expected 4096-byte logical sectors on $DISK"

  free_bytes="$(air_installable_bytes)"
  if ((free_bytes < AIR_MIN_FREE_BYTES)); then
    die "need at least $(fmt_size "$AIR_MIN_FREE_BYTES") for NixOS on $DISK (found $(fmt_size "$free_bytes"))"
  fi

  ui_step "Create LUKS partition"
  ui_disk_diff_box "$(air_disk_diff "$esp_uuid")"
  confirm "Create a LUKS partition on $DISK ($(fmt_size "$free_bytes") available). Previous Linux installs are removed. iBoot, macOS, the ESP, and Recovery are left alone."

  air_remove_linux_partitions "$esp_dev"

  if ! read -r free_start free_end free_bytes < <(air_largest_free_region); then
    die "no free GPT gap on $DISK after removing previous Linux install"
  fi
  if ((free_bytes < AIR_MIN_FREE_BYTES)); then
    die "largest free region is $(fmt_size "$free_bytes"); need at least $(fmt_size "$AIR_MIN_FREE_BYTES")"
  fi

  before="$(air_part_state)"
  # Only claim the largest free gap (sectors from parted). Never touch existing slices.
  ui_spin "Creating partition..." \
    sgdisk "$DISK" -n "0:${free_start}:${free_end}" -t 0:8309 -c 0:nixos
  partprobe "$DISK"
  udevadm settle

  part=/dev/disk/by-partlabel/nixos
  for _ in {1..25}; do
    [[ -b $part ]] && break
    sleep 0.2
    udevadm settle || true
  done
  [[ -b $part ]] || die "new partition not found"
  nixos_dev="$(readlink -f "$part")"
  [[ $nixos_dev != "$esp_dev" ]] || die "refusing to format the ESP"
  part_bytes="$(lsblk -n -b -d -o SIZE "$part")"
  [[ $part_bytes =~ ^[0-9]+$ ]] || die "could not read new partition size"
  if ((part_bytes < AIR_MIN_FREE_BYTES)); then
    die "new partition is only $(fmt_size "$part_bytes") - refused (likely hit an alignment gap)"
  fi

  after="$(air_part_state)"
  air_safety_check "$before" "$esp_uuid"
  if [[ $(grep -c . <<<"$after") -ne $(($(grep -c . <<<"$before") + 1)) ]]; then
    die "expected exactly one new partition"
  fi

  ui_step "Encrypt disk"
  # Format LUKS here (4096-byte sectors). Root LVM/xfs is created next without Disko.
  luks_format_open "$part"
  [[ $nixos_dev == "$(readlink -f "$part")" ]] || die "nixos partition moved"
  air_safety_check "$before" "$esp_uuid"

  ui_step "Format and mount"
  # Manual LVM/xfs — same layout as disko.devices — so we never fetch Disko
  # into the tiny live tmpfs before the target disk exists.
  ui_spin "Formatting LVM and mounting..." air_lvm_format_mount
  mountpoint -q /mnt || die "/mnt not mounted"
  air_safety_check "$before" "$esp_uuid"
  use_target_backed_nix

  # Shared Asahi/macOS ESP — mount only, never mkfs/wipefs.
  if mountpoint -q /mnt/efi 2>/dev/null; then
    umount /mnt/efi || die "could not unmount stale /mnt/efi"
  fi
  mkdir -p /mnt/efi
  ui_spin "Mounting Asahi ESP..." mount -o umask=0077 "$esp" /mnt/efi
  mountpoint -q /mnt/efi || die "/mnt/efi not mounted"
  [[ $(readlink -f "$(findmnt -n -o SOURCE /mnt/efi)") == "$esp_dev" ]] ||
    die "/mnt/efi is not the Asahi ESP ($esp_uuid)"
  for _ in {1..25}; do
    [[ -f /mnt/efi/vendorfw/firmware.cpio ]] && break
    sleep 0.2
  done

  ui_step "Copy firmware"
  copy_repo
  mkdir -p /mnt/home/max/dotfiles/nixos/hosts/air/firmware
  fw=""
  for candidate in /mnt/efi/vendorfw/firmware.cpio /efi/vendorfw/firmware.cpio /boot/vendorfw/firmware.cpio; do
    if [[ -f $candidate ]]; then
      fw=$candidate
      break
    fi
  done
  [[ -n $fw ]] || die "firmware.cpio not found on the ESP"
  ui_spin "Copying firmware..." cp "$fw" /mnt/home/max/dotfiles/nixos/hosts/air/firmware/
  air_ensure_camera_firmware /mnt/home/max/dotfiles/nixos/hosts/air/firmware "$fw"

  cat >/mnt/home/max/dotfiles/nixos/hosts/air/hardware.nix <<EOF
{
  lib,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  # Asahi shared ESP (macOS + m1n1). Mount only — do not format.
  fileSystems."/efi" = {
    device = "/dev/disk/by-partuuid/${esp_uuid}";
    fsType = "vfat";
    options = [ "umask=0077" ];
    neededForBoot = true;
  };
}
EOF

  install_system
}

finish() {
  local choice header

  gum style \
    --border rounded \
    --border-foreground "$C_SUCCESS" \
    --bold \
    --foreground "$C_SUCCESS" \
    --align center \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --margin "$UI_MARGIN_SECTION" \
    "${UI_OK} Done."

  if [[ ${INSTALL_YES:-} == 1 ]]; then
    return 0
  fi

  header="Installation complete - what next?"
  if [[ $HOST == air ]]; then
    header="$header
$(ui_faint "Hold power at boot for the Apple boot picker if you need macOS.")"
  fi

  choice="$(
    gum choose --height 2 --header "$header" \
      "${UI_MARK} Reboot into NixOS" \
      "${UI_FAIL} Exit to shell"
  )" || exit 0

  case $choice in
    *Reboot*)
      stop_sleep_inhibit
      reboot
      ;;
  esac
}

if [[ $EUID -ne 0 ]]; then
  exec sudo env \
    INSTALL_YES="${INSTALL_YES:-}" \
    TERM="${TERM:-}" \
    COLORTERM="${COLORTERM:-}" \
    "$0" "$@"
fi

export NIX_CONFIG="experimental-features = nix-command flakes"

# Stretch the live tmpfs store before the first nix fetch (gum).
expand_live_tmpfs_store

if ! command -v gum >/dev/null 2>&1; then
  exec nix "${NIX_EXTRA[@]}" shell nixpkgs#gum --command env \
    INSTALL_YES="${INSTALL_YES:-}" \
    TERM="${TERM:-}" \
    COLORTERM="${COLORTERM:-}" \
    TMPDIR="${TMPDIR:-}" \
    TMP="${TMP:-}" \
    TEMP="${TEMP:-}" \
    "$0" "$@"
fi

theme
trap on_interrupt INT
trap cleanup EXIT
start_sleep_inhibit

detected="$(detect_host)"
if [[ $# -gt 0 ]]; then
  [[ $1 == mina || $1 == air ]] || die "usage: $0 [mina|air]"
  HOST=$1
  [[ $HOST == "$detected" ]] || die "this machine is $detected, not $HOST"
else
  HOST=$detected
fi

SECRETS="$(mktemp -d /run/nixos-install.XXXXXX)"
chmod 700 "$SECRETS"

if [[ $HOST == air ]]; then
  STEP_TOTAL=6
  INSTALLER_OUTLINE="- Passwords
- Create LUKS partition
- Encrypt disk
- Format and mount
- Copy firmware
- Install NixOS"
else
  STEP_TOTAL=3
  INSTALLER_OUTLINE="- Passwords
- Set up the disks (destructive)
- Install NixOS"
fi
STEP_N=0

ui_banner "$HOST" "$INSTALLER_OUTLINE"

ui_step "Passwords"
ask_password "$SECRETS/luks" "Disk encryption password"
cp "$SECRETS/luks" "$LUKS_PASSFILE"
chmod 600 "$LUKS_PASSFILE"
ask_password "$SECRETS/root" "root password"
ask_password "$SECRETS/max" "max password"
ui_ok "Passwords saved"

case $HOST in
  mina) install_mina ;;
  air) install_air ;;
esac

finish
