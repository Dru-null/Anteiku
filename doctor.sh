#!/usr/bin/env bash
# ============================================================
#  doctor.sh — what you have, what will work, what will bite you.
#  READ-ONLY. Writes nothing, changes nothing, starts nothing.
#  Safe to run before you have decided anything, and safe to paste
#  into a bug report (it prints no secrets).
# ============================================================
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/detect.sh
. lib/detect.sh
# shellcheck source=lib/release.sh
. lib/release.sh

banner "anteiku $S_DOT doctor" "read-only: what you have, what works, what will bite"

detect_os; detect_cpu; detect_mem; detect_gpu; detect_docker; detect_image_store; detect_tailscale

# ---------------------------------------------------------------- system
h1 "System"
kv "Distro"    "$DET_DISTRO $DET_DISTRO_VER"
kv "Kernel"    "$DET_KERNEL"
kv "Arch"      "$DET_ARCH"
# nproc: logical CPUs this process may use (threads, vCPUs; after cpusets)
kv "CPU"       "$DET_CPU ($DET_CORES CPU$([ "$DET_CORES" = 1 ] || echo s))"
kv "Memory"    "${DET_MEM_GIB} GiB (swap ${DET_SWAP_GIB} GiB)"
kv "Timezone"  "$DET_TZ"
kv "User"      "uid=$DET_UID gid=$DET_GID"

case "$DET_ARCH" in
  x86_64|amd64) ok "64-bit x86 — every image in this repo has a build for it." ;;
  aarch64|arm64)
    warn "ARM64 (Raspberry Pi 5, Apple silicon VM, ARM server)."
    note "Most images here are multi-arch, but a few are x86-only."
    note "Hardware transcoding on a Pi is limited. Expect direct-play only." ;;
  armv7l|armhf)
    err "32-bit ARM. Several images no longer publish a build for this."
    note "A Pi 4 or newer running a 64-bit OS is the realistic minimum." ;;
  *) warn "Unrecognised architecture '$DET_ARCH'. You are off the tested path." ;;
esac

# The README's "4 GiB works, 8 is comfortable" means RAM installed; the
# kernel reports a little less (3.7 GiB for 4 GB is typical), so the
# thresholds are 7/8 of each: 3584 and 7168 MiB (T-042).
if [ "$DET_MEM_MIB" -lt 3584 ]; then
  err "Under 4 GiB RAM. The full arr stack will thrash or get OOM-killed."
  note "Pick fewer services, or add memory."
elif [ "$DET_MEM_MIB" -lt 7168 ]; then
  warn "${DET_MEM_GIB} GiB RAM is workable but tight for the whole stack."
  note "Fine for a handful of services. Watch swap."
else
  ok "${DET_MEM_GIB} GiB RAM is comfortable for this stack."
fi

if [ "$DET_TZ" = "Etc/UTC" ] || [ -z "$DET_TZ" ]; then
  warn "Timezone looks unset (Etc/UTC). Schedules and logs will be in UTC."
  note "Set one: sudo timedatectl set-timezone Europe/Dublin"
fi

# ----------------------------------------------------------------- tools
# Bash, coreutils and Docker are the requirements. These are optional:
# one line per missing one, with what doesn't work without it.
h1 "Tools"
MISSING=()
if ! have ss; then
  if have netstat; then
    info "ss not found: ports are checked with netstat instead; their owner is only named for a container."
  else
    # The warning itself is under "Port availability": counted once.
    info "ss not found, netstat neither: ports can't be checked, so setup.sh can't move a taken one."
  fi
  MISSING+=(ss)
fi
have lspci || { info "lspci not found: GPUs are shown by PCI id, without model names."; MISSING+=(lspci); }
have curl  || { warn "curl not found: update.sh and the update check can't reach GitHub; ntfy messages aren't sent."; MISSING+=(curl); }
have git   || { warn "git not found: update.sh can't move this folder to a new release."; MISSING+=(git); }
have timedatectl || {
  if [ "$DET_TZ_FROM" = default ]; then
    info "timedatectl not found, and no /etc/timezone or /etc/localtime: the timezone is UTC."
  else
    info "timedatectl not found: the timezone came from $DET_TZ_FROM."
  fi; MISSING+=(timedatectl); }
if [ "${#MISSING[@]}" -eq 0 ]; then
  ok "ss, lspci, curl, git and timedatectl are installed."
else
  note "$(install_hint "${MISSING[@]}")"
