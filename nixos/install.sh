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
HOST=""
STEP_N=0
STEP_TOTAL=0

die() {
  if command -v gum >/dev/null 2>&1; then
    gum log --level error "$1"
  else
    echo "$1" >&2
  fi
  exit 1
}

cleanup() {
  reset_zram_swap
  if [[ -n ${SECRETS:-} && -d $SECRETS ]]; then
    rm -rf "$SECRETS"
  fi
  rm -f "$LUKS_PASSFILE" /mnt/root/chpasswd
}

nix_flake() {
  command nix "${NIX_EXTRA[@]}" "$@"
}

UI_WIDTH=64
UI_PAD_H=2
NIXOS_VERSION="26.11 unstable"
ZRAM_ALGORITHM=lz4
ZRAM_MEMORY_PERCENT=100
ZRAM_SWAP_PRIORITY=100
SWAP_ZRAM_KIND=zram
SWAP_DISK_KIND=swap
SWAP_DISK_DETAIL=partition
C_ACCENT=39
C_SUCCESS=42
C_WARN=214
C_DANGER=196
C_MUTED=245
C_TEXT=252
C_VIOLET=141
C_SPIN=201

theme() {
  export GUM_INPUT_CURSOR_FOREGROUND="$C_ACCENT"
  export GUM_INPUT_PROMPT_FOREGROUND="$C_ACCENT"
  export GUM_INPUT_HEADER_FOREGROUND="$C_VIOLET"
  export GUM_INPUT_WIDTH="$UI_WIDTH"
  export GUM_INPUT_CHAR_LIMIT="512"
  export GUM_INPUT_PROMPT="🔑 "
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
    mina) echo "🖥" ;;
    air) echo "💻" ;;
    *) echo "⌁" ;;
  esac
}

ui_ansi() {
  printf '\033[%sm%s\033[0m' "$1" "$2"
}

ui_faint() {
  ui_ansi "2" "$1"
}

ui_installer_icon() {
  case $1 in
    *Password*) printf '🔐' ;;
    *destructive*) printf '⚠' ;;
    *LUKS*) printf '🧩' ;;
    *Encrypt*) printf '🔒' ;;
    *Format*) printf '💾' ;;
    *firmware*) printf '📦' ;;
    *Install*) printf '⚙' ;;
    *) printf '▸' ;;
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
  local host=$1 label
  label="$(host_icon "$host") $host · $(host_arch)"
  gum style \
    --border rounded \
    --border-foreground "$C_ACCENT" \
    --bold \
    --foreground "$C_ACCENT" \
    --align center \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --margin "1 0 0 0" \
    "❄ NixOS" \
    "$(ui_ansi "2;38;5;${C_VIOLET}" "◈ Version $NIXOS_VERSION")" \
    "$(ui_faint "$label")"
}

ui_heading() {
  gum style \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --margin "1 0 0 0" \
    --bold \
    --foreground "$C_ACCENT" \
    "◆ $1"
}

ui_body() {
  gum style \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --foreground "$C_TEXT" \
    "$@"
}

ui_installer() {
  local body=$1 line icon color
  ui_heading "Installer"
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    line="${line#- }"
    icon="$(ui_installer_icon "$line")"
    color="$(ui_installer_color "$line")"
    gum style \
      --width "$UI_WIDTH" \
      --padding "0 $UI_PAD_H" \
      --foreground "$color" \
      "  $icon  $line"
  done <<< "$body"
}

ui_ok() {
  gum style \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --foreground "$C_SUCCESS" \
    "✔ $1"
}

ui_warn() {
  gum style \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --foreground "$C_WARN" \
    "⚠ $1"
}

ui_step() {
  STEP_N=$((STEP_N + 1))
  gum style \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --margin "1 0 0 0" \
    "$(ui_ansi "1;38;5;${C_ACCENT}" "▸ $STEP_N/$STEP_TOTAL") $(ui_ansi "1;38;5;${C_TEXT}" "$1")"
}

