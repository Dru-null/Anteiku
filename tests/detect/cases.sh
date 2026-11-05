# shellcheck shell=bash
# ============================================================
#  tests/detect/cases.sh — the machines, for tests/detect/run.sh.
#
#  One function per case, named case_<group>_<what>. Fixture lines
#  first (they change the default machine in run.sh), then checks:
#
#    is DET_MEM_GB 3            what lib/detect.sh set (also: pick,
#                               port.<n>, fs_of, fstype_of, free_gb)
#    env_is COMPOSE_FILE ...    the .env that setup.sh --dry-run shows
#    env_absent AMD_RENDER_PATH
#    doctor warn "..."          a whole doctor.sh line (ok|warn|err|note|kv)
#    setup ok "..."             the same for setup.sh
#    doctor_lacks "..."         text that must not appear
#    current T-042 "why"        the checks after it, to the end of the
#                               case, record today's output of a known
#                               problem; T-042 will change them
#
#  "written" fixtures are typed from upstream formats (lspci, os-release,
#  /proc); "captured" ones were read from a real machine, hardware lines
#  only (no names, addresses or timezone), and from "..." says which.
#  Only what Anteiku reads is checked: no CPU flags, no VRAM, and nothing
#  about DET_CPU_VENDOR, DET_NVIDIA_RENDER or DET_RENDER_GROUP (unused).
# ============================================================

# Lines the GPU cases share.
L_INTEL_UHD630='00:02.0 VGA compatible controller: Intel Corporation CoffeeLake-H GT2 [UHD Graphics 630]'
L_INTEL_ARC='00:02.0 VGA compatible controller: Intel Corporation Lunar Lake [Intel Arc Graphics 130V / 140V] (rev 04)'
L_AMD_6700XT='03:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Navi 22 [Radeon RX 6700/6700 XT/6750 XT / 6800M/6850M XT] (rev c1)'
L_NV_3060='01:00.0 VGA compatible controller: NVIDIA Corporation GA104 [GeForce RTX 3060 Ti] (rev a1)'
L_NV_1050M='01:00.0 3D controller: NVIDIA Corporation GP107M [GeForce GTX 1050 Mobile] (rev a1)'
P_INTEL='0000:00:02.0'; P_AMD='0000:03:00.0'; P_NV='0000:01:00.0'
BP=/dev/dri/by-path

# ------------------------------------------------------------ baseline
case_baseline() {   # the default machine, unchanged
  is DET_DISTRO Ubuntu; is DET_DISTRO_VER 24.04; is DET_KERNEL 6.8.0-87-generic; is DET_ARCH x86_64
  is DET_CPU "Intel(R) Core(TM) i5-8500T CPU @ 2.10GHz"; is DET_CORES 6
  is DET_MEM_GB 15; is DET_TZ America/Toronto
  is DET_UID "$RUN_UID"; is DET_GID "$RUN_GID"
  is pick cpu
  doctor kv Distro "Ubuntu 24.04"
  doctor kv CPU "Intel(R) Core(TM) i5-8500T CPU @ 2.10GHz (6 cores)"
  doctor kv Timezone America/Toronto
  doctor kv User "uid=$RUN_UID gid=$RUN_GID"
  doctor ok "64-bit x86 — every image in this repo has a build for it."
  doctor ok "Docker daemon is reachable."
  doctor ok "All default ports for the arr stack are free."
  doctor kv GPU "none detected (or lspci not installed)"
  doctor note "No GPU detected — CPU transcoding only."
  doctor_lacks "Timezone looks unset"
  env_is PUID "$RUN_UID"; env_is PGID "$RUN_GID"; env_is TZ America/Toronto
  env_is COMPOSE_FILE compose.yaml:hw/cpu-only.yaml
  env_is RENDER_GID 992
  env_absent INTEL_RENDER_PATH; env_absent AMD_RENDER_PATH
  setup ok "No usable GPU found — CPU transcoding."
}