fi
if ! have crontab; then
  warn "crontab not found: update.sh --schedule can't add the weekly check."
  note "$(cron_hint)"
fi

# ---------------------------------------------------------------- docker
h1 "Docker"
if [ -z "$DET_DOCKER_VER" ]; then
  err "$MSG_DOCKER_ABSENT"
  note "$MSG_DOCKER_INSTALL"
else
  kv "Engine" "$DET_DOCKER_VER"
  if [ -n "$DET_COMPOSE_VER" ]; then
    kv "Compose" "$DET_COMPOSE_VER (plugin)"
    ok "$MSG_COMPOSE_OK"
  else
    err "$MSG_COMPOSE_MISSING"
    note "$MSG_COMPOSE_OLD"
    note "$MSG_COMPOSE_INSTALL"
  fi
  if [ "$DET_DOCKER_OK" -eq 1 ]; then
    ok "Docker daemon is reachable."
  else
    err "$MSG_DOCKER_DOWN"
    docker_fix_notes
  fi
  [ "$DET_DOCKER_ROOTLESS" -eq 1 ] && {
    warn "Rootless Docker detected — this path is NOT maintainer-tested."
    note "From Docker's docs: ports below 1024 will not bind, and device"
    note "passthrough for GPU transcoding needs extra setup."; }
fi

# ------------------------------------------------------------------- gpu
h1 "Graphics and transcoding"
if [ -n "$DET_GPUS" ]; then
  while IFS= read -r g; do [ -n "$g" ] && kv "GPU" "$(echo "$g" | cut -c1-70)"; done <<< "$DET_GPUS"
else
  kv "GPU" "none detected"
fi
if [ -n "$DET_GPUS" ] && ! have lspci; then
  note "lspci is not installed (package pciutils), so no model names;"
  note "the vendor:device ids above identify the card."
fi

if [ -n "$DET_RENDER_NODES" ]; then
  echo
  while IFS='|' read -r node path drv; do
    [ -z "$node" ] && continue
    kv "Render node" "$node  (driver: $drv)"
    note "stable id: $path"
  done <<< "$DET_RENDER_NODES"
fi

RENDER_COUNT="$(echo "$DET_RENDER_NODES" | grep -c '|' || true)"
if [ "${RENDER_COUNT:-0}" -gt 1 ]; then
  echo
  warn "More than one render node. Do NOT pass /dev/dri/renderD128 directly."
  note "renderD128 and renderD129 can SWAP which card they point at across"
  note "reboots. Transcoding then dies with a cryptic ffmpeg error until you"
  note "notice. Pass the /dev/dri/by-path/...-render symlink instead — it is"
  note "tied to the PCI slot and does not move. setup.sh does this for you."
fi

echo
printf '  %sWhich one should Jellyfin use?%s\n' "$C_INF" "$C_RST"
case "$DET_GPU_VENDORS" in
  *intel*nvidia*|*nvidia*intel*)
    note "You have both an Intel iGPU and an NVIDIA card."
    note "Counterintuitive but usually right: use the INTEL iGPU. Quick Sync"
    note "is purpose-built for this, costs a few watts, and needs no extra"
    note "driver plumbing. Save the NVIDIA card for games." ;;
  *nvidia*)
    warn "NVIDIA NVENC — this path is NOT maintainer-tested."
    note "NVIDIA only. Good encoder (NVENC), but it needs the"
    note "proprietary driver and nvidia-container-toolkit."
    NV_MISSING="$(nvidia_missing)"
    if [ -z "$NV_MISSING" ]; then
      ok "Both found: driver loaded, and Docker lists the nvidia runtime."
      note "Consumer cards also cap concurrent encode sessions."
    else
      warn "Not usable yet, so setup.sh picks CPU transcoding. Missing:"
      while IFS= read -r m; do note "  - $m"; done <<< "$NV_MISSING"
    fi ;;
  *intel*)
    note "Intel Quick Sync — the sweet spot for this job. Low power, good"
    note "quality, minimal setup. Just pass the render node." ;;
  *amd*)
    warn "AMD VAAPI — this path is NOT maintainer-tested."
    note "From the docs: VAAPI through amdgpu, the same interface as Intel."
    note "Expect more setup than Intel, and lower quality at a given bitrate." ;;
  *)
    if [ -n "$DET_GPU_OTHER" ]; then
      note "Only $DET_GPU_OTHER: no video encoder."
      note "CPU transcoding only."
    else
      note "No GPU detected — CPU transcoding only."
    fi ;;
