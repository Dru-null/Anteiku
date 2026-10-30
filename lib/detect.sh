#!/usr/bin/env bash
# ============================================================
#  detect.sh — shared hardware/software detection.
#  Sourced by doctor.sh and setup.sh. Reads only; writes nothing.
# ============================================================
# Library: the C_*, S_* and DET_* variables are read by the scripts that
# source this file, so shellcheck cannot see them used here.
# shellcheck disable=SC2034

# --- output helpers ---------------------------------------------------
# Colour only on a real terminal, and never when NO_COLOR is set
# (https://no-color.org). Unicode symbols only when the locale says UTF-8;
# otherwise plain ASCII of the same width, so alignment never breaks.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
  C_INF=$'\033[36m'; C_ACC=$'\033[35m'; C_GREY=$'\033[90m'
else
  C_RST=''; C_B=''; C_DIM=''; C_OK=''; C_WARN=''; C_ERR=''
  C_INF=''; C_ACC=''; C_GREY=''
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
  printf '%s%s%s%s%s\n' "$C_INF" "$S_TL" "$(_rule $w)" "$S_TR" "$C_RST"
  printf '%s%s%s  %s%s%s%s%s%s\n' "$C_INF" "$S_V" "$C_RST" "$C_B" "$(_pad "$1" $((w-2)))" "$C_RST" "$C_INF" "$S_V" "$C_RST"
  [ -n "${2:-}" ] && printf '%s%s%s  %s%s%s%s%s%s\n' "$C_INF" "$S_V" "$C_RST" "$C_GREY" "$(_pad "$2" $((w-2)))" "$C_RST" "$C_INF" "$S_V" "$C_RST"
  printf '%s%s%s%s%s\n' "$C_INF" "$S_BL" "$(_rule $w)" "$S_BR" "$C_RST"
}

