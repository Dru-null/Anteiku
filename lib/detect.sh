#!/usr/bin/env bash
# ============================================================
#  detect.sh — shared hardware/software detection.
#  Sourced by doctor.sh and setup.sh. Reads only; writes nothing.
# ============================================================
# Library: the C_*, S_* and DET_* variables are read by the scripts that
# source this file, so shellcheck cannot see them used here.
# shellcheck disable=SC2034
#
# Tests only: ANTEIKU_DETECT_ROOT=<dir> makes detection read /etc, /proc,
# /sys and /dev/dri under <dir> (a fixture), and report device paths as
# they would be on the real machine. Unset, the real ones are read.
# Tools (lspci, ss, docker, ...) are swapped through PATH: tests/detect/.

# --- output helpers ---------------------------------------------------
# Colour only on a real terminal, and never when NO_COLOR is set
# (https://no-color.org). Unicode symbols only when the locale says UTF-8;
# otherwise plain ASCII of the same width, so alignment never breaks.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
  C_INF=$'\033[36m'; C_GREY=$'\033[90m'
  # Crimson for titles and what matters; a muted crimson for notes, so a
  # paragraph of advice doesn't read as an error. Exact where the terminal
  # says it can, nearest of 256 otherwise, plain red on anything older.
  case "${COLORTERM:-}:${TERM:-}" in
    truecolor:*|24bit:*) C_CRIM=$'\033[38;2;200;50;60m'; C_NOTE=$'\033[38;2;178;110;114m' ;;
    *:*256color*)        C_CRIM=$'\033[38;5;161m';       C_NOTE=$'\033[38;5;138m' ;;
    *)                   C_CRIM=$'\033[31m';             C_NOTE=$'\033[31m' ;;
  esac
  C_ACC="$C_CRIM"   # the picker's cursor and "new" tags
else
  C_RST=''; C_B=''; C_DIM=''; C_OK=''; C_WARN=''; C_ERR=''
  C_INF=''; C_ACC=''; C_GREY=''; C_CRIM=''; C_NOTE=''
fi
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf-8*|*UTF8*|*utf8*)
    S_OK='✔'; S_WARN='▲'; S_ERR='✖'; S_INFO='ℹ'; S_RULE='─'; S_DOT='·'
    S_ON='✓'; S_LOCK='■'; S_PROMPT='›'
    S_TL='╭'; S_TR='╮'; S_BL='╰'; S_BR='╯'; S_V='│' ;;
  *)
    S_OK='+'; S_WARN='!'; S_ERR='x'; S_INFO='i'; S_RULE='-'; S_DOT='-'
    S_ON='x'; S_LOCK='='; S_PROMPT='>'
    S_TL='+'; S_TR='+'; S_BL='+'; S_BR='+'; S_V='|' ;;
esac

FINDINGS_WARN=0
FINDINGS_ERR=0