ui_spin() {
  local title=$1
  shift
  local log status=0 pid i=0 pad line
  local -a frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  log="$(mktemp)"
  pad="$(printf '%*s' "$UI_PAD_H" '')"

  "$@" >"$log" 2>&1 &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    line="${pad}$(ui_ansi "38;5;${C_SPIN}" "${frames[i]}") $(ui_ansi "38;5;${C_ACCENT}" "$title")"
    if [[ -e /dev/tty ]]; then
      printf '\r%-*s' "$UI_WIDTH" "$line" >/dev/tty
    else
      printf '\r%-*s' "$UI_WIDTH" "$line" >&2
    fi
    i=$(((i + 1) % ${#frames[@]}))
    sleep 0.08
  done

  wait "$pid" || status=$?

  if ((status == 0)); then
    line="${pad}$(ui_ansi "38;5;${C_SUCCESS}" "✔") $(ui_ansi "38;5;${C_TEXT}" "$title")"
  else
    line="${pad}$(ui_ansi "38;5;${C_DANGER}" "✕") $(ui_ansi "38;5;${C_TEXT}" "$title")"
  fi
  ui_tty "$line"

  if ((status != 0)); then
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

ui_build_truncate() {
  local text=$1 max=$2
  text="${text//[$'\t\r\n']/ }"
  if ((${#text} > max)); then
    printf '%s…' "${text:0:max-1}"
  else
    printf '%s' "$text"
  fi
}

ui_build_json_num() {
  sed -n "s/.*\"$2\":\\([0-9]*\\).*/\\1/p" <<<"$1" | head -1
}

ui_build_json_fields105() {
  sed -n 's/.*"fields":\[\([0-9]*\),\([0-9]*\),\([0-9]*\),\([0-9]*\)\].*/\1 \2 \3 \4/p' <<<"$1" | head -1
}

ui_build_json_text() {
  sed -n 's/.*"text":"\(.*\)","type".*/\1/p' <<<"$1" |
    sed 's/\\"/"/g; s/\\n/ /g; s/\\u001b\[[0-9;]*m//g'
}

ui_build_percent() {
  local done=$1 expected=$2
  if ((expected > 0)); then
    echo $((done * 100 / expected))
  else
    echo 0
  fi
}

ui_build_bar() {
  local percent=$1 width=28 filled=0 bar='' i
  if ((percent < 0)); then
    percent=0
  elif ((percent > 100)); then
    percent=100
  fi
  filled=$((percent * width / 100))
  for ((i = 0; i < width; i++)); do
    if ((i < filled)); then
      bar+='█'
    else
      bar+='░'
    fi
  done
  printf '%s' "$bar"
}

ui_build_box_poll() {
  local log=$1
  local -n _done=$2 _expected=$3 _running=$4 _activity=$5 _builds_id=$6
  local line num text d e r f id

  [[ -f $log ]] || return 0

  while IFS= read -r line; do
    [[ $line == @nix\ * ]] || continue
    line="${line#@nix }"
    if [[ $line == *'"action":"start"'* && $line == *'"type":104'* && $line == *'"parent":0'* ]]; then
      id="$(ui_build_json_num "$line" id)"
      [[ -n $id ]] && _builds_id=$id
    elif [[ $line == *'"action":"result"'* && $line == *'"type":105'* ]]; then
      read -r d e r f <<<"$(ui_build_json_fields105 "$line")"
      [[ -n $e ]] || continue
      id="$(ui_build_json_num "$line" id)"
      if [[ -n $_builds_id && $id == "$_builds_id" ]]; then
        _done=${d:-0}
        _expected=$e
        _running=${r:-0}
      elif ((e >= _expected)); then
        _done=${d:-0}
        _expected=$e
        _running=${r:-0}
      fi
    elif [[ $line == *'"action":"start"'* ]]; then
      text="$(ui_build_json_text "$line")"
      [[ -n $text ]] || continue
      if [[ $text == building* ]]; then
        _activity="$text"
      elif [[ $_activity == starting* ]]; then
        _activity="$text"
      fi
    fi
  done <"$log"
}

ui_build_box_render() {
  local done=$1 expected=$2 running=$3 activity=$4
  local -n _height=$5
  local bar body rendered lines width percent
  width=$((UI_WIDTH - UI_PAD_H * 2 - 4))
  percent="$(ui_build_percent "$done" "$expected")"
  activity="$(ui_build_truncate "$activity" "$width")"
  bar="$(ui_build_bar "$percent")"
  body="$activity"
  body+=$'\n'"$(ui_ansi "38;5;${C_SPIN}" "$bar") $(ui_faint "${percent}/100")"
  if ((running > 0)); then
    body+=$'\n'"$(ui_faint "$running active")"
  fi

  rendered="$(gum style \
    --border rounded \
    --border-foreground "$C_MUTED" \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --margin "1 0 0 0" \
    --foreground "$C_TEXT" \
    "$(ui_ansi "38;5;${C_MUTED}" "▤ build")" \
    "$body")"

  lines="$(printf '%s\n' "$rendered" | wc -l)"
  if (($_height > 0)); then
    { tput cuu "$_height" && tput ed; } >/dev/tty 2>&1 || true
  fi
  ui_tty "$rendered"
  _height=$lines
}

ui_build_box() {
  local log out status=0 height=0 pid builds_id=0
  local done=0 expected=0 running=0 activity='starting…'
  log="$(mktemp)"
  out="$(mktemp)"

  ui_build_box_render "$done" "$expected" "$running" "$activity" height

  "$@" --log-format internal-json >"$out" 2>"$log" &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    ui_build_box_poll "$log" done expected running activity builds_id
    ui_build_box_render "$done" "$expected" "$running" "$activity" height
    sleep 0.15
  done

  wait "$pid" || status=$?

  ui_build_box_poll "$log" done expected running activity builds_id
  if ((status != 0)); then
    activity='build failed'
  elif ((expected > 0 && done >= expected)); then
    activity='done'
  fi
  ui_build_box_render "$done" "$expected" "$running" "$activity" height

  if ((status != 0)); then
    grep -E '^error:|^warning:' "$log" 2>/dev/null | tail -5 >&2 || true
    rm -f "$log" "$out"
    return "$status"
  fi

  tail -1 "$out"
  rm -f "$log" "$out"
}

ui_box() {
  gum style \
    --border rounded \
    --border-foreground "$C_MUTED" \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --margin "1 0 0 0" \
    --foreground "$C_TEXT" \
    "$(ui_ansi "38;5;${C_MUTED}" "▤ storage")" \
    "$1"
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

disk_size_human() {
  fmt_size "$(lsblk -n -b -d -o SIZE "$DISK" 2>/dev/null || echo 0)"
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

part_role_air() {
  local label=$1 fstype=$2 parttypename=$3
  local l="${label,,}"
  local t="${parttypename,,}"

  if [[ $fstype == vfat || $t == *efi* ]]; then
    echo esp
    return
  fi

  case "$l" in
    *iboot*|*macos*|*recovery*|*asahi*|*stub*) echo preserved; return ;;
    *efi*|*esp*) echo esp; return ;;
  esac

  case "$t" in
    *iboot*|*apple*boot*) echo preserved; return ;;
    *apfs*|*macos*|*hfs*) echo preserved; return ;;
    *recovery*) echo preserved; return ;;
    *asahi*) echo preserved; return ;;
  esac

  echo preserved
}

disk_lsblk() {
  lsblk -P -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINT,TYPE,PARTTYPENAME,PKNAME "$DISK" 2>/dev/null || true
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
    crypt) icon="🔒" ;;
    lvm) icon="📦" ;;
    part) icon="💿" ;;
    *) icon="▸" ;;
  esac

  printf '%s %s' "$icon" "$spec"
}