# ------------------------------------------------------------ GPU
case_gpu_intel_i915() {
  gpu "$L_INTEL_UHD630"; render renderD128 i915 "$P_INTEL"
  is DET_GPU_VENDORS intel; is DET_INTEL_RENDER "$BP/pci-$P_INTEL-render"; is pick intel
  doctor kv "Render node" "/dev/dri/renderD128  (driver: i915)"
  doctor note "stable id: $BP/pci-$P_INTEL-render"
  doctor note "Intel Quick Sync — the sweet spot for this job. Low power, good"
  doctor_lacks "More than one render node"
  env_is COMPOSE_FILE compose.yaml:hw/gpu-intel.yaml
  env_is RENDER_GID 992; env_is INTEL_RENDER_PATH "$BP/pci-$P_INTEL-render"; env_absent AMD_RENDER_PATH
  setup ok "Intel Quick Sync (tested path)."
}

case_gpu_intel_xe() {   # Lunar Lake and newer bind to xe, not i915
  gpu "$L_INTEL_ARC"; render renderD128 xe "$P_INTEL"
  is DET_INTEL_RENDER "$BP/pci-$P_INTEL-render"; is pick intel
  doctor kv "Render node" "/dev/dri/renderD128  (driver: xe)"
  env_is COMPOSE_FILE compose.yaml:hw/gpu-intel.yaml
  env_is INTEL_RENDER_PATH "$BP/pci-$P_INTEL-render"
}

case_gpu_amd() {
  gpu "$L_AMD_6700XT"; render renderD128 amdgpu "$P_AMD"
  is DET_GPU_VENDORS amd; is DET_AMD_RENDER "$BP/pci-$P_AMD-render"; is DET_INTEL_RENDER ""; is pick amd
  doctor note "AMD VAAPI. Works, but it is the fiddliest of the three and"
  env_is COMPOSE_FILE compose.yaml:hw/gpu-amd.yaml
  env_is AMD_RENDER_PATH "$BP/pci-$P_AMD-render"; env_absent INTEL_RENDER_PATH; env_is RENDER_GID 992
  setup warn "AMD VAAPI — this path is NOT maintainer-tested."
  setup note "device: $BP/pci-$P_AMD-render"
}

case_gpu_nvidia_driver() {   # proprietary driver; the container toolkit is not read at all
  gpu "$L_NV_3060"; render renderD128 nvidia "$P_NV"
  is DET_GPU_VENDORS nvidia; is pick nvidia
  doctor note "NVIDIA only. Good encoder (NVENC), but it needs the"
  env_is COMPOSE_FILE compose.yaml:hw/gpu-nvidia.yaml
  env_absent INTEL_RENDER_PATH; env_absent AMD_RENDER_PATH
  setup warn "NVIDIA NVENC — this path is NOT maintainer-tested."
}

case_gpu_nvidia_nouveau() {   # nouveau has no NVENC
  gpu "$L_NV_3060"; render renderD128 nouveau "$P_NV"
  current T-043 "NVIDIA is chosen from lspci alone; the driver is never checked"
  is pick nvidia
  env_is COMPOSE_FILE compose.yaml:hw/gpu-nvidia.yaml
  setup note "Falls back to CPU transcoding if either is missing."
}

case_gpu_nvidia_no_driver() {   # card present, no driver: no render node at all
  gpu "$L_NV_3060"
  is DET_RENDER_NODES ""
  current T-043 "NVIDIA is chosen from lspci alone; the driver is never checked"
  is pick nvidia
  env_is COMPOSE_FILE compose.yaml:hw/gpu-nvidia.yaml
}

case_gpu_intel_nvidia() {   # laptop: iGPU + discrete card; Intel wins on purpose
  gpu "$L_INTEL_UHD630"; gpu "$L_NV_1050M"
  render renderD128 i915 "$P_INTEL"; render renderD129 nvidia "$P_NV"
  is DET_GPU_VENDORS "intel nvidia"; is pick intel
  doctor warn "More than one render node. Do NOT pass /dev/dri/renderD128 directly."
  doctor note "You have both an Intel iGPU and an NVIDIA card."
  env_is COMPOSE_FILE compose.yaml:hw/gpu-intel.yaml
  env_is INTEL_RENDER_PATH "$BP/pci-$P_INTEL-render"
  setup note "You also have an NVIDIA card. Intel is still the better"
}

