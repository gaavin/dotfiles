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
C_ACCENT=39
C_SUCCESS=42
C_WARN=214
C_DANGER=196
C_MUTED=245
C_TEXT=252
C_VIOLET=141

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
  gum spin --spinner dot --title "◌ $title" --show-error -- "$@"
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
  if [[ $bytes =~ ^[0-9]+$ ]]; then
    if command -v numfmt >/dev/null 2>&1; then
      numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null && return
    fi
    awk -v b="$bytes" 'BEGIN {
      split("B KiB MiB GiB TiB", u, " ")
      i = 1
      while (b >= 1024 && i < 5) { b /= 1024; i++ }
      printf "%.1f%s", b, u[i]
    }'
  else
    echo "$bytes"
  fi
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

disk_diff_header() {
  local disk_name size_h
  disk_name="$(disk_short)"
  size_h="$(disk_size_human)"
  ui_diff_ctx "--- $disk_name · $size_h"
  ui_diff_ctx "+++ $disk_name · planned"
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

mina_disk_diff() {
  local part_count=0 name size fstype label mount type spec

  {
    disk_diff_header
    while read -r name size fstype label mount type; do
      [[ ${type:-} == part ]] || continue
      part_count=$((part_count + 1))
      spec="$(part_label_display "$label" "" "$name")  $(fmt_size "$size")"
      [[ -n $fstype && $fstype != "-" ]] && spec="$spec  $fstype"
      [[ -n $mount && $mount != "-" ]] && spec="$spec  mount $mount"
      ui_diff_del "$spec  (wiped)"
    done < <(lsblk -n -r -o NAME,SIZE,FSTYPE,PARTLABEL,MOUNTPOINT,TYPE "$DISK" 2>/dev/null || true)

    if [[ $part_count -eq 0 ]]; then
      ui_diff_ctx "(empty disk)"
    fi

    ui_diff_add "ESP  2G  vfat  /efi"
    ui_diff_add "nixos  LUKS  cryptroot"
    ui_diff_add "  swap  8G"
    ui_diff_add "  root  xfs  /  (remaining space)"
  }
}

air_disk_diff() {
  local name size fstype label mount type parttypename role display spec

  {
    disk_diff_header
    while read -r name size fstype label mount type parttypename; do
      [[ ${type:-} == part ]] || continue
      display="$(part_label_display "$label" "$parttypename" "$name")"
      spec="$display  $(fmt_size "$size")"
      [[ -n $fstype && $fstype != "-" ]] && spec="$spec  $fstype"
      [[ -n $mount && $mount != "-" ]] && spec="$spec  mount $mount"
      role="$(part_role_air "$label" "$fstype" "$parttypename")"
      case $role in
        esp) ui_diff_mod "$spec  (mount at /efi, not formatted)" ;;
        preserved) ui_diff_ctx "$spec  (preserved)" ;;
      esac
    done < <(lsblk -n -r -o NAME,SIZE,FSTYPE,PARTLABEL,MOUNTPOINT,TYPE,PARTTYPENAME "$DISK" 2>/dev/null || true)

    ui_diff_add "nixos  LUKS  cryptroot  (free space)"
    ui_diff_add "  swap  8G"
    ui_diff_add "  root  xfs  /  (remaining space)"
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
    echo lz4
    return
  }

  sys="/sys/block/$dev/comp_algorithm"
  [[ -f $sys ]] || {
    echo lz4
    return
  }
  algo=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$sys")
  echo "${algo:-lz4}"
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

collect_swap_lines() {
  local name type size_bytes base algo size_h
  local -a zram_lines=() disk_lines=()

  while read -r name type size_bytes _ _; do
    [[ -n $name ]] || continue
    base="${name##*/}"
    size_h="$(swap_size_for "$name" "$size_bytes")"
    if [[ $base == zram* ]]; then
      algo="$(zram_compression "$base")"
      zram_lines+=("$(ui_ansi "38;5;${C_VIOLET}" "  ⚡ ${size_h}  zram ${algo}")")
    else
      disk_lines+=("$(ui_ansi "38;5;${C_SUCCESS}" "  💾 ${size_h}  swap partition")")
    fi
  done < <(swapon_table)

  ((${#zram_lines[@]})) && printf '%s\n' "${zram_lines[@]}"
  ((${#disk_lines[@]})) && printf '%s\n' "${disk_lines[@]}"
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

  echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null ||
    echo lzo > /sys/block/zram0/comp_algorithm 2>/dev/null || true

  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  size_bytes=$((mem_kb * 1024))
  echo "$size_bytes" > /sys/block/zram0/disksize

  mkswap "$dev" >/dev/null 2>&1 || return 1
  swapon -p 100 "$dev" 2>/dev/null || swapon "$dev" 2>/dev/null || return 1
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
  local flake=/mnt/home/max/dotfiles/nixos
  systemctl restart systemd-timesyncd || true
  ui_step "Install NixOS"
  if [[ $HOST == air ]]; then
    ui_ok "⚙ linux-asahi will compile from source"
  fi
  ensure_swap
  nixos-install --no-root-password --no-channel-copy --root /mnt --flake "path:$flake#$HOST"
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