# _pad "text" width -> text padded to width CHARACTERS. printf's %-20s pads
# by bytes, so any line with a dash or a dot in it comes out short and
# the columns stop lining up.
_pad() { local t="$1" n=$(( $2 - ${#1} )); printf '%s' "$t"; [ "$n" -gt 0 ] && printf '%*s' "$n" ''; return 0; }

_rule() { local n="$1" out=""; while [ "$n" -gt 0 ]; do out="$out$S_RULE"; n=$((n-1)); done; printf '%s' "$out"; }

# banner "title" "subtitle"
banner() {
  local w=60
  printf '%s%s%s%s%s\n' "$C_CRIM" "$S_TL" "$(_rule $w)" "$S_TR" "$C_RST"
  printf '%s%s%s  %s%s%s%s%s%s\n' "$C_CRIM" "$S_V" "$C_RST" "$C_B" "$(_pad "$1" $((w-2)))" "$C_RST" "$C_CRIM" "$S_V" "$C_RST"
  [ -n "${2:-}" ] && printf '%s%s%s  %s%s%s%s%s%s\n' "$C_CRIM" "$S_V" "$C_RST" "$C_GREY" "$(_pad "$2" $((w-2)))" "$C_RST" "$C_CRIM" "$S_V" "$C_RST"
  printf '%s%s%s%s%s\n' "$C_CRIM" "$S_BL" "$(_rule $w)" "$S_BR" "$C_RST"
}

# Section header:  ── Title ─────────────
h1() {
  local t="$1" n=$(( 56 - ${#1} )); [ "$n" -lt 3 ] && n=3
  printf '\n%s%s%s %s%s%s %s%s%s\n' "$C_CRIM" "$(_rule 2)" "$C_RST" "$C_B$C_CRIM" "$t" "$C_RST" "$C_GREY" "$(_rule $n)" "$C_RST"
}
kv()   { printf '  %s%-20s%s %s\n' "$C_GREY" "$1" "$C_RST" "$2"; }
ok()   { printf '  %s%s%s  %s\n' "$C_OK"   "$S_OK"   "$C_RST" "$1"; }
info() { printf '  %s%s%s  %s\n' "$C_INF"  "$S_INFO" "$C_RST" "$1"; }
warn() { printf '  %s%s%s  %s%s%s\n' "$C_WARN" "$S_WARN" "$C_RST" "$C_WARN" "$1" "$C_RST"; FINDINGS_WARN=$((FINDINGS_WARN+1)); }
err()  { printf '  %s%s%s  %s%s%s%s\n' "$C_ERR" "$S_ERR" "$C_RST" "$C_B" "$C_ERR" "$1" "$C_RST"; FINDINGS_ERR=$((FINDINGS_ERR+1)); }
note() { printf '     %s%s%s\n' "$C_NOTE" "$1" "$C_RST"; }

have() { command -v "$1" >/dev/null 2>&1; }

# Resolve to an absolute path. Relative paths are ambiguous the moment
# compose includes a file from a subdirectory, and the failure is silent:
# the stack comes up fine with your data somewhere you did not intend.
abspath() {
  local p="$1" head tail
  case "$p" in /*) printf '%s\n' "$p"; return ;; esac
  # The folder may not exist yet (a dry run creates nothing): resolve the
  # part that does, keep the rest as written.
  head="$(dirname "$p")"; tail="$(basename "$p")"
  while [ ! -d "$head" ]; do tail="$(basename "$head")/$tail"; head="$(dirname "$head")"; done
  printf '%s\n' "$(cd "$head" && pwd)/$tail"
}

# existing_dir <path> -> the path, or its nearest parent that exists.
# df and stat need a real folder; it sits on the same filesystem as a
# folder that will be created under it.
existing_dir() {
  local p="$1"
  while [ ! -d "$p" ]; do p="$(dirname "$p")"; done
  printf '%s\n' "$p"
}

# --- system -----------------------------------------------------------
detect_os() {
  local R="${ANTEIKU_DETECT_ROOT:-}"
  DET_DISTRO="unknown"; DET_DISTRO_VER=""; DET_DISTRO_ID=""; DET_DISTRO_LIKE=""
  if [ -r "$R/etc/os-release" ]; then
    # shellcheck disable=SC1091
    . "$R/etc/os-release"
    DET_DISTRO="${NAME:-unknown}"; DET_DISTRO_VER="${VERSION_ID:-}"
    DET_DISTRO_ID="${ID:-}"; DET_DISTRO_LIKE="${ID_LIKE:-}"
  fi
  DET_KERNEL="$(uname -r)"
  DET_ARCH="$(uname -m)"
  # timedatectl needs systemd running. Without it: /etc/timezone (Debian
  # only), then the /etc/localtime link (every distro), then UTC.
  local lt
  DET_TZ_FROM=timedatectl
  if ! DET_TZ="$(timedatectl show -p Timezone --value 2>/dev/null)" || [ -z "$DET_TZ" ]; then
    DET_TZ_FROM=/etc/timezone
    if ! DET_TZ="$(cat "$R/etc/timezone" 2>/dev/null)" || [ -z "$DET_TZ" ]; then
      DET_TZ_FROM=/etc/localtime; DET_TZ=""
      lt="$(readlink "$R/etc/localtime" 2>/dev/null)"
      case "$lt" in */zoneinfo/?*) DET_TZ="${lt#*/zoneinfo/}" ;; esac
      [ -z "$DET_TZ" ] && { DET_TZ_FROM=default; DET_TZ='Etc/UTC'; }
    fi
  fi
  DET_UID="$(id -u)"; DET_GID="$(id -g)"
}

detect_cpu() {
  local R="${ANTEIKU_DETECT_ROOT:-}"
  DET_CPU="$(awk -F': ' '/^model name/{print $2; exit}' "$R/proc/cpuinfo" 2>/dev/null)"
  [ -z "$DET_CPU" ] && DET_CPU="$(awk -F': ' '/^Model/{print $2; exit}' "$R/proc/cpuinfo" 2>/dev/null)"
  [ -z "$DET_CPU" ] && DET_CPU="unknown"
  DET_CORES="$(nproc 2>/dev/null || echo '?')"
  DET_CPU_VENDOR="other"
  case "$DET_CPU" in
    *Intel*) DET_CPU_VENDOR="intel" ;;
    *AMD*)   DET_CPU_VENDOR="amd" ;;
  esac
}

# MemTotal is a little under the RAM installed (the kernel and firmware keep
# some): a 4 GB machine reads about 3.7 GiB. Keep MiB for comparisons and
# show GiB with one decimal; flooring to whole GiB made it "3" (T-042).
# Sets DET_MEM_MIB, DET_MEM_GIB ("3.7"), DET_SWAP_MIB, DET_SWAP_GIB.
_kb_gib() { local t=$(( ($1 * 10 + 524288) / 1048576 )); echo "$(( t / 10 )).$(( t % 10 ))"; }
detect_mem() {
  local kb R="${ANTEIKU_DETECT_ROOT:-}"
  kb="$(awk '/^MemTotal:/{print $2; exit}' "$R/proc/meminfo" 2>/dev/null)"
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
  DET_MEM_MIB=$(( kb / 1024 )); DET_MEM_GIB="$(_kb_gib "$kb")"
  kb="$(awk '/^SwapTotal:/{print $2; exit}' "$R/proc/meminfo" 2>/dev/null)"
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
  DET_SWAP_MIB=$(( kb / 1024 )); DET_SWAP_GIB="$(_kb_gib "$kb")"
}

# --- GPU --------------------------------------------------------------
# Sets DET_GPUS (human list), DET_GPU_VENDORS (space-separated: intel amd nvidia),
# DET_GPU_OTHER (display adapters with no video encoder: VMs, server BMCs),
# DET_NVIDIA_DRIVER (the kernel driver bound to the NVIDIA card: nvidia,
# nouveau, or empty for none) and DET_RENDER_NODES ("node|pcipath|driver"
# per line).
#
# Vendors come from sysfs (PCI class 0x03xxxx = display), which every Linux
# has. lspci is optional (minimal Debian and Arch lack it) and only gives
# the model names.
detect_gpu() {
  local R="${ANTEIKU_DETECT_ROOT:-}"
  DET_GPUS=""; DET_GPU_VENDORS=""; DET_GPU_OTHER=""; DET_NVIDIA_DRIVER=""; DET_RENDER_NODES=""

  local d class vendor device drv slot name sysnames=""
  for d in "$R"/sys/bus/pci/devices/*; do
    [ -r "$d/class" ] || continue
    class="$(cat "$d/class" 2>/dev/null)"; [ "${class#0x03}" = "$class" ] && continue
    vendor="$(cat "$d/vendor" 2>/dev/null)"; device="$(cat "$d/device" 2>/dev/null)"
    drv=""; [ -e "$d/driver" ] && drv="$(basename "$(readlink -f "$d/driver")")"
    slot="${d##*/}"; slot="${slot#0000:}"
    case "$vendor" in
      0x8086) name="Intel";  DET_GPU_VENDORS="$DET_GPU_VENDORS intel" ;;
      0x1002) name="AMD";    DET_GPU_VENDORS="$DET_GPU_VENDORS amd" ;;
      0x10de) name="NVIDIA"; DET_GPU_VENDORS="$DET_GPU_VENDORS nvidia"
              [ -z "$DET_NVIDIA_DRIVER" ] && DET_NVIDIA_DRIVER="${drv:-none}" ;;
      0x1af4) name="virtio-gpu (virtual machine)" ;;
      0x1234) name="QEMU standard VGA (virtual machine)" ;;
      0x1a03) name="ASPEED (server management graphics)" ;;
      *)      name="display adapter $vendor" ;;
    esac
    case "$vendor" in
      0x8086|0x1002|0x10de) ;;
      *) DET_GPU_OTHER="${DET_GPU_OTHER:+$DET_GPU_OTHER, }$name" ;;
    esac
    sysnames="${sysnames}${slot} ${name} [${vendor#0x}:${device#0x}]"$'\n'
  done
  [ "$DET_NVIDIA_DRIVER" = none ] && DET_NVIDIA_DRIVER=""

  if have lspci; then
    while IFS= read -r line; do
      [ -n "$line" ] && DET_GPUS="${DET_GPUS}${line}"$'\n'
    done <<< "$(lspci 2>/dev/null | grep -iE 'vga|3d controller|display controller' || true)"
  fi
  # No lspci: name them from sysfs instead, ids and all.
  [ -z "$DET_GPUS" ] && DET_GPUS="$sysnames"

  # Render nodes, with the STABLE by-path id. Bare /dev/dri/renderD128 is
  # NOT stable across reboots on a machine with two GPUs — the numbers can
  # swap, and a container pinned to the wrong one fails to transcode.
  if [ -d "$R/dev/dri" ]; then
    local n base drv path
    for n in "$R"/dev/dri/renderD*; do
      [ -e "$n" ] || continue
      base="$(basename "$n")"
      drv="$(basename "$(readlink -f "$R/sys/class/drm/$base/device/driver" 2>/dev/null)" 2>/dev/null)"
      [ -z "$drv" ] && drv="unknown"
      path=""
      if [ -d "$R/dev/dri/by-path" ]; then
        local p
        for p in "$R"/dev/dri/by-path/*-render; do
          [ -e "$p" ] || continue
          if [ "$(readlink -f "$p")" = "$(readlink -f "$n")" ]; then path="${p#"$R"}"; break; fi
        done
      fi
      [ -z "$path" ] && path="(no by-path entry)"
      DET_RENDER_NODES="${DET_RENDER_NODES}${n#"$R"}|${path}|${drv}"$'\n'
    done
  fi

  DET_GPU_VENDORS="$(echo "$DET_GPU_VENDORS" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
}

# --- render group + per-vendor render node ----------------------------
# Two things that differ on every machine and break transcoding silently
# if you hardcode them:
#   DET_RENDER_GID  - gid of the group owning /dev/dri/render*. A container
#                     not in it opens the device read-only, Jellyfin falls
#                     back to CPU, and nothing logs an error.
#   DET_*_RENDER    - the by-path symlink for a given vendor's card. Stable
#                     across reboots; the bare renderD12X number is not.
detect_render() {
  local R="${ANTEIKU_DETECT_ROOT:-}"
  DET_RENDER_GID=""; DET_INTEL_RENDER=""; DET_AMD_RENDER=""; DET_NVIDIA_RENDER=""

  local grp
  for grp in render video; do
    DET_RENDER_GID="$(getent group "$grp" 2>/dev/null | cut -d: -f3)"
    [ -n "$DET_RENDER_GID" ] && { DET_RENDER_GROUP="$grp"; break; }
  done
  # Fall back to whatever group actually owns the device.
  if [ -z "$DET_RENDER_GID" ] && [ -e "$R/dev/dri/renderD128" ]; then
    DET_RENDER_GROUP="$(stat -c %G "$R/dev/dri/renderD128" 2>/dev/null)"
    DET_RENDER_GID="$(stat -c %g "$R/dev/dri/renderD128" 2>/dev/null)"
  fi

  local node path drv
  while IFS='|' read -r node path drv; do
    [ -z "$node" ] && continue
    [ "${path#/dev/dri/by-path/}" = "$path" ] && continue   # no stable id
    case "$drv" in
      i915|xe)              [ -z "$DET_INTEL_RENDER" ]  && DET_INTEL_RENDER="$path" ;;
      amdgpu|radeon)        [ -z "$DET_AMD_RENDER" ]    && DET_AMD_RENDER="$path" ;;
      nvidia|nouveau)       [ -z "$DET_NVIDIA_RENDER" ] && DET_NVIDIA_RENDER="$path" ;;
    esac
  done <<< "$DET_RENDER_NODES"
}

# What an NVIDIA card still needs before Jellyfin can use it: one line per
# missing piece, nothing when it is ready. Needs detect_gpu and
# detect_docker. A container that asks Docker for an NVIDIA GPU it can't
# provide does not start at all; it never falls back to the CPU.
nvidia_missing() {
  case " ${DET_GPU_VENDORS:-} " in
    *" nvidia "*) ;;
    *) echo "an NVIDIA card (none found)"; return 0 ;;
  esac
  case "${DET_NVIDIA_DRIVER:-}" in
    nvidia) ;;
    nouveau) echo "the proprietary NVIDIA driver (the card is on nouveau, which has no NVENC)" ;;
    "")      echo "the proprietary NVIDIA driver (no driver is loaded for the card)" ;;
    *)       echo "the proprietary NVIDIA driver (the card is on $DET_NVIDIA_DRIVER)" ;;
  esac
  if [ "${DET_DOCKER_OK:-0}" -ne 1 ]; then
    echo "a check of Docker's nvidia runtime (Docker isn't reachable)"
  elif [ "${DET_DOCKER_NVIDIA:-0}" -ne 1 ]; then
    echo "nvidia-container-toolkit (docker info lists no nvidia runtime)"
  fi
}

# Which GPU profile should Jellyfin use? Echoes: intel|nvidia|amd|cpu
# Intel wins over a discrete NVIDIA card on purpose - see doctor.sh.
# NVIDIA only when nvidia_missing is empty: otherwise Jellyfin won't start.
pick_gpu_profile() {
  if [ -n "${DET_INTEL_RENDER:-}" ]; then echo intel; return; fi
  case "$DET_GPU_VENDORS" in
    *nvidia*) [ -z "$(nvidia_missing)" ] && { echo nvidia; return; } ;;
  esac
  if [ -n "${DET_AMD_RENDER:-}" ]; then echo amd; return; fi
  echo cpu
}

# --- docker -----------------------------------------------------------
detect_docker() {
  DET_DOCKER_VER=""; DET_COMPOSE_VER=""; DET_DOCKER_OK=0
  DET_DOCKER_ROOTLESS=0; DET_IN_DOCKER_GROUP=0; DET_DOCKER_NVIDIA=0
  DET_DOCKER_ROOT=""; DET_DOCKER_STORE=""
  if have docker; then
    DET_DOCKER_VER="$(docker --version 2>/dev/null | sed 's/^Docker version //; s/,.*//')"
    local info
    if info="$(docker info 2>/dev/null)"; then
      DET_DOCKER_OK=1
      grep -qi 'rootless' <<< "$info" && DET_DOCKER_ROOTLESS=1
      # nvidia-container-toolkit registers this runtime (nvidia-ctk runtime
      # configure); without it Docker can't give a container the card.
      grep -qE '^ *Runtimes:(.* )?nvidia( |$)' <<< "$info" && DET_DOCKER_NVIDIA=1
      DET_DOCKER_ROOT="$(sed -n 's/^ *Docker Root Dir: *//p' <<< "$info" | head -n 1)"
      # Docker 29's default image store is containerd's; the classic one
      # (overlay2 and friends) has no driver-type line.
      if grep -qE '^ *driver-type: *io\.containerd\.snapshotter' <<< "$info"; then DET_DOCKER_STORE=containerd
      elif grep -qE '^ *Storage Driver: *[^ ]' <<< "$info"; then DET_DOCKER_STORE=classic; fi
    fi
    DET_COMPOSE_VER="$(docker compose version --short 2>/dev/null || true)"
  fi
  id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker && DET_IN_DOCKER_GROUP=1
}