disk_build_parent_map() {
  local -n out=$1
  local -n typemap=$2
  local line crypt_name= luks_part= name pk

  while IFS= read -r line; do
    [[ -z $line ]] && continue
    NAME= SIZE= FSTYPE= LABEL= PARTLABEL= MOUNTPOINT= TYPE= PARTTYPENAME= PKNAME=
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
  local disk_name size_h
  disk_name="$(disk_short)"
  size_h="$(disk_size_human)"
  ui_diff_ctx "--- ${disk_name} · ${size_h}"
  ui_diff_ctx "+++ ${disk_name} · planned"
  ui_diff_ctx ""
}

mina_disk_diff() {
  local line removed=0 depth indent spec
  local -A pkmap=()
  local -A devtypes=()

  disk_build_parent_map pkmap devtypes

  {
    disk_diff_header

    while IFS= read -r line; do
      [[ -z $line ]] && continue
      NAME= SIZE= FSTYPE= LABEL= PARTLABEL= MOUNTPOINT= TYPE= PARTTYPENAME= PKNAME=
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
      ui_diff_ctx "  (empty disk)"
    fi

    ui_diff_ctx ""
    ui_diff_add "💿 ESP  2G  vfat  /efi"
    ui_diff_add "💿 nixos  LUKS"
    ui_diff_add "  🔒 cryptroot"
    ui_diff_add "    📦 swap  8G"
    ui_diff_add "    📦 root  xfs  /"
  }
}