esac
note ""
note "And the honest answer most guides skip: you may not need any of it."
note "If your TV or app can play the file as-is (direct play), nothing"
note "transcodes and the GPU sits idle. Hardware encoding matters when you"
note "stream to several devices at once, or remotely over limited upload."

# ----------------------------------------------------------------- ports
h1 "Port availability"
PORTS="9696:Prowlarr 8181:qBittorrent 8989:Sonarr 7878:Radarr 8686:Lidarr 5299:LazyLibrarian 6767:Bazarr 5055:Seerr"
CLASH=0; OWN=0
# An install's own containers hold its own ports: no clash (T-074). Its
# compose project as compose reads it: the shell first, then .env, then
# setup.sh's default. No .env, no install: nothing here is "own".
OWN_PROJECT=""
if [ -r .env ]; then
  OWN_PROJECT="${COMPOSE_PROJECT_NAME:-$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' .env | tail -n 1)}"
  OWN_PROJECT="${OWN_PROJECT:-anteiku}"
fi
if ! ports_checkable; then
  warn "Can't check the ports: neither ss nor netstat is installed."
  note "setup.sh will keep the default ports without knowing whether"
  note "they are free. $(install_hint ss)"
else
  for entry in $PORTS; do
    p="${entry%%:*}"; name="${entry##*:}"
    if port_in_use "$p"; then
      if svc="$(port_held_by_project "$p" "$OWN_PROJECT")"; then
        info "$p ($name) is in use by Anteiku's $svc."
        OWN=$((OWN+1))
      else
        warn "$p ($name) is already in use by: $(who_has_port "$p")"
        CLASH=$((CLASH+1))
      fi
    fi
  done
  if [ "$CLASH" -eq 0 ] && [ "$OWN" -gt 0 ]; then
    ok "No clashes: the default ports in use are this install's own."
  elif [ "$CLASH" -eq 0 ]; then
    ok "All default ports for the arr stack are free."
  fi
  [ "$CLASH" -gt 0 ] && note "setup.sh can shift these. Nothing is forced to a fixed port."
fi

if port_in_use 53; then   # 2 (can't tell) is not "taken": the warning above covers it
  echo
  if svc="$(port_held_by_project 53 "$OWN_PROJECT")"; then
    info "Port 53 is in use by Anteiku's $svc."
  else
    warn "Port 53 is taken by: $(who_has_port 53)"
    note "This is THE classic Pi-hole faceplant. On most Ubuntu/Debian boxes it"
    note "is systemd-resolved holding 53 for local DNS. Pi-hole cannot start"
    note "until you free it. Not a problem at all unless you want Pi-hole."
  fi
fi

# ------------------------------------------------------------------ disk
h1 "Storage"
HERE_FS="$(fs_of .)"; HERE_FREE="$(free_gb .)"; HERE_TYPE="$(fstype_of .)"
kv "This directory" "$HERE_FS  ($HERE_TYPE, ${HERE_FREE} GB free)"
# Images don't go where Anteiku was cloned: Docker keeps them in its own
# folder (detect_image_store, T-069). The sizes are judged there.
IMG_FS=""
[ -n "$DET_IMAGE_STORE" ] && IMG_FS="$(fs_of "$DET_IMAGE_STORE")"
if [ -n "$IMG_FS" ]; then
  IMG_FREE="$(free_gb "$DET_IMAGE_STORE")"
  kv "Images" "$IMG_FS  ($(fstype_of "$DET_IMAGE_STORE"), ${IMG_FREE} GB free; $DET_IMAGE_STORE)"
  [ "$IMG_FS" != "$HERE_FS" ] && note "Docker keeps images in $DET_IMAGE_STORE, not in this folder."
else
  IMG_FREE="$HERE_FREE"
  kv "Images" "unknown: ${DET_IMAGE_STORE_WHY:-$DET_IMAGE_STORE is not on this machine}"
  note "Judged on this folder instead. Docker keeps images in its own folder,"
  note "usually /var/lib/containerd or /var/lib/docker, often on another disk."
fi
# Image sizes as a default Docker 29 install stores them (T-068): the
# starter set about 4 GB, every service about 17 GB. update.sh pulls the
# new images while the old ones are still there.
if [ "${IMG_FREE:-0}" -lt 10 ]; then
  err "Under 10 GB free. The starter set's images take about 4 GB, and an update needs room for new ones."