# No Docker, or a daemon this user can't reach: doctor's blockers and
# setup.sh's warning or refusal say it in the same words (T-078).
MSG_DOCKER_ABSENT="Docker is not installed. Nothing here can run without it."
MSG_DOCKER_INSTALL="Install: https://docs.docker.com/engine/install/"
MSG_DOCKER_DOWN="Docker is installed but the daemon is not reachable as this user."
MSG_DOCKER_GROUP="You are not in the 'docker' group. Fix, then log out and back in:"
MSG_DOCKER_GROUP_FIX="  sudo usermod -aG docker \$USER"
MSG_DOCKER_START="Is it running?  sudo systemctl status docker"
# docker_why -> why Docker can't be asked: "Docker is not installed" or
# "Docker is not reachable"; nothing when it can.
docker_why() {
  if [ -z "${DET_DOCKER_VER:-}" ]; then echo "Docker is not installed"
  elif [ "${DET_DOCKER_OK:-0}" -ne 1 ]; then echo "Docker is not reachable"; fi
}
# docker_fix_notes: how to reach an installed daemon, after MSG_DOCKER_DOWN.
docker_fix_notes() {
  if [ "${DET_IN_DOCKER_GROUP:-0}" -eq 0 ]; then
    note "$MSG_DOCKER_GROUP"
    note "$MSG_DOCKER_GROUP_FIX"
  else
    note "$MSG_DOCKER_START"
  fi
}