case_gpu_nodes_swapped() {   # the numbers swap across reboots; by-path doesn't
  gpu "$L_INTEL_UHD630"; gpu "$L_NV_1050M"
  render renderD128 nouveau "$P_NV"; render renderD129 i915 "$P_INTEL"
  is DET_INTEL_RENDER "$BP/pci-$P_INTEL-render"; is pick intel
  doctor kv "Render node" "/dev/dri/renderD129  (driver: i915)"
  env_is INTEL_RENDER_PATH "$BP/pci-$P_INTEL-render"
  env_is COMPOSE_FILE compose.yaml:hw/gpu-intel.yaml
}

case_gpu_virtio() {   # a KVM guest with virtio-gpu: a render node, no vendor
  gpu "00:01.0 VGA compatible controller: Red Hat, Inc. Virtio 1.0 GPU (rev 01)"
  render renderD128 virtio-pci "0000:00:01.0"
  is DET_GPU_VENDORS ""; is pick cpu
  doctor kv "Render node" "/dev/dri/renderD128  (driver: virtio-pci)"
  doctor note "No GPU detected — CPU transcoding only."
  env_is COMPOSE_FILE compose.yaml:hw/cpu-only.yaml
  env_absent INTEL_RENDER_PATH; env_absent AMD_RENDER_PATH
}

case_gpu_bochs() {   # QEMU's standard VGA: display only, no render node
  gpu "00:02.0 VGA compatible controller: Device 1234:1111 (rev 02)"
  is DET_GPU_VENDORS ""; is DET_RENDER_NODES ""; is pick cpu
  doctor kv GPU "00:02.0 VGA compatible controller: Device 1234:1111 (rev 02)"
  env_is COMPOSE_FILE compose.yaml:hw/cpu-only.yaml
}

case_gpu_aspeed() {   # server BMC graphics
  gpu "03:00.0 VGA compatible controller: ASPEED Technology, Inc. ASPEED Graphics Family (rev 41)"
  is DET_GPU_VENDORS ""; is pick cpu
  doctor note "No GPU detected — CPU transcoding only."
  env_is COMPOSE_FILE compose.yaml:hw/cpu-only.yaml
}

case_gpu_no_lspci() {   # Debian/Arch minimal: no pciutils
  gpu "$L_NV_3060"; render renderD128 nvidia "$P_NV"; no_tool lspci
  is DET_GPUS ""
  doctor kv GPU "none detected (or lspci not installed)"
  doctor kv "Render node" "/dev/dri/renderD128  (driver: nvidia)"
  current T-043 "without lspci an NVIDIA card is never chosen, even with its driver loaded"
  is pick cpu
  env_is COMPOSE_FILE compose.yaml:hw/cpu-only.yaml
}

case_gpu_no_lspci_intel() {   # Intel and AMD come from sysfs, so they survive it
  gpu "$L_INTEL_UHD630"; render renderD128 i915 "$P_INTEL"; no_tool lspci
  is pick intel
  env_is INTEL_RENDER_PATH "$BP/pci-$P_INTEL-render"
}

case_gpu_no_by_path() {   # no stable id: the node is shown, never written to .env
  gpu "$L_INTEL_UHD630"; render renderD128 i915
  is DET_INTEL_RENDER ""; is pick cpu
  doctor note "stable id: (no by-path entry)"
  env_is COMPOSE_FILE compose.yaml:hw/cpu-only.yaml
  env_absent INTEL_RENDER_PATH
}

case_gpu_no_render_group() {   # no render or video group: the node's own group
  gpu "$L_INTEL_UHD630"; render renderD128 i915 "$P_INTEL"; group render; group video
  is DET_RENDER_GID "$(stat -c %g "$R/dev/dri/renderD128")"
  env_is RENDER_GID "$(stat -c %g "$R/dev/dri/renderD128")"
  setup_lacks "Could not determine the render group id."
}

case_gpu_video_group_only() {   # older distros: video owns the nodes
  gpu "$L_INTEL_UHD630"; render renderD128 i915 "$P_INTEL"; group render
  is DET_RENDER_GID 44; env_is RENDER_GID 44
}

case_gpu_no_group_no_node() {   # override to a GPU with nothing to read the gid from
  group render; group video; gpu "$L_NV_3060"
  is DET_RENDER_GID ""
  env_absent RENDER_GID
  setup warn "Could not determine the render group id."
}