# Section header:  ── Title ─────────────
h1() {
  local t="$1" n=$(( 56 - ${#1} )); [ "$n" -lt 3 ] && n=3
  printf '\n%s%s%s %s%s%s %s%s%s\n' "$C_INF" "$(_rule 2)" "$C_RST" "$C_B$C_INF" "$t" "$C_RST" "$C_DIM" "$(_rule $n)" "$C_RST"
}
kv()   { printf '  %s%-20s%s %s\n' "$C_GREY" "$1" "$C_RST" "$2"; }
ok()   { printf '  %s%s%s  %s\n' "$C_OK"   "$S_OK"   "$C_RST" "$1"; }
info() { printf '  %s%s%s  %s\n' "$C_INF"  "$S_INFO" "$C_RST" "$1"; }
warn() { printf '  %s%s%s  %s%s%s\n' "$C_WARN" "$S_WARN" "$C_RST" "$C_WARN" "$1" "$C_RST"; FINDINGS_WARN=$((FINDINGS_WARN+1)); }
err()  { printf '  %s%s%s  %s%s%s%s\n' "$C_ERR" "$S_ERR" "$C_RST" "$C_B" "$C_ERR" "$1" "$C_RST"; FINDINGS_ERR=$((FINDINGS_ERR+1)); }
note() { printf '     %s%s%s\n' "$C_DIM" "$1" "$C_RST"; }

have() { command -v "$1" >/dev/null 2>&1; }

# Resolve to an absolute path. Relative paths are ambiguous the moment
# compose includes a file from a subdirectory, and the failure is silent:
# the stack comes up fine with your data somewhere you did not intend.
abspath() {
  local p="$1"
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    *)  printf '%s\n' "$(cd "$(dirname "$p")" 2>/dev/null && pwd)/$(basename "$p")" ;;
  esac
}

# --- system -----------------------------------------------------------
detect_os() {
  DET_DISTRO="unknown"; DET_DISTRO_VER=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DET_DISTRO="${NAME:-unknown}"; DET_DISTRO_VER="${VERSION_ID:-}"
  fi
  DET_KERNEL="$(uname -r)"
  DET_ARCH="$(uname -m)"
  DET_TZ="$( (timedatectl show -p Timezone --value 2>/dev/null) || cat /etc/timezone 2>/dev/null || echo 'Etc/UTC')"
  DET_UID="$(id -u)"; DET_GID="$(id -g)"
}

detect_cpu() {
  DET_CPU="$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  [ -z "$DET_CPU" ] && DET_CPU="$(awk -F': ' '/^Model/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  [ -z "$DET_CPU" ] && DET_CPU="unknown"
  DET_CORES="$(nproc 2>/dev/null || echo '?')"
  DET_CPU_VENDOR="other"
  case "$DET_CPU" in
    *Intel*) DET_CPU_VENDOR="intel" ;;
    *AMD*)   DET_CPU_VENDOR="amd" ;;
  esac
}

detect_mem() {
  local kb
  kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  DET_MEM_GB=$(( kb / 1024 / 1024 ))
  kb="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  DET_SWAP_GB=$(( kb / 1024 / 1024 ))
}

# --- GPU --------------------------------------------------------------
# Sets DET_GPUS (human list), DET_GPU_VENDORS (space-separated: intel amd nvidia),
# and DET_RENDER_NODES ("node|pcipath|driver" per line).
detect_gpu() {
  DET_GPUS=""; DET_GPU_VENDORS=""; DET_RENDER_NODES=""

  if have lspci; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      DET_GPUS="${DET_GPUS}${line}"$'\n'
      case "$line" in
        *Intel*)            DET_GPU_VENDORS="$DET_GPU_VENDORS intel" ;;
        *NVIDIA*|*nVidia*)  DET_GPU_VENDORS="$DET_GPU_VENDORS nvidia" ;;
        *AMD*|*ATI*|*Radeon*) DET_GPU_VENDORS="$DET_GPU_VENDORS amd" ;;
      esac
    done <<< "$(lspci 2>/dev/null | grep -iE 'vga|3d controller|display controller' || true)"
  fi

  # Render nodes, with the STABLE by-path id. Bare /dev/dri/renderD128 is
  # NOT stable across reboots on a machine with two GPUs — the numbers can
  # swap, and a container pinned to the wrong one fails to transcode.
  if [ -d /dev/dri ]; then
    local n base drv path
    for n in /dev/dri/renderD*; do
      [ -e "$n" ] || continue
      base="$(basename "$n")"
      drv="$(basename "$(readlink -f "/sys/class/drm/$base/device/driver" 2>/dev/null)" 2>/dev/null)"
      [ -z "$drv" ] && drv="unknown"
      path=""
      if [ -d /dev/dri/by-path ]; then
        local p
        for p in /dev/dri/by-path/*-render; do
          [ -e "$p" ] || continue
          if [ "$(readlink -f "$p")" = "$(readlink -f "$n")" ]; then path="$p"; break; fi
        done
      fi
      [ -z "$path" ] && path="(no by-path entry)"
      DET_RENDER_NODES="${DET_RENDER_NODES}${n}|${path}|${drv}"$'\n'
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
  DET_RENDER_GID=""; DET_INTEL_RENDER=""; DET_AMD_RENDER=""; DET_NVIDIA_RENDER=""

  local grp
  for grp in render video; do
    DET_RENDER_GID="$(getent group "$grp" 2>/dev/null | cut -d: -f3)"
    [ -n "$DET_RENDER_GID" ] && { DET_RENDER_GROUP="$grp"; break; }
  done
  # Fall back to whatever group actually owns the device.
  if [ -z "$DET_RENDER_GID" ] && [ -e /dev/dri/renderD128 ]; then
    DET_RENDER_GROUP="$(stat -c %G /dev/dri/renderD128 2>/dev/null)"
    DET_RENDER_GID="$(stat -c %g /dev/dri/renderD128 2>/dev/null)"
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

# Which GPU profile should Jellyfin use? Echoes: intel|nvidia|amd|cpu
# Intel wins over a discrete NVIDIA card on purpose - see doctor.sh.
pick_gpu_profile() {
  if [ -n "${DET_INTEL_RENDER:-}" ]; then echo intel; return; fi
  case "$DET_GPU_VENDORS" in
    *nvidia*) echo nvidia; return ;;
  esac
  if [ -n "${DET_AMD_RENDER:-}" ]; then echo amd; return; fi
  echo cpu
}

# --- docker -----------------------------------------------------------
detect_docker() {
  DET_DOCKER_VER=""; DET_COMPOSE_VER=""; DET_DOCKER_OK=0
  DET_DOCKER_ROOTLESS=0; DET_IN_DOCKER_GROUP=0
  if have docker; then
    DET_DOCKER_VER="$(docker --version 2>/dev/null | sed 's/^Docker version //; s/,.*//')"
    if docker info >/dev/null 2>&1; then
      DET_DOCKER_OK=1
      docker info 2>/dev/null | grep -qi 'rootless' && DET_DOCKER_ROOTLESS=1
    fi
    DET_COMPOSE_VER="$(docker compose version --short 2>/dev/null || true)"
  fi
  id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker && DET_IN_DOCKER_GROUP=1
}

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
# port_in_use <port> -> 0 if something is listening
port_in_use() {
  local p="$1"
  if have ss; then
    ss -lntuH 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${p}\$" && return 0
  elif have netstat; then
    netstat -lntu 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$" && return 0
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
  [ -z "$out" ] && out="unidentified (try: sudo ss -lntup | grep :${p})"
  echo "$out"
}

# --- disk -------------------------------------------------------------
# fs_of <path> -> filesystem mountpoint; free_gb <path> -> integer GB
fs_of()    { df -P "$1" 2>/dev/null | awk 'NR==2{print $6}'; }
fstype_of(){ df -PT "$1" 2>/dev/null | awk 'NR==2{print $2}'; }
free_gb()  { df -P --block-size=1G "$1" 2>/dev/null | awk 'NR==2{print $4}'; }