# Docker without the Compose plugin (a distro's docker.io): doctor's
# blocker and setup.sh's warning say it in the same words (T-073). No
# generation number: "v2" named the plugin against v1's docker-compose
# script, and the plugin's own versions are 5.x now (T-077).
MSG_COMPOSE_OK="Compose plugin present — 'docker compose', the syntax this repo uses."
MSG_COMPOSE_MISSING="The Compose plugin ('docker compose') is missing."
MSG_COMPOSE_OLD="The old 'docker-compose' script will not work here."
MSG_COMPOSE_INSTALL="Install the plugin: https://docs.docker.com/compose/install/"
# compose_missing -> 0 if Docker is installed and its compose plugin isn't.
compose_missing() { [ -n "$DET_DOCKER_VER" ] && [ -z "$DET_COMPOSE_VER" ]; }

# --- remote access ----------------------------------------------------
detect_tailscale() {
  DET_TS_INSTALLED=0; DET_TS_UP=0; DET_TS_IP=""; DET_TS_NAME=""
  have tailscale || return 0
  DET_TS_INSTALLED=1
  DET_TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"
  [ -n "$DET_TS_IP" ] && DET_TS_UP=1
  DET_TS_NAME="$(tailscale status --json 2>/dev/null \
    | grep -oE '"DNSName"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 \
    | sed 's/.*"\([^"]*\)"$/\1/; s/\.$//')"
}

# --- ports ------------------------------------------------------------
# ports_checkable -> 0 if ss or netstat can list what is listening.
ports_checkable() { have ss || have netstat; }

# port_in_use <port> -> 0 if something is listening, 1 if nothing is,
# 2 if it can't tell (neither ss nor netstat). Never read 2 as free.
port_in_use() {
  local p="$1"
  if have ss; then
    ss -lntuH 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${p}\$" && return 0
  elif have netstat; then
    netstat -lntu 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$" && return 0
  else
    return 2
  fi
  return 1
}

# who_has_port <port> -> best-effort owner.
# Unprivileged ss cannot name a root-owned process (docker-proxy is the usual
# one), so fall back to asking Docker which container publishes the port.
who_has_port() {
  local p="$1" out=""
  if have ss; then
    out="$(ss -lntupH 2>/dev/null | grep -E "[:.]${p} " \
           | grep -oE 'users:\(\("[^"]+' | head -1 | sed 's/.*"//')"
  fi
  if [ -z "$out" ] && have docker && docker info >/dev/null 2>&1; then
    local c
    c="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null \
         | grep -E "[:.]${p}->" | awk '{print $1}' | head -1)"
    [ -n "$c" ] && out="container '${c}'"
  fi
  if [ -z "$out" ]; then
    # Suggest the tool that is installed.
    if have ss; then out="unidentified (try: sudo ss -lntup | grep :${p})"
    else out="unidentified (try: sudo netstat -lntup | grep :${p})"; fi
  fi
  echo "$out"
}

# port_held_by_project <port> <project> [service] -> the compose service of
# <project>'s running container that publishes <port> (a service given:
# only that one). 1 if none, or Docker can't be asked. setup.sh uses it so
# a re-run doesn't move a service off its own port; doctor.sh so it
# doesn't call the install's own containers a clash (T-074).
port_held_by_project() {
  [ "${DET_DOCKER_OK:-0}" -eq 1 ] && [ -n "$2" ] || return 1
  local by=(--filter "label=com.docker.compose.project=$2") s
  [ -n "${3:-}" ] && by+=(--filter "label=com.docker.compose.service=$3")
  s="$(docker ps "${by[@]}" --format '{{.Label "com.docker.compose.service"}} {{.Ports}}' 2>/dev/null \
       | grep -E "[:.]$1->" | head -n 1 | cut -d' ' -f1)"
  [ -n "$s" ] && echo "$s"
}

# --- host tools -------------------------------------------------------
# Optional tools, what each is for, and its package per family:
#   tool|debian package|fedora package|arch package
# Checked against each distro's package search (Debian trixie, Ubuntu
# 26.04, Fedora 43, Arch), 2026-11-06.
HOST_TOOLS="
ss|iproute2|iproute|iproute2
netstat|net-tools|net-tools|net-tools
lspci|pciutils|pciutils|pciutils
curl|curl|curl|curl
git|git|git|git
crontab|cron|cronie|cronie
timedatectl|systemd|systemd|systemd
"

# pkg_family -> debian | fedora | arch, or nothing: from os-release ID
# and ID_LIKE (Ubuntu says ID_LIKE=debian, RHEL and Rocky list fedora,
# Manjaro "arch").
pkg_family() {
  local w f="${ANTEIKU_DETECT_ROOT:-}/etc/os-release"
  # update.sh doesn't run detect_os: read the two keys here.
  if [ -z "${DET_DISTRO_ID+x}" ] && [ -r "$f" ]; then
    DET_DISTRO_ID="$(sed -n 's/^ID=//p' "$f" | tr -d "\"'" | head -n 1)"
    DET_DISTRO_LIKE="$(sed -n 's/^ID_LIKE=//p' "$f" | tr -d "\"'" | head -n 1)"
  fi
  for w in ${DET_DISTRO_ID:-} ${DET_DISTRO_LIKE:-}; do
    case "$w" in
      debian|ubuntu) echo debian; return ;;
      fedora) echo fedora; return ;;
      arch) echo arch; return ;;
    esac
  done
}