# ------------------------------------------------------------ memory
# MemTotal is what the kernel reports: a little under the RAM installed.
case_mem_2gb() {
  mem_kb 2014560 0
  is DET_MEM_GB 1; is DET_SWAP_GB 0
  doctor kv Memory "1 GiB (swap 0 GiB)"
  doctor err "Under 4 GiB RAM. The full arr stack will thrash or get OOM-killed."
}

case_mem_4gb() {
  mem_kb 3884728 0
  current T-042 "a 4 GB machine is floored to 3 GiB and gets the under-4 error"
  is DET_MEM_GB 3
  doctor err "Under 4 GiB RAM. The full arr stack will thrash or get OOM-killed."
}

case_mem_8gb() {
  mem_kb 7975444 2097148
  current T-042 "an 8 GB machine is floored to 7 GiB and called tight; 2 GiB swap reads 1"
  is DET_MEM_GB 7; is DET_SWAP_GB 1
  doctor warn "7 GiB RAM is workable but tight for the whole stack."
}

case_mem_16gb() {
  mem_kb 16247300 0
  is DET_MEM_GB 15
  doctor ok "15 GiB RAM is comfortable for this stack."
  doctor kv Memory "15 GiB (swap 0 GiB)"
}

case_mem_unreadable() {   # no /proc/meminfo (a broken container)
  rm -f "$R/proc/meminfo"
  is DET_MEM_GB 0
  doctor err "Under 4 GiB RAM. The full arr stack will thrash or get OOM-killed."
}

# ------------------------------------------------------------ arch / CPU
case_arch_aarch64_pi5() {   # Raspberry Pi: no "model name", a "Model" line
  arch aarch64; kernel 6.12.47+rpt-rpi-2712; cores 4
  cpuinfo <<'EOF'
processor	: 0
BogoMIPS	: 108.00
Features	: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm lrcpc dcpop asimddp
CPU implementer	: 0x41
CPU part	: 0xd0b

Revision	: d04170
Model		: Raspberry Pi 5 Model B Rev 1.0
EOF
  is DET_ARCH aarch64; is DET_CPU "Raspberry Pi 5 Model B Rev 1.0"
  doctor kv CPU "Raspberry Pi 5 Model B Rev 1.0 (4 cores)"
  doctor warn "ARM64 (Raspberry Pi 5, Apple silicon VM, ARM server)."
  current T-046 "every pinned image publishes linux/arm64 (registry, 2026-11-05)"
  doctor note "Most images here are multi-arch, but a few are x86-only."
}

case_arch_aarch64_vm() {   # an ARM VM or server: no model line at all
  arch aarch64; cores 2
  cpuinfo <<'EOF'
processor	: 0
BogoMIPS	: 50.00
Features	: fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid
CPU implementer	: 0x41
CPU architecture: 8
CPU part	: 0xd08
EOF
  is DET_CPU unknown
  doctor kv CPU "unknown (2 cores)"
}

case_arch_armv7() {
  arch armv7l; cpu_model "ARMv7 Processor rev 3 (v7l)" 4
  doctor err "32-bit ARM. Several images no longer publish a build for this."
}

case_arch_riscv64() {
  arch riscv64
  doctor warn "Unrecognised architecture 'riscv64'. You are off the tested path."
}

case_cpu_amd() {
  cpu_model "AMD Ryzen 5 5600X 6-Core Processor" 12; cores 12
  doctor kv CPU "AMD Ryzen 5 5600X 6-Core Processor (12 cores)"
}

# ------------------------------------------------------------ OS
case_os_ubuntu_2604() {
  os_release <<'EOF'
PRETTY_NAME="Ubuntu 26.04 LTS"
NAME="Ubuntu"
VERSION_ID="26.04"
ID=ubuntu
EOF
  is DET_DISTRO Ubuntu; is DET_DISTRO_VER 26.04; doctor kv Distro "Ubuntu 26.04"
}

case_os_ubuntu_2204() {
  os_release <<'EOF'
PRETTY_NAME="Ubuntu 22.04.5 LTS"
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION="22.04.5 LTS (Jammy Jellyfish)"
ID=ubuntu
EOF
  doctor kv Distro "Ubuntu 22.04"
}