ui_disk_diff_box() {
  gum style \
    --border rounded \
    --border-foreground "$C_MUTED" \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --margin "1 0 0 0" \
    --foreground "$C_TEXT" \
    "$(ui_ansi "38;5;${C_MUTED}" "▤ storage")" \
    "$1"
}

air_disk_diff() {
  local line role indent spec
  local -A pkmap=()
  local -A devtypes=()

  disk_build_parent_map pkmap devtypes

  {
    disk_diff_header

    while IFS= read -r line; do
      [[ -z $line ]] && continue
      NAME= SIZE= FSTYPE= LABEL= PARTLABEL= MOUNTPOINT= TYPE= PARTTYPENAME= PKNAME=
      eval "$line"
      [[ ${TYPE:-} == disk ]] && continue
      [[ ${TYPE:-} == part ]] || continue
      indent="$(disk_display_indent "$(disk_tree_depth "$NAME" pkmap)")"
      spec="$(disk_entry_desc "$NAME" "$SIZE" "$FSTYPE" "$LABEL" "$PARTLABEL" "$MOUNTPOINT" "$TYPE")"
      role="$(part_role_air "$PARTLABEL" "$FSTYPE" "$PARTTYPENAME")"
      case $role in
        esp) ui_diff_mod "${indent}${spec}  (mount at /efi, not formatted)" ;;
        preserved) ui_diff_ctx "${indent}${spec}  (preserved)" ;;
      esac
    done < <(disk_lsblk)

    ui_diff_ctx ""
    ui_diff_add "🔒 nixos  LUKS  cryptroot  (free space)"
    ui_diff_add "  📦 swap  8G"
    ui_diff_add "  📦 root  xfs  /"
  }
}