# pkg_of <tool> -> its package on this distro family, or nothing.
pkg_of() {
  local fam col t deb fed arc
  fam="$(pkg_family)"
  while IFS='|' read -r t deb fed arc; do
    [ "$t" = "$1" ] || continue
    case "$fam" in debian) col="$deb" ;; fedora) col="$fed" ;; arch) col="$arc" ;; *) col="" ;; esac
    echo "$col"; return
  done <<< "$HOST_TOOLS"
}

# install_hint <tool>... -> one line: the command for this distro's
# package manager, or a generic line naming the tools. Never apt on a
# distro that doesn't have it.
install_hint() {
  local t pkgs="" fam
  fam="$(pkg_family)"
  if [ -z "$fam" ]; then
    echo "Install them with your distro's package manager: $*"; return
  fi
  for t in "$@"; do
    case " $pkgs " in *" $(pkg_of "$t") "*) ;; *) pkgs="${pkgs:+$pkgs }$(pkg_of "$t")" ;; esac
  done
  case "$fam" in
    debian) echo "Install: sudo apt install $pkgs" ;;
    fedora) echo "Install: sudo dnf install $pkgs" ;;
    arch)   echo "Install: sudo pacman -S $pkgs" ;;
  esac
}

# cron_hint -> how to get a crontab that also runs: Fedora and Arch
# install cronie without starting it (Arch doesn't even enable it).
# MSG_CRONTAB_MISSING: doctor's warning and setup's "Next" note (T-060).
MSG_CRONTAB_MISSING="crontab not found: update.sh --schedule can't add the weekly check."
cron_hint() {
  case "$(pkg_family)" in
    debian) echo "Install: sudo apt install cron" ;;
    fedora) echo "Install: sudo dnf install cronie && sudo systemctl enable --now crond" ;;
    arch)   echo "Install: sudo pacman -S cronie && sudo systemctl enable --now cronie" ;;
    *)      echo "Install a cron daemon (cronie or cron) with your distro's package manager, and start it." ;;
  esac
}