case_os_debian_12() {
  os_release <<'EOF'
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
NAME="Debian GNU/Linux"
VERSION_ID="12"
VERSION="12 (bookworm)"
VERSION_CODENAME=bookworm
ID=debian
EOF
  is DET_DISTRO "Debian GNU/Linux"; doctor kv Distro "Debian GNU/Linux 12"
}

case_os_debian_13() {
  os_release <<'EOF'
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME="Debian GNU/Linux"
VERSION_ID="13"
VERSION="13 (trixie)"
ID=debian
EOF
  doctor kv Distro "Debian GNU/Linux 13"
}

case_os_fedora() {
  os_release <<'EOF'
NAME="Fedora Linux"
VERSION="43 (Server Edition)"
ID=fedora
VERSION_ID=43
PRETTY_NAME="Fedora Linux 43 (Server Edition)"
VARIANT_ID=server
EOF
  doctor kv Distro "Fedora Linux 43"
}

case_os_arch() {   # rolling: no VERSION_ID
  os_release <<'EOF'
NAME="Arch Linux"
PRETTY_NAME="Arch Linux"
ID=arch
BUILD_ID=rolling
EOF
  is DET_DISTRO "Arch Linux"; is DET_DISTRO_VER ""
  doctor kv Distro "Arch Linux "
}

case_os_none() {   # no /etc/os-release
  no_os_release
  is DET_DISTRO unknown; doctor kv Distro "unknown "
}

# ------------------------------------------------------------ timezone, user
case_user_ids() {   # PUID/PGID are whoever runs setup.sh, not 1000
  user_ids 1234 2345
  is DET_UID 1234; is DET_GID 2345
  doctor kv User "uid=1234 gid=2345"
  env_is PUID 1234; env_is PGID 2345
}

case_tz_file() {   # no timedatectl (no systemd): /etc/timezone
  no_tool timedatectl; tz_file Europe/Lisbon
  is DET_TZ Europe/Lisbon; env_is TZ Europe/Lisbon
}

case_tz_ctl_fails() {   # timedatectl installed, systemd not running (a container)
  tz_ctl_fails; tz_file Asia/Tokyo
  is DET_TZ Asia/Tokyo
}

case_tz_none() {   # neither: UTC, and doctor says so
  no_tool timedatectl
  is DET_TZ Etc/UTC; env_is TZ Etc/UTC
  doctor warn "Timezone looks unset (Etc/UTC). Schedules and logs will be in UTC."
}

# ------------------------------------------------------------ Docker
case_docker_absent() {
  docker_is absent
  is DET_DOCKER_VER ""; is DET_DOCKER_OK 0
  doctor err "Docker is not installed. Nothing here can run without it."
}

case_docker_down_not_in_group() {
  docker_is down; user_groups "you adm"
  is DET_DOCKER_OK 0; is DET_IN_DOCKER_GROUP 0
  doctor err "Docker is installed but the daemon is not reachable as this user."
  doctor note "You are not in the 'docker' group. Fix, then log out and back in:"
}

case_docker_down_in_group() {
  docker_is down
  is DET_IN_DOCKER_GROUP 1
  doctor note "Is it running?  sudo systemctl status docker"
}

case_docker_no_compose() {   # distro docker.io without the compose plugin
  docker_is no-compose
  is DET_COMPOSE_VER ""
  doctor err "Compose v2 plugin missing. The old 'docker-compose' script will not work here."
}

case_docker_rootless() {
  docker_is rootless
  is DET_DOCKER_ROOTLESS 1
  doctor warn "Rootless Docker detected."
  doctor kv Engine "29.0.1"; doctor kv Compose "2.40.3 (v2 plugin)"
}

# ------------------------------------------------------------ Tailscale
case_tailscale_up() {
  tailscale_is up 100.64.0.7 media-box.example-tailnet.ts.net
  is DET_TS_UP 1; is DET_TS_NAME media-box.example-tailnet.ts.net
  doctor ok "Tailscale is up — 100.64.0.7  (media-box.example-tailnet.ts.net)"
}

case_tailscale_down() {
  tailscale_is down
  is DET_TS_INSTALLED 1; is DET_TS_UP 0
  doctor warn "Tailscale is installed but not connected."
}

