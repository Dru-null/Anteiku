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

banner "anteiku $S_DOT doctor" "read-only: what you have, what works, what will bite"

detect_os; detect_cpu; detect_mem; detect_gpu; detect_docker; detect_tailscale

# ---------------------------------------------------------------- system
h1 "System"
kv "Distro"    "$DET_DISTRO $DET_DISTRO_VER"
kv "Kernel"    "$DET_KERNEL"
kv "Arch"      "$DET_ARCH"
kv "CPU"       "$DET_CPU ($DET_CORES cores)"
kv "Memory"    "${DET_MEM_GB} GiB (swap ${DET_SWAP_GB} GiB)"
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

if [ "$DET_MEM_GB" -lt 4 ]; then
  err "Under 4 GiB RAM. The full arr stack will thrash or get OOM-killed."
  note "Pick fewer services, or add memory."
elif [ "$DET_MEM_GB" -lt 8 ]; then
  warn "${DET_MEM_GB} GiB RAM is workable but tight for the whole stack."
  note "Fine for a handful of services. Watch swap."
else
  ok "${DET_MEM_GB} GiB RAM is comfortable for this stack."
fi

if [ "$DET_TZ" = "Etc/UTC" ] || [ -z "$DET_TZ" ]; then
  warn "Timezone looks unset (Etc/UTC). Schedules and logs will be in UTC."
  note "Set one: sudo timedatectl set-timezone Europe/Dublin"
fi

# ---------------------------------------------------------------- docker
h1 "Docker"
if [ -z "$DET_DOCKER_VER" ]; then
  err "Docker is not installed. Nothing here can run without it."
  note "Install: https://docs.docker.com/engine/install/"
else
  kv "Engine" "$DET_DOCKER_VER"
  if [ -n "$DET_COMPOSE_VER" ]; then
    kv "Compose" "$DET_COMPOSE_VER (v2 plugin)"
    ok "Compose v2 present — 'docker compose', the syntax this repo uses."
  else
    err "Compose v2 plugin missing. The old 'docker-compose' script will not work here."
    note "Install the plugin: https://docs.docker.com/compose/install/"
  fi
  if [ "$DET_DOCKER_OK" -eq 1 ]; then
    ok "Docker daemon is reachable."
  else
    err "Docker is installed but the daemon is not reachable as this user."
    if [ "$DET_IN_DOCKER_GROUP" -eq 0 ]; then
      note "You are not in the 'docker' group. Fix, then log out and back in:"
      note "  sudo usermod -aG docker \$USER"
    else
      note "Is it running?  sudo systemctl status docker"
    fi
  fi
  [ "$DET_DOCKER_ROOTLESS" -eq 1 ] && {
    warn "Rootless Docker detected."
    note "Ports below 1024 will not bind, and device passthrough for GPU"
    note "transcoding needs extra setup. Everything else works."; }
fi

# ------------------------------------------------------------------- gpu
h1 "Graphics and transcoding"
if [ -n "$DET_GPUS" ]; then
  while IFS= read -r g; do [ -n "$g" ] && kv "GPU" "$(echo "$g" | cut -c1-70)"; done <<< "$DET_GPUS"
else
  kv "GPU" "none detected (or lspci not installed)"
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
    note "NVIDIA only. Good encoder (NVENC), but it needs the"
    note "nvidia-container-toolkit installed before Docker can see it."
    note "Consumer cards also cap concurrent encode sessions." ;;
  *intel*)
    note "Intel Quick Sync — the sweet spot for this job. Low power, good"
    note "quality, minimal setup. Just pass the render node." ;;
  *amd*)
    note "AMD VAAPI. Works, but it is the fiddliest of the three and"
    note "quality at a given bitrate trails Intel and NVIDIA." ;;
  *)
    note "No GPU detected — CPU transcoding only." ;;
esac
note ""
note "And the honest answer most guides skip: you may not need any of it."
note "If your TV or app can play the file as-is (direct play), nothing"
note "transcodes and the GPU sits idle. Hardware encoding matters when you"
note "stream to several devices at once, or remotely over limited upload."

# ----------------------------------------------------------------- ports
h1 "Port availability"
PORTS="9696:Prowlarr 8181:qBittorrent 8989:Sonarr 7878:Radarr 8686:Lidarr 5299:LazyLibrarian 6767:Bazarr 5055:Seerr"
CLASH=0
for entry in $PORTS; do
  p="${entry%%:*}"; name="${entry##*:}"
  if port_in_use "$p"; then
    warn "$p ($name) is already in use by: $(who_has_port "$p")"
    CLASH=$((CLASH+1))
  fi
done
[ "$CLASH" -eq 0 ] && ok "All default ports for the arr stack are free."
[ "$CLASH" -gt 0 ] && note "setup.sh can shift these. Nothing is forced to a fixed port."

if port_in_use 53; then
  echo
  warn "Port 53 is taken by: $(who_has_port 53)"
  note "This is THE classic Pi-hole faceplant. On most Ubuntu/Debian boxes it"
  note "is systemd-resolved holding 53 for local DNS. Pi-hole cannot start"
  note "until you free it. Not a problem at all unless you want Pi-hole."
fi

# ------------------------------------------------------------------ disk
h1 "Storage"
ROOT_FS="$(fs_of .)"; ROOT_FREE="$(free_gb .)"; ROOT_TYPE="$(fstype_of .)"
kv "This directory" "$ROOT_FS  ($ROOT_TYPE, ${ROOT_FREE} GB free)"
if [ "${ROOT_FREE:-0}" -lt 10 ]; then
  err "Under 10 GB free. Container images alone will not fit."
elif [ "${ROOT_FREE:-0}" -lt 50 ]; then
  warn "${ROOT_FREE} GB free — enough for images and configs, not a library."
else
  ok "${ROOT_FREE} GB free here."
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