# --- disk -------------------------------------------------------------
# fs_of <path> -> filesystem mountpoint; free_gb <path> -> whole GB free.
# GB are decimal, as the README states sizes, and floored from 1K blocks:
# df's own --block-size rounds up (9.9 GB would read 10).
fs_of()    { df -P "$1" 2>/dev/null | awk 'NR==2{print $6}'; }
fstype_of(){ df -PT "$1" 2>/dev/null | awk 'NR==2{print $2}'; }
free_gb()  { df -P "$1" 2>/dev/null | awk 'NR==2{printf "%d\n", $4 * 1024 / 1000000000}'; }

# detect_image_store (after detect_docker) -> DET_IMAGE_STORE, the folder
# Docker keeps images in, or empty with DET_IMAGE_STORE_WHY saying why.
# Docker 29's default store keeps them in containerd's root: the "root"
# line of its config, else /var/lib/containerd. The classic store keeps
# them in Docker Root Dir. Rootless Docker runs a containerd of its own,
# configured elsewhere: not guessed.
detect_image_store() {
  local R="${ANTEIKU_DETECT_ROOT:-}" root
  DET_IMAGE_STORE=""; DET_IMAGE_STORE_WHY=""
  if [ -z "${DET_DOCKER_VER:-}" ]; then DET_IMAGE_STORE_WHY="Docker is not installed"
  elif [ "${DET_DOCKER_OK:-0}" -ne 1 ]; then DET_IMAGE_STORE_WHY="Docker is not reachable"
  elif [ "${DET_DOCKER_STORE:-}" = containerd ]; then
    if [ "${DET_DOCKER_ROOTLESS:-0}" -eq 1 ]; then DET_IMAGE_STORE_WHY="rootless Docker's image store is not read"
    else
      # A top-level key: TOML puts those before the first [section].
      root="$(sed -n '/^[[:space:]]*\[/q; s/^[[:space:]]*root[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$R/etc/containerd/config.toml" 2>/dev/null | head -n 1)"
      DET_IMAGE_STORE="${root:-/var/lib/containerd}"
    fi
  elif [ "${DET_DOCKER_STORE:-}" = classic ] && [ -n "${DET_DOCKER_ROOT:-}" ]; then DET_IMAGE_STORE="$DET_DOCKER_ROOT"
  else DET_IMAGE_STORE_WHY="docker info does not say"
  fi
}