# ------------------------------------------------------------ ports
case_ports_container() {   # held by a container; unprivileged ss can't name docker-proxy
  listen 8989; container media-sonarr 8989
  is port.8989 "used by container 'media-sonarr'"; is port.7878 free
  doctor warn "8989 (Sonarr) is already in use by: container 'media-sonarr'"
  env_is PORT_SONARR 8990
}

case_ports_ours() {   # this project's own Sonarr from a previous run: not a clash
  listen 8989; container fx-sonarr 8989 anteiku-fx sonarr
  is port.8989 "used by container 'fx-sonarr'"
  env_is PORT_SONARR 8989
}

case_ports_dns() {   # systemd-resolved on 53, the Pi-hole trap
  listen 53 systemd-resolve
  is port.53 "used by systemd-resolve"
  doctor warn "Port 53 is taken by: systemd-resolve"
}

case_ports_netstat_only() {   # no ss (net-tools only)
  listen 8989; no_tool ss
  is port.8989 "used by unidentified (try: sudo ss -lntup | grep :8989)"
  env_is PORT_SONARR 8990
}

case_ports_no_tools() {   # neither ss nor netstat
  listen 8989; no_tool ss netstat
  current T-044 "with neither tool every port reads as free"
  is port.8989 free
  doctor ok "All default ports for the arr stack are free."
  env_is PORT_SONARR 8989
}

# ------------------------------------------------------------ disk (df helpers)
case_disk_ok() {
  disk 512 ext4 /srv
  is fs_of /srv; is fstype_of ext4; is free_gb 512
  doctor kv "This directory" "/srv  (ext4, 512 GB free)"
  doctor ok "512 GB free here."
}

case_disk_tight() {
  disk 30 xfs
  doctor warn "30 GB free — enough for images and configs, not a library."
}

case_disk_full() {
  disk 6 btrfs
  doctor err "Under 10 GB free. Container images alone will not fit."
}

# ------------------------------------------------------------ other tools
case_tools_no_nproc() {
  no_tool nproc
  is DET_CORES "?"
}

# ------------------------------------------------------------ captured
# From a real machine (the workspace capture tool), checked against what
# doctor.sh and setup.sh printed on that machine itself, the same day.
case_capture_maintainer_laptop() {
  from 'captured: the maintainer server (laptop, i5-9300H, UHD 630 + GTX 1050 on nouveau), 2026-11-05'
  os_release <<'EOS'
NAME="Ubuntu"
VERSION_ID="26.04"
EOS
  arch 'x86_64'; kernel '7.0.0-34-generic'; cores '8'
  cpu_model 'Intel(R) Core(TM) i5-9300H CPU @ 2.40GHz' 8
  mem_kb 15684192 4194300
  gpu '00:02.0 VGA compatible controller: Intel Corporation CoffeeLake-H GT2 [UHD Graphics 630]'
  gpu '01:00.0 VGA compatible controller: NVIDIA Corporation GP107M [GeForce GTX 1050 3 GB Max-Q] (rev a1)'
  render renderD128 'nouveau' '0000:01:00.0'
  render renderD129 'i915' '0000:00:02.0'
  group render 991
  group video 44
  doctor kv Distro "Ubuntu 26.04"
  doctor kv Kernel "7.0.0-34-generic"
  doctor kv CPU "Intel(R) Core(TM) i5-9300H CPU @ 2.40GHz (8 cores)"
  doctor kv GPU "00:02.0 VGA compatible controller: Intel Corporation CoffeeLake-H GT2 "
  doctor kv "Render node" "/dev/dri/renderD128  (driver: nouveau)"
  doctor note "stable id: /dev/dri/by-path/pci-0000:00:02.0-render"
  doctor warn "More than one render node. Do NOT pass /dev/dri/renderD128 directly."
  is pick intel
  env_is COMPOSE_FILE compose.yaml:hw/gpu-intel.yaml
  env_is RENDER_GID 991
  env_is INTEL_RENDER_PATH /dev/dri/by-path/pci-0000:00:02.0-render
  env_absent AMD_RENDER_PATH
  setup ok "Intel Quick Sync (tested path)."
  setup note "You also have an NVIDIA card. Intel is still the better"
  current T-042 "16 GB of RAM reads 14 GiB, a 4 GiB swap file reads 3"
  doctor kv Memory "14 GiB (swap 3 GiB)"
}