ask_password() {
  local dest=$1 header=$2 pass pass2
  while true; do
    pass="$(gum input --password --header "🔐 $header" --placeholder "password" --char-limit 0)" || exit 1
    if [[ -z $pass ]]; then
      ui_warn "Password cannot be empty"
      continue
    fi
    pass2="$(gum input --password --header "🔐 Confirm $header" --placeholder "confirm" --char-limit 0)" || exit 1
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
  gum confirm --default=false --affirmative "Continue →" --negative "✕ Cancel" "$1" || {
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
      nix "${NIX_EXTRA[@]}" shell nixpkgs#git --command git clone "$REPO_URL" /mnt/home/max/dotfiles
  fi
}

luks_format_open() {
  local part=$1
  if ! cryptsetup luksFormat --type luks2 --sector-size 4096 --batch-mode --key-file "$SECRETS/luks" "$part"; then
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
    nix "${NIX_EXTRA[@]}" run github:nix-community/disko/latest -- \
    --mode "$1" \
    "${@:2}" \
    --flake "path:$SCRIPT_DIR#$HOST"
}

air_part_state() {
  lsblk -n -b -r -o TYPE,PARTUUID,START,SIZE,FSTYPE,PARTLABEL "$DISK" |
    awk '$1 == "part" { print $2, $3, $4, $5, $6 }'
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
  [[ -b $esp ]] || die "ESP not found: $esp_uuid"
  [[ $(lsblk -n -o FSTYPE "$esp") == vfat ]] || die "ESP is not vfat: $esp_uuid"
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
  local name type size_bytes base algo size_h
  local -a icons=() sizes=() kinds=() details=() colors=()
  local size_w=0 kind_w detail_w row i

  kind_w=${#SWAP_DISK_KIND}
  if ((${#SWAP_ZRAM_KIND} > kind_w)); then
    kind_w=${#SWAP_ZRAM_KIND}
  fi
  detail_w=${#SWAP_DISK_DETAIL}

  while read -r name type size_bytes _ _; do
    [[ -n $name ]] || continue
    base="${name##*/}"
    size_h="$(swap_size_for "$name" "$size_bytes")"
    if [[ $base == zram* ]]; then
      algo="$(zram_compression "$base")"
      [[ ${#algo} -gt $detail_w ]] && detail_w=${#algo}
      icons+=("⚡")
      sizes+=("$size_h")
      kinds+=("$SWAP_ZRAM_KIND")
      details+=("$algo")
      colors+=("$C_VIOLET")
    else
      icons+=("💾")
      sizes+=("$size_h")
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

ui_swap_box() {
  local body
  body="$(collect_swap_lines)"
  [[ -n $body ]] || return 1
  gum style \
    --border rounded \
    --border-foreground "$C_MUTED" \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --margin "1 0 0 0" \
    --foreground "$C_TEXT" \
    "$(ui_ansi "38;5;${C_MUTED}" "▤ swap")" \
    "$body"
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
      echo 0 >"$sys/reset" 2>/dev/null || true
    else
      echo 0 >"$sys/disksize" 2>/dev/null || true
    fi
  done

  if [[ -d /sys/module/zram ]]; then
    rmmod zram 2>/dev/null || true
  fi
}

enable_zram_swap() {
  local dev=/dev/zram0 mem_kb size_bytes

  reset_zram_swap

  modprobe zram num_devices=1 2>/dev/null || return 1
  [[ -e /sys/block/zram0/disksize ]] || return 1

  echo "$ZRAM_ALGORITHM" > /sys/block/zram0/comp_algorithm 2>/dev/null ||
    echo lzo > /sys/block/zram0/comp_algorithm 2>/dev/null || true

  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  size_bytes=$((mem_kb * 1024 * ZRAM_MEMORY_PERCENT / 100))
  echo "$size_bytes" > /sys/block/zram0/disksize

  mkswap "$dev" >/dev/null 2>&1 || return 1
  swapon -p "$ZRAM_SWAP_PRIORITY" "$dev" 2>/dev/null || swapon "$dev" 2>/dev/null || return 1
}

activate_target_swap() {
  local dev activated=0

  vgchange -ay 2>/dev/null || true
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
  ui_warn "⚙ swap is off — install may run out of memory"
  return 1
}

set_passwords() {
  {
    printf 'root:%s\n' "$(cat "$SECRETS/root")"
    printf 'max:%s\n' "$(cat "$SECRETS/max")"
  } >"$SECRETS/chpasswd"
  chmod 600 "$SECRETS/chpasswd"
  mkdir -p /mnt/root
  cp "$SECRETS/chpasswd" /mnt/root/chpasswd
  chmod 600 /mnt/root/chpasswd
  ui_spin "Setting user passwords..." \
    nixos-enter --root /mnt -c 'chpasswd < /root/chpasswd && chown -R max:users /home/max'
  rm -f /mnt/root/chpasswd
}

install_system() {
  local flake=/mnt/home/max/dotfiles/nixos system
  systemctl restart systemd-timesyncd || true
  ui_step "Install NixOS"
  if [[ $HOST == air ]]; then
    ui_ok "⚙ linux-asahi will compile from source"
  fi
  ensure_swap
  system="$(
    ui_build_box nix "${NIX_EXTRA[@]}" build \
      "path:$flake#nixosConfigurations.$HOST.config.system.build.toplevel" \
      --print-out-paths
  )" || die "failed to build system"
  ui_spin "Installing system..." \
    nixos-install --system "$system" --no-root-password --no-channel-copy --root /mnt
  set_passwords
}

install_mina() {
  command -v nixos-install >/dev/null || die "nixos-install not found"
  [[ -b $DISK ]] || die "$DISK not found"

  ui_step "Set up the disks (destructive)"
  ui_disk_diff_box "$(mina_disk_diff)"
  confirm "This WIPES $DISK."

  disko_run destroy,format,mount --yes-wipe-all-disks

  mountpoint -q /mnt || die "/mnt not mounted"
  copy_repo
  install_system
}

install_air() {
  local esp_uuid esp part fw candidate before after nixos_dev esp_dev
  command -v nixos-install >/dev/null || die "nixos-install not found"
  command -v cryptsetup >/dev/null && command -v sgdisk >/dev/null ||
    die "missing cryptsetup/sgdisk"
  [[ -b $DISK ]] || die "$DISK not found"
  [[ ! -e /dev/disk/by-partlabel/nixos ]] || die "/dev/disk/by-partlabel/nixos already exists; aborting"

  esp_uuid="$(tr -d '\0' < /proc/device-tree/chosen/asahi,efi-system-partition)"
  esp=/dev/disk/by-partuuid/$esp_uuid
  air_assert_esp "$esp_uuid"
  esp_dev="$(readlink -f "$esp")"

  ui_step "Create LUKS partition"
  ui_disk_diff_box "$(air_disk_diff)"
  confirm "Create a LUKS partition in the free space on $DISK. iBoot, macOS, the ESP, and Recovery are left alone."

  before="$(air_part_state)"
  # 0:0:0 = first free number, first free start, end of that gap — existing slices stay
  ui_spin "Creating partition..." sgdisk "$DISK" -n 0:0:0 -t 0:8309 -c 0:nixos
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

  after="$(air_part_state)"
  air_assert_preserved "$before" "$after"
  air_assert_esp "$esp_uuid"
  if [[ $(grep -c . <<<"$after") -ne $(($(grep -c . <<<"$before") + 1)) ]]; then
    die "expected exactly one new partition"
  fi

  ui_step "Encrypt disk"
  luks_format_open "$part"
  [[ $nixos_dev == "$(readlink -f "$part")" ]] || die "nixos partition moved"
  air_assert_preserved "$before" "$(air_part_state)"
  air_assert_esp "$esp_uuid"

  ui_step "Format and mount"
  disko_run format,mount
  mountpoint -q /mnt || die "/mnt not mounted"
  air_assert_preserved "$before" "$(air_part_state)"
  air_assert_esp "$esp_uuid"
  mkdir -p /mnt/efi
  ui_spin "Mounting original ESP..." mount "$esp" /mnt/efi
  mountpoint -q /mnt/efi || die "/mnt/efi not mounted"
  [[ $(readlink -f "$(findmnt -n -o SOURCE /mnt/efi)") == "$esp_dev" ]] || die "/mnt/efi is not the original ESP"
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

  fileSystems."/efi" = {
    device = "/dev/disk/by-partuuid/${esp_uuid}";
    fsType = "vfat";
    options = [ "umask=0077" ];
  };
}
EOF

  install_system
}

finish() {
  local msg="↻ reboot."
  if [[ $HOST == air ]]; then
    msg="↻ reboot, then hold power for the Apple boot picker if you need macOS."
  fi
  gum style \
    --border rounded \
    --border-foreground "$C_SUCCESS" \
    --bold \
    --foreground "$C_SUCCESS" \
    --align center \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --margin "1 0 0 0" \
    "✔ Done." \
    "$(ui_faint "$msg")"
}

if [[ $EUID -ne 0 ]]; then
  exec sudo env \
    INSTALL_YES="${INSTALL_YES:-}" \
    TERM="${TERM:-}" \
    COLORTERM="${COLORTERM:-}" \
    "$0" "$@"
fi

export NIX_CONFIG="experimental-features = nix-command flakes"

if ! command -v gum >/dev/null 2>&1; then
  exec nix "${NIX_EXTRA[@]}" shell nixpkgs#gum --command env \
    INSTALL_YES="${INSTALL_YES:-}" \
    TERM="${TERM:-}" \
    COLORTERM="${COLORTERM:-}" \
    "$0" "$@"
fi

theme
trap cleanup EXIT

detected="$(detect_host)"
if [[ $# -gt 0 ]]; then
  [[ $1 == mina || $1 == air ]] || die "usage: $0 [mina|air]"
  HOST=$1
  [[ $HOST == "$detected" ]] || die "this machine is $detected, not $HOST"
else
  HOST=$detected
fi

ui_banner "$HOST"

SECRETS="$(mktemp -d /run/nixos-install.XXXXXX)"
chmod 700 "$SECRETS"

if [[ $HOST == air ]]; then
  STEP_TOTAL=6
else
  STEP_TOTAL=3
fi
STEP_N=0

if [[ $HOST == air ]]; then
  ui_installer "- Passwords
- Create LUKS partition
- Encrypt disk
- Format and mount
- Copy firmware
- Install NixOS"
else
  ui_installer "- Passwords
- Set up the disks (destructive)
- Install NixOS"
fi

ui_step "Passwords"
ask_password "$SECRETS/luks" "Disk encryption password"
cp "$SECRETS/luks" "$LUKS_PASSFILE"
chmod 600 "$LUKS_PASSFILE"
ask_password "$SECRETS/root" "root password"
ask_password "$SECRETS/max" "max password"
ui_ok "🔐 Passwords saved"

case $HOST in
  mina) install_mina ;;
  air) install_air ;;
esac

finish