elif [ "${IMG_FREE:-0}" -lt 25 ]; then
  warn "${IMG_FREE} GB free — enough for the starter set, not for every service: all the images take about 17 GB."
elif [ "${IMG_FREE:-0}" -lt 50 ]; then
  warn "${IMG_FREE} GB free — enough for images and configs, not a library."
else
  ok "${IMG_FREE} GB free for images."
fi
note ""
note "The rule that saves people the most pain: your DOWNLOADS and your"
note "LIBRARY must sit on the SAME filesystem, under one root. Then an"
note "import is an instant hardlink costing no extra space. Split them"
note "across two mounts and every import becomes a full copy — twice the"
note "disk, slow imports, and a disk that fills without explanation."

# --------------------------------------------------------- remote access
h1 "Remote access"
if [ "$DET_TS_INSTALLED" -eq 0 ]; then
  ok "Nothing to fix — this is only relevant when you want access from outside."
  note "When you do, read docs/remote-access.md BEFORE forwarding any port"
  note "on your router. Forwarding publishes a service to the whole"
  note "internet; a mesh VPN gets you in with nothing exposed, and takes"
  note "about ten minutes."
elif [ "$DET_TS_UP" -eq 1 ]; then
  ok "Tailscale is up — ${DET_TS_IP}${DET_TS_NAME:+  (${DET_TS_NAME})}"
  note "To make your .home names work away from home too, add Pi-hole as"
  note "a split-DNS nameserver for that suffix. See docs/remote-access.md."
else
  warn "Tailscale is installed but not connected."
  note "Bring it up with:  sudo tailscale up"
fi

# --------------------------------------------------------------- updates
# Only for an install, and only if you didn't turn checks off. Asks
# GitHub for the newest release; sends nothing (lib/release.sh).
h1 "Updates"
if [ ! -r .env ]; then
  ok "Nothing installed yet. setup.sh asks how you want updates handled."
else
  UPD_MODE="$(sed -n 's/^UPDATE_MODE=//p' .env | tail -n 1)"
  REL_NOW="$(release_current)"
  kv "This install" "${REL_NOW:-unknown}"
  kv "UPDATE_MODE" "${UPD_MODE:-notify (not set)}"
  if [ -n "$REL_NOW" ] && [ "$(head -n 1 update-logs/failed 2>/dev/null)" = "$REL_NOW" ]; then
    warn "The update to $REL_NOW stopped halfway. The way back, in this folder:"
    tail -n +3 update-logs/failed | while IFS= read -r l; do note "  $l"; done
  elif [ "$UPD_MODE" = off ]; then
    ok "Update checks are off. ./update.sh --check asks by hand."
  elif ! have curl; then
    note "Could not ask GitHub for the newest release: curl is not installed."
  elif ! release_latest; then
    note "Could not ask GitHub for the newest release (offline?)."
  elif [ -n "$REL_NOW" ] && ! version_gt "$REL_TAG" "$REL_NOW"; then
    ok "Up to date: $REL_NOW is the newest tested release."
  else
    warn "Anteiku $REL_TAG is available. See: ./update.sh --check"
  fi
  if [ "$UPD_MODE" != off ] && ! have crontab; then
    note "No weekly check scheduled, and none can be: crontab is not installed."
  elif [ "$UPD_MODE" != off ] && ! crontab -l 2>/dev/null \
       | awk -v t="# anteiku-update $PWD" 'substr($0, length($0) - length(t) + 1) == t {f=1} END {exit !f}'; then
    note "No weekly check scheduled. To add one:  ./update.sh --schedule"
  fi
fi

# --------------------------------------------------------------- summary
h1 "Summary"
if [ "$FINDINGS_ERR" -gt 0 ]; then
  printf '  %s%s blocker(s)%s and %s warning(s). Fix the blockers first.\n' "$C_ERR" "$FINDINGS_ERR" "$C_RST" "$FINDINGS_WARN"
elif [ "$FINDINGS_WARN" -gt 0 ]; then
  printf '  %sNo blockers%s, %s thing(s) to be aware of above.\n' "$C_OK" "$C_RST" "$FINDINGS_WARN"
  printf '  You are good to run: %s./setup.sh%s\n' "$C_B" "$C_RST"
else
  printf '  %sAll clear.%s Run: %s./setup.sh%s\n' "$C_OK" "$C_RST" "$C_B" "$C_RST"
fi
echo
exit 0
