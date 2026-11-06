# shellcheck shell=bash
# ============================================================
#  tests/detect/cases.sh — the machines, for tests/detect/run.sh.
#
#  One function per case, named case_<group>_<what>. Fixture lines
#  first (they change the default machine in run.sh), then checks:
#
#    is DET_MEM_MIB 3793        what lib/detect.sh set (also: pick,
#                               port.<n>, fs_of, fstype_of, free_gb,
#                               image_store)
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
#  A gpu line also puts the card in sysfs: gpu "<lspci line>" vendor:device
#  [kernel driver]; override sets GPU_PROFILE_OVERRIDE for setup.sh.
#  Only what Anteiku reads is checked: no CPU flags, no VRAM, and nothing
#  about DET_CPU_VENDOR, DET_NVIDIA_RENDER or DET_RENDER_GROUP (unused).
# ============================================================

# Lines the GPU cases share, and the cards' PCI vendor:device ids.
L_INTEL_UHD630='00:02.0 VGA compatible controller: Intel Corporation CoffeeLake-H GT2 [UHD Graphics 630]'
L_INTEL_ARC='00:02.0 VGA compatible controller: Intel Corporation Lunar Lake [Intel Arc Graphics 130V / 140V] (rev 04)'
L_AMD_6700XT='03:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Navi 22 [Radeon RX 6700/6700 XT/6750 XT / 6800M/6850M XT] (rev c1)'
L_NV_3060='01:00.0 VGA compatible controller: NVIDIA Corporation GA104 [GeForce RTX 3060 Ti] (rev a1)'
L_NV_1050M='01:00.0 3D controller: NVIDIA Corporation GP107M [GeForce GTX 1050 Mobile] (rev a1)'
I_UHD630=8086:3e9b; I_ARC=8086:64a0; I_6700XT=1002:73df; I_3060=10de:2486; I_1050M=10de:1c8d
P_INTEL='0000:00:02.0'; P_AMD='0000:03:00.0'; P_NV='0000:01:00.0'
BP=/dev/dri/by-path
# What the scripts say about a card that isn't ready (nvidia_missing).
M_NOUVEAU="  - the proprietary NVIDIA driver (the card is on nouveau, which has no NVENC)"
M_NODRV="  - the proprietary NVIDIA driver (no driver is loaded for the card)"
M_TOOLKIT="  - nvidia-container-toolkit (docker info lists no nvidia runtime)"
M_DOCKER="  - a check of Docker's nvidia runtime (Docker isn't reachable)"
NV_CPU="NVIDIA card found, but Docker can't give it to Jellyfin — CPU transcoding."
NV_DOCTOR="Not usable yet, so setup.sh picks CPU transcoding. Missing:"

# ------------------------------------------------------------ baseline
case_baseline() {   # the default machine, unchanged
  is DET_DISTRO Ubuntu; is DET_DISTRO_VER 24.04; is DET_KERNEL 6.8.0-87-generic; is DET_ARCH x86_64
  is DET_CPU "Intel(R) Core(TM) i5-8500T CPU @ 2.10GHz"; is DET_CORES 6
  is DET_MEM_MIB 15866; is DET_MEM_GIB 15.5; is DET_TZ America/Toronto
  is DET_UID "$RUN_UID"; is DET_GID "$RUN_GID"
  is pick cpu; is DET_GPU_VENDORS ""; is DET_GPU_OTHER ""
  doctor kv Distro "Ubuntu 24.04"
  doctor kv CPU "Intel(R) Core(TM) i5-8500T CPU @ 2.10GHz (6 CPUs)"
  doctor kv Timezone America/Toronto
  doctor kv User "uid=$RUN_UID gid=$RUN_GID"
  doctor ok "64-bit x86 — every image in this repo has a build for it."
  doctor ok "Docker daemon is reachable."
  doctor ok "Compose plugin present — 'docker compose', the syntax this repo uses."
  doctor kv Compose "2.40.3 (plugin)"; doctor_lacks "v2"   # plugin versions aren't "v2" (T-077)
  setup ok "No container name collisions."; setup ok "Network name is free of conflicts."
  setup_lacks "Not checked without Docker"
  next step 1 "Your ports" "cat ports.md" "bookmark this"
  next_lacks "Not checked without Docker"; next_lacks "Compose plugin"
  doctor ok "All default ports for the arr stack are free."
  doctor kv GPU "none detected"
  doctor note "No GPU detected — CPU transcoding only."
  doctor_lacks "Timezone looks unset"
  env_is PUID "$RUN_UID"; env_is PGID "$RUN_GID"; env_is TZ America/Toronto
  env_is COMPOSE_FILE compose.yaml:hw/cpu-only.yaml
  env_is RENDER_GID 992
  env_absent INTEL_RENDER_PATH; env_absent AMD_RENDER_PATH
  setup ok "No usable GPU found — CPU transcoding."
  setup_lacks "NVIDIA"
  setup_lacks "Compose plugin ('docker compose') is missing"
}

# ------------------------------------------------------------ GPU
case_gpu_intel_i915() {
  gpu "$L_INTEL_UHD630" $I_UHD630 i915; render renderD128 i915 "$P_INTEL"
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
  gpu "$L_INTEL_ARC" $I_ARC xe; render renderD128 xe "$P_INTEL"
  is DET_INTEL_RENDER "$BP/pci-$P_INTEL-render"; is pick intel
  doctor kv "Render node" "/dev/dri/renderD128  (driver: xe)"
  env_is COMPOSE_FILE compose.yaml:hw/gpu-intel.yaml
  env_is INTEL_RENDER_PATH "$BP/pci-$P_INTEL-render"
}

case_gpu_amd() {
  gpu "$L_AMD_6700XT" $I_6700XT amdgpu; render renderD128 amdgpu "$P_AMD"
  is DET_GPU_VENDORS amd; is DET_AMD_RENDER "$BP/pci-$P_AMD-render"; is DET_INTEL_RENDER ""; is pick amd
  doctor warn "AMD VAAPI — this path is NOT maintainer-tested."
  doctor note "From the docs: VAAPI through amdgpu, the same interface as Intel."
  doctor_lacks "Works, but"
  env_is COMPOSE_FILE compose.yaml:hw/gpu-amd.yaml
  env_is AMD_RENDER_PATH "$BP/pci-$P_AMD-render"; env_absent INTEL_RENDER_PATH; env_is RENDER_GID 992
  setup warn "AMD VAAPI — this path is NOT maintainer-tested."
  setup note "device: $BP/pci-$P_AMD-render"
}

case_gpu_nvidia_driver() {   # proprietary driver and the toolkit's nvidia runtime: ready
  gpu "$L_NV_3060" $I_3060 nvidia; render renderD128 nvidia "$P_NV"; docker_is nvidia-runtime
  is DET_GPU_VENDORS nvidia; is DET_NVIDIA_DRIVER nvidia; is DET_DOCKER_NVIDIA 1; is pick nvidia
  doctor warn "NVIDIA NVENC — this path is NOT maintainer-tested."
  doctor note "NVIDIA only. Good encoder (NVENC), but it needs the"
  doctor ok "Both found: driver loaded, and Docker lists the nvidia runtime."
  doctor_lacks "Missing:"
  env_is COMPOSE_FILE compose.yaml:hw/gpu-nvidia.yaml
  env_absent INTEL_RENDER_PATH; env_absent AMD_RENDER_PATH
  setup warn "NVIDIA NVENC — this path is NOT maintainer-tested."
  setup note "The proprietary driver is loaded and Docker lists the nvidia"
  setup_lacks "Falls back to CPU"; setup_lacks "Missing:"
}

case_gpu_nvidia_nouveau() {   # nouveau has no NVENC; the toolkit alone doesn't help (this host, minus Intel)
  gpu "$L_NV_3060" $I_3060 nouveau; render renderD128 nouveau "$P_NV"; docker_is nvidia-runtime
  is DET_NVIDIA_DRIVER nouveau; is DET_DOCKER_NVIDIA 1; is pick cpu
  doctor warn "$NV_DOCTOR"; doctor note "$M_NOUVEAU"; doctor_lacks "$M_TOOLKIT"
  env_is COMPOSE_FILE compose.yaml:hw/cpu-only.yaml
  setup warn "$NV_CPU"; setup note "$M_NOUVEAU"; setup_lacks "$M_TOOLKIT"
  setup_lacks "Falls back to CPU transcoding"; setup_lacks "No usable GPU found"
}

case_gpu_nvidia_no_driver() {   # card present, no driver: no render node at all
  gpu "$L_NV_3060" $I_3060
  is DET_RENDER_NODES ""; is DET_NVIDIA_DRIVER ""; is DET_DOCKER_NVIDIA 0; is pick cpu
  doctor warn "$NV_DOCTOR"; doctor note "$M_NODRV"; doctor note "$M_TOOLKIT"
  env_is COMPOSE_FILE compose.yaml:hw/cpu-only.yaml
  setup warn "$NV_CPU"; setup note "$M_NODRV"; setup note "$M_TOOLKIT"
}

case_gpu_nvidia_no_runtime() {   # proprietary driver, toolkit not installed
  gpu "$L_NV_3060" $I_3060 nvidia; render renderD128 nvidia "$P_NV"
  is DET_NVIDIA_DRIVER nvidia; is DET_DOCKER_NVIDIA 0; is pick cpu
  doctor note "$M_TOOLKIT"; doctor_lacks "proprietary NVIDIA driver ("
  env_is COMPOSE_FILE compose.yaml:hw/cpu-only.yaml
  setup warn "$NV_CPU"; setup note "$M_TOOLKIT"; setup_lacks "proprietary NVIDIA driver ("
}

case_gpu_nvidia_docker_down() {   # driver loaded, but nothing to ask about the runtime
  gpu "$L_NV_3060" $I_3060 nvidia; render renderD128 nvidia "$P_NV"; docker_is down nvidia-runtime
  is DET_DOCKER_NVIDIA 0; is pick cpu
  env_is COMPOSE_FILE compose.yaml:hw/cpu-only.yaml
  setup note "$M_DOCKER"; setup_lacks "$M_TOOLKIT"
}

case_gpu_nvidia_override_unready() {   # forced anyway: the Physical failure path (Jellyfin stayed Created)
  gpu "$L_NV_3060" $I_3060 nouveau; render renderD128 nouveau "$P_NV"; docker_is nvidia-runtime; override nvidia
  env_is COMPOSE_FILE compose.yaml:hw/gpu-nvidia.yaml
  setup warn "overridden by GPU_PROFILE_OVERRIDE -> nvidia"
  setup warn "Jellyfin will not start with this profile. Missing:"
  setup note "$M_NOUVEAU"
  setup note "stays Created, and the error names libnvidia-ml.so.1."
}

case_gpu_override_no_card() {   # nvidia forced on a machine without one
  override nvidia
  env_is COMPOSE_FILE compose.yaml:hw/gpu-nvidia.yaml
  setup warn "Jellyfin will not start with this profile. Missing:"
  setup note "  - an NVIDIA card (none found)"
  setup_lacks "proprietary NVIDIA driver ("
}

case_gpu_intel_nvidia() {   # laptop: iGPU + discrete card; Intel wins on purpose
  gpu "$L_INTEL_UHD630" $I_UHD630 i915; gpu "$L_NV_1050M" $I_1050M nvidia
  render renderD128 i915 "$P_INTEL"; render renderD129 nvidia "$P_NV"
  is DET_GPU_VENDORS "intel nvidia"; is pick intel
  doctor warn "More than one render node. Do NOT pass /dev/dri/renderD128 directly."
  doctor note "You have both an Intel iGPU and an NVIDIA card."
  env_is COMPOSE_FILE compose.yaml:hw/gpu-intel.yaml
  env_is INTEL_RENDER_PATH "$BP/pci-$P_INTEL-render"
  setup note "You also have an NVIDIA card. Intel is still the better"
  setup note "$M_TOOLKIT"; setup_lacks "if you disagree."
}

case_gpu_intel_nvidia_ready() {   # both usable: the override is offered
  gpu "$L_INTEL_UHD630" $I_UHD630 i915; gpu "$L_NV_1050M" $I_1050M nvidia
  render renderD128 i915 "$P_INTEL"; render renderD129 nvidia "$P_NV"; docker_is nvidia-runtime
  is pick intel
  env_is COMPOSE_FILE compose.yaml:hw/gpu-intel.yaml
  setup note "GPU_PROFILE_OVERRIDE=nvidia ./setup.sh if you disagree."; setup_lacks "Missing:"
}

case_gpu_nodes_swapped() {   # the numbers swap across reboots; by-path doesn't (this host)
  gpu "$L_INTEL_UHD630" $I_UHD630 i915; gpu "$L_NV_1050M" $I_1050M nouveau; docker_is nvidia-runtime
  render renderD128 nouveau "$P_NV"; render renderD129 i915 "$P_INTEL"
  is DET_INTEL_RENDER "$BP/pci-$P_INTEL-render"; is pick intel
  doctor kv "Render node" "/dev/dri/renderD129  (driver: i915)"
  env_is INTEL_RENDER_PATH "$BP/pci-$P_INTEL-render"
  env_is COMPOSE_FILE compose.yaml:hw/gpu-intel.yaml
  setup note "$M_NOUVEAU"; setup_lacks "if you disagree."
}

case_gpu_virtio() {   # a KVM guest with virtio-gpu: a render node, no encoder
  gpu "00:01.0 VGA compatible controller: Red Hat, Inc. Virtio 1.0 GPU (rev 01)" 1af4:1050 virtio-pci
  render renderD128 virtio-pci "0000:00:01.0"
  is DET_GPU_VENDORS ""; is DET_GPU_OTHER "virtio-gpu (virtual machine)"; is pick cpu
  doctor kv "Render node" "/dev/dri/renderD128  (driver: virtio-pci)"
  doctor note "Only virtio-gpu (virtual machine): no video encoder."
  doctor_lacks "No GPU detected"
  env_is COMPOSE_FILE compose.yaml:hw/cpu-only.yaml
  env_absent INTEL_RENDER_PATH; env_absent AMD_RENDER_PATH
  setup ok "No usable GPU found — CPU transcoding."
  setup note "virtio-gpu (virtual machine): no video encoder."
}

case_gpu_bochs() {   # QEMU's standard VGA: display only, no render node
  gpu "00:02.0 VGA compatible controller: Device 1234:1111 (rev 02)" 1234:1111
  is DET_GPU_VENDORS ""; is DET_RENDER_NODES ""; is pick cpu
  doctor kv GPU "00:02.0 VGA compatible controller: Device 1234:1111 (rev 02)"
  doctor note "Only QEMU standard VGA (virtual machine): no video encoder."
  env_is COMPOSE_FILE compose.yaml:hw/cpu-only.yaml
  setup note "QEMU standard VGA (virtual machine): no video encoder."
}

case_gpu_aspeed() {   # server BMC graphics
  gpu "03:00.0 VGA compatible controller: ASPEED Technology, Inc. ASPEED Graphics Family (rev 41)" 1a03:2000 ast
  is DET_GPU_VENDORS ""; is pick cpu
  doctor note "Only ASPEED (server management graphics): no video encoder."
  doctor_lacks "No GPU detected"
  env_is COMPOSE_FILE compose.yaml:hw/cpu-only.yaml
  setup note "ASPEED (server management graphics): no video encoder."
}

case_gpu_no_lspci() {   # Debian/Arch minimal: no pciutils; the card comes from sysfs
  gpu "$L_NV_3060" $I_3060 nvidia; render renderD128 nvidia "$P_NV"; docker_is nvidia-runtime; no_tool lspci
  is DET_GPUS "01:00.0 NVIDIA [10de:2486]"; is DET_GPU_VENDORS nvidia
  doctor kv GPU "01:00.0 NVIDIA [10de:2486]"
  doctor note "lspci is not installed (package pciutils), so no model names;"
  doctor kv "Render node" "/dev/dri/renderD128  (driver: nvidia)"
  is pick nvidia
  env_is COMPOSE_FILE compose.yaml:hw/gpu-nvidia.yaml
}

case_gpu_no_lspci_intel() {   # Intel and AMD come from sysfs, so they survive it
  gpu "$L_INTEL_UHD630" $I_UHD630 i915; render renderD128 i915 "$P_INTEL"; no_tool lspci
  is DET_GPU_VENDORS intel; is pick intel
  env_is INTEL_RENDER_PATH "$BP/pci-$P_INTEL-render"
}

case_gpu_no_by_path() {   # no stable id: the node is shown, never written to .env
  gpu "$L_INTEL_UHD630" $I_UHD630 i915; render renderD128 i915
  is DET_INTEL_RENDER ""; is pick cpu
  doctor note "stable id: (no by-path entry)"
  env_is COMPOSE_FILE compose.yaml:hw/cpu-only.yaml
  env_absent INTEL_RENDER_PATH
}

case_gpu_no_render_group() {   # no render or video group: the node's own group
  gpu "$L_INTEL_UHD630" $I_UHD630 i915; render renderD128 i915 "$P_INTEL"; group render; group video
  is DET_RENDER_GID "$(stat -c %g "$R/dev/dri/renderD128")"
  env_is RENDER_GID "$(stat -c %g "$R/dev/dri/renderD128")"
  setup_lacks "Could not determine the render group id."
}

case_gpu_video_group_only() {   # older distros: video owns the nodes
  gpu "$L_INTEL_UHD630" $I_UHD630 i915; render renderD128 i915 "$P_INTEL"; group render
  is DET_RENDER_GID 44; env_is RENDER_GID 44
}

case_gpu_no_group_no_node() {   # override to a GPU with nothing to read the gid from
  group render; group video; gpu "$L_NV_3060" $I_3060; override nvidia
  is DET_RENDER_GID ""
  env_absent RENDER_GID
  setup warn "Could not determine the render group id."
}

# ------------------------------------------------------------ memory
# MemTotal is what the kernel reports: a little under the RAM installed.
# doctor compares MiB against 7/8 of 4 and 8 GiB (3584, 7168) and shows
# one decimal (T-042). Captured sizes: vm_ubuntu_2gib, vm_ubuntu_3gib.
M_UNDER4="Under 4 GiB RAM. The full arr stack will thrash or get OOM-killed."
case_mem_2gb() {
  mem_kb 2014560 0
  is DET_MEM_MIB 1967; is DET_MEM_GIB 1.9; is DET_SWAP_MIB 0; is DET_SWAP_GIB 0.0
  doctor kv Memory "1.9 GiB (swap 0.0 GiB)"
  doctor err "$M_UNDER4"
}

case_mem_4gb() {   # typical for 4 GB installed
  mem_kb 3884728 0
  is DET_MEM_MIB 3793; is DET_MEM_GIB 3.7
  doctor kv Memory "3.7 GiB (swap 0.0 GiB)"
  doctor warn "3.7 GiB RAM is workable but tight for the whole stack."
  doctor_lacks "Under 4 GiB"
}

case_mem_8gb() {   # typical for 8 GB installed, 2 GiB swap
  mem_kb 7975444 2097148
  is DET_MEM_MIB 7788; is DET_MEM_GIB 7.6; is DET_SWAP_MIB 2047; is DET_SWAP_GIB 2.0
  doctor kv Memory "7.6 GiB (swap 2.0 GiB)"
  doctor ok "7.6 GiB RAM is comfortable for this stack."
  doctor_lacks "tight"
}

case_mem_16gb() {
  mem_kb 16247300 0
  is DET_MEM_MIB 15866; is DET_MEM_GIB 15.5
  doctor ok "15.5 GiB RAM is comfortable for this stack."
  doctor kv Memory "15.5 GiB (swap 0.0 GiB)"
}

case_mem_edge_4() {   # exactly 3584 MiB: tight, not under 4
  mem_kb 3670016 0
  is DET_MEM_MIB 3584
  doctor warn "3.5 GiB RAM is workable but tight for the whole stack."
}

case_mem_below_edge_4() {   # 1 kB less: 3583 MiB
  mem_kb 3670015 0
  is DET_MEM_MIB 3583
  doctor err "$M_UNDER4"
}

case_mem_edge_8() {   # exactly 7168 MiB: comfortable
  mem_kb 7340032 0
  is DET_MEM_MIB 7168
  doctor ok "7.0 GiB RAM is comfortable for this stack."
}

case_mem_below_edge_8() {   # 7167 MiB
  mem_kb 7340031 0
  is DET_MEM_MIB 7167
  doctor warn "7.0 GiB RAM is workable but tight for the whole stack."
}

case_mem_unreadable() {   # no /proc/meminfo (a broken container)
  rm -f "$R/proc/meminfo"
  is DET_MEM_MIB 0; is DET_MEM_GIB 0.0
  doctor err "$M_UNDER4"
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
  doctor kv CPU "Raspberry Pi 5 Model B Rev 1.0 (4 CPUs)"
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
  doctor kv CPU "unknown (2 CPUs)"
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
  doctor kv CPU "AMD Ryzen 5 5600X 6-Core Processor (12 CPUs)"
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
  is DET_TZ Europe/Lisbon; env_is TZ Europe/Lisbon; is DET_TZ_FROM /etc/timezone
  doctor info "timedatectl not found: the timezone came from /etc/timezone."
}

case_tz_localtime() {   # Fedora/Arch have no /etc/timezone: the /etc/localtime link
  no_tool timedatectl; tz_link /usr/share/zoneinfo/Europe/Berlin
  is DET_TZ Europe/Berlin; is DET_TZ_FROM /etc/localtime; env_is TZ Europe/Berlin
  doctor info "timedatectl not found: the timezone came from /etc/localtime."
  doctor_lacks "Timezone looks unset"
}

case_tz_localtime_relative() {   # systemd writes the link relative
  no_tool timedatectl; tz_link ../usr/share/zoneinfo/America/Sao_Paulo
  is DET_TZ America/Sao_Paulo
}

case_tz_localtime_file() {   # a copied file, not a link: nothing to read
  no_tool timedatectl; mkdir -p "$R/etc"; : > "$R/etc/localtime"
  is DET_TZ Etc/UTC; is DET_TZ_FROM default
}

case_tz_ctl_fails() {   # timedatectl installed, systemd not running (a container)
  tz_ctl_fails; tz_file Asia/Tokyo
  is DET_TZ Asia/Tokyo
}

case_tz_none() {   # neither: UTC, and doctor says so
  no_tool timedatectl
  is DET_TZ Etc/UTC; env_is TZ Etc/UTC; is DET_TZ_FROM default
  doctor warn "Timezone looks unset (Etc/UTC). Schedules and logs will be in UTC."
  doctor info "timedatectl not found, and no /etc/timezone or /etc/localtime: the timezone is UTC."
}

# ------------------------------------------------------------ Docker
case_docker_absent() {
  docker_is absent
  is DET_DOCKER_VER ""; is DET_DOCKER_OK 0
  doctor err "Docker is not installed. Nothing here can run without it."
  setup_lacks "Compose plugin ('docker compose') is missing"   # no docker at all: not a plugin problem (T-073)
  # setup.sh writes the config, says so in doctor's words, and doesn't
  # claim checks it couldn't make (T-078).
  setup warn "Docker is not installed. Nothing here can run without it."
  setup note "Install: https://docs.docker.com/engine/install/"
  setup info "Container names and the network name: not checked, Docker is not installed."
  setup note "Not checked without Docker: container name collisions, the network name."
  setup_lacks "No container name collisions."; setup_lacks "Network name is free of conflicts."
  env_is COMPOSE_PROFILES "prowlarr,qbittorrent,sonarr,radarr,seerr,jellyfin"
  # The real run says it again right above the steps (T-060).
  next warn "Docker is not installed. Nothing here can run without it."
  next note "Not checked without Docker: container name collisions, the network name."
  next_lacks "Compose plugin ('docker compose') is missing"
}

case_docker_down_not_in_group() {
  docker_is down; user_groups "you adm"
  is DET_DOCKER_OK 0; is DET_IN_DOCKER_GROUP 0
  doctor err "Docker is installed but the daemon is not reachable as this user."
  doctor note "You are not in the 'docker' group. Fix, then log out and back in:"
  setup warn "Docker is installed but the daemon is not reachable as this user."
  setup note "You are not in the 'docker' group. Fix, then log out and back in:"
  setup note "  sudo usermod -aG docker \$USER"
  setup info "Container names and the network name: not checked, Docker is not reachable."
  setup_lacks "No container name collisions."; setup_lacks "Network name is free of conflicts."
  setup_lacks "Is it running?"
  env_is COMPOSE_PROFILES "prowlarr,qbittorrent,sonarr,radarr,seerr,jellyfin"
}

case_docker_down_in_group() {
  docker_is down
  is DET_IN_DOCKER_GROUP 1
  doctor note "Is it running?  sudo systemctl status docker"
  setup warn "Docker is installed but the daemon is not reachable as this user."
  setup note "Is it running?  sudo systemctl status docker"
  setup note "Once ./doctor.sh says the daemon is reachable, re-run this script"
  setup_lacks "No container name collisions."; setup_lacks "You are not in the 'docker' group"
  next warn "Docker is installed but the daemon is not reachable as this user."
  next note "Is it running?  sudo systemctl status docker"
  next note "Once ./doctor.sh says the daemon is reachable, re-run this script"
}

# A re-run can't be written without Docker: the install's own containers
# may hold their ports, and only Docker can say they are its own (T-078).
case_docker_down_rerun() {   # own Sonarr on 8989, daemon unreachable: refused, nothing written
  docker_is down; refuses; listen 8989
  prev_env <<'ENV'
COMPOSE_PROFILES=sonarr
PORT_SONARR=8989
ENV
  setup err "Docker is installed but the daemon is not reachable as this user."
  setup note "Is it running?  sudo systemctl status docker"
  setup note "from a clash, so their ports would move. Refusing; nothing was written."
  setup_lacks "Configuration to write"; setup_lacks "No container name collisions."
}

case_docker_absent_rerun() {   # no Docker, nothing of the install can be running: written
  docker_is absent
  prev_env <<'ENV'
COMPOSE_PROFILES=sonarr
PORT_SONARR=8989
ENV
  env_is PORT_SONARR 8989
  setup warn "Docker is not installed. Nothing here can run without it."
  setup_lacks "Refusing"
}

case_docker_no_compose() {   # distro docker.io without the compose plugin
  docker_is no-compose
  is DET_COMPOSE_VER ""
  doctor err "The Compose plugin ('docker compose') is missing."
  doctor note "The old 'docker-compose' script will not work here."
  doctor note "Install the plugin: https://docs.docker.com/compose/install/"
  doctor_lacks "v2"   # plugin versions aren't "v2" (T-077)
  # setup.sh still writes the config (T-073): it doesn't need compose, and
  # says so before the steps that do.
  setup warn "The Compose plugin ('docker compose') is missing."
  setup note "The old 'docker-compose' script will not work here."
  setup_lacks "v2 plugin"
  setup note "Install the plugin: https://docs.docker.com/compose/install/"
  setup note "Until it is installed, every 'docker compose' command fails."
  env_is COMPOSE_PROFILES "prowlarr,qbittorrent,sonarr,radarr,seerr,jellyfin"
  next warn "The Compose plugin ('docker compose') is missing."
  next note "Until it is installed, every 'docker compose' command fails."
  next_lacks "Not checked without Docker"
}

case_docker_down_no_compose() {   # the plugin check needs no daemon
  docker_is down no-compose
  is DET_COMPOSE_VER ""; is DET_DOCKER_OK 0
  doctor err "The Compose plugin ('docker compose') is missing."
  setup warn "The Compose plugin ('docker compose') is missing."
}

case_docker_rootless() {
  docker_is rootless
  is DET_DOCKER_ROOTLESS 1
  doctor warn "Rootless Docker detected — this path is NOT maintainer-tested."
  doctor note "From Docker's docs: ports below 1024 will not bind, and device"
  doctor_lacks "Everything else works"
  doctor kv Engine "29.0.1"; doctor kv Compose "2.40.3 (plugin)"
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

# doctor on a running install (T-074): its own containers on its own ports
# are no clash. "Own" = the compose project in .env, as setup.sh's held_by_us.
case_ports_doctor_own() {   # the five defaults up, as every S37 distro row had them
  installed; install_env <<< "COMPOSE_PROJECT_NAME=anteiku-fx"
  listen 9696; listen 8181; listen 8989; listen 7878; listen 5055
  container fx-prowlarr 9696 anteiku-fx prowlarr; container fx-qbittorrent 8181 anteiku-fx qbittorrent
  container fx-sonarr 8989 anteiku-fx sonarr; container fx-radarr 7878 anteiku-fx radarr
  container fx-seerr 5055 anteiku-fx seerr
  doctor info "8989 (Sonarr) is in use by Anteiku's sonarr."
  doctor info "8181 (qBittorrent) is in use by Anteiku's qbittorrent."
  doctor ok "No clashes: the default ports in use are this install's own."
  doctor_lacks "is already in use by"
  doctor_lacks "setup.sh can shift these"
  doctor_lacks "All default ports for the arr stack are free."
}

case_ports_doctor_foreign() {   # another compose project's sonarr on 8989: still a clash
  installed; install_env <<< "COMPOSE_PROJECT_NAME=anteiku-fx"
  listen 8989; container media-sonarr 8989 media sonarr
  doctor warn "8989 (Sonarr) is already in use by: container 'media-sonarr'"
  doctor note "setup.sh can shift these. Nothing is forced to a fixed port."
  doctor_lacks "Anteiku's"
}

case_ports_doctor_both() {   # own sonarr, a foreign container and a process
  installed; install_env <<< "COMPOSE_PROJECT_NAME=anteiku-fx"
  listen 8989; container fx-sonarr 8989 anteiku-fx sonarr
  listen 7878; container old-radarr 7878 media radarr
  listen 9696 python3
  doctor info "8989 (Sonarr) is in use by Anteiku's sonarr."
  doctor warn "7878 (Radarr) is already in use by: container 'old-radarr'"
  doctor warn "9696 (Prowlarr) is already in use by: python3"
  doctor note "setup.sh can shift these. Nothing is forced to a fixed port."
  doctor_lacks "No clashes"
}

case_ports_doctor_no_env() {   # no install: nothing is "own", whatever its labels
  listen 8989; container anteiku-sonarr 8989 anteiku sonarr
  doctor warn "8989 (Sonarr) is already in use by: container 'anteiku-sonarr'"
  doctor_lacks "Anteiku's"
}

case_ports_doctor_env_project() {   # COMPOSE_PROJECT_NAME missing from .env: setup.sh's default
  installed
  listen 8989; container anteiku-sonarr 8989 anteiku sonarr
  doctor info "8989 (Sonarr) is in use by Anteiku's sonarr."
}

case_ports_doctor_shell_project() {   # compose reads COMPOSE_PROJECT_NAME from the shell before .env
  installed; install_env <<< "COMPOSE_PROJECT_NAME=anteiku-fx"; shell_env COMPOSE_PROJECT_NAME=other
  listen 8989; container o-sonarr 8989 other sonarr
  listen 7878; container fx-radarr 7878 anteiku-fx radarr
  doctor info "8989 (Sonarr) is in use by Anteiku's sonarr."
  doctor warn "7878 (Radarr) is already in use by: container 'fx-radarr'"
}

case_ports_ours_other_service() {   # this project's Radarr on 8989 is not Sonarr's own port
  listen 8989; container fx-radarr 8989 anteiku-fx radarr
  env_is PORT_SONARR 8990
}

case_ports_doctor_own_pihole() {   # this install's Pi-hole on 53: not the systemd-resolved trap
  installed; install_env <<< "COMPOSE_PROJECT_NAME=anteiku-fx"
  listen 53; container fx-pihole 53 anteiku-fx pihole
  doctor info "Port 53 is in use by Anteiku's pihole."
  doctor_lacks "Port 53 is taken by"
  doctor_lacks "faceplant"
}

case_ports_dns() {   # systemd-resolved on 53, the Pi-hole trap
  listen 53 systemd-resolve
  is port.53 "used by systemd-resolve"
  doctor warn "Port 53 is taken by: systemd-resolve"
}

case_ports_netstat_only() {   # no ss (net-tools only): the hint names the tool that is there
  listen 8989; no_tool ss
  is port.8989 "used by unidentified (try: sudo netstat -lntup | grep :8989)"
  env_is PORT_SONARR 8990
  doctor info "ss not found: ports are checked with netstat instead; their owner is only named for a container."
  doctor warn "8989 (Sonarr) is already in use by: unidentified (try: sudo netstat -lntup | grep :8989)"
}

case_ports_no_tools() {   # neither ss nor netstat: never "free"; setup keeps the default and says so
  listen 8989; no_tool ss netstat
  is port.8989 unchecked; is port.7878 unchecked; is port.53 unchecked
  doctor warn "Can't check the ports: neither ss nor netstat is installed."
  doctor note "they are free. Install: sudo apt install iproute2"
  doctor info "ss not found, netstat neither: ports can't be checked, so setup.sh can't move a taken one."
  doctor_lacks "All default ports for the arr stack are free."
  doctor_lacks "Port 53 is taken"
  setup warn "Can't check which ports are free: neither ss nor netstat is installed."
  setup note "Install: sudo apt install iproute2, then re-run this script: it moves taken ports."
  setup info "sonarr: 8989 (not checked)"
  setup info "PORT_JELLYFIN_DISCOVERY: 7359  (client auto-discovery, not checked)"
  setup_lacks "taken by"
  env_is PORT_SONARR 8989
}

case_ports_no_tools_rerun() {   # an earlier run moved Sonarr: unchecked, its port stays put
  listen 8989; no_tool ss netstat
  prev_env <<'ENV'
COMPOSE_PROFILES=sonarr,pihole
PORT_SONARR=8990
PORT_PIHOLE=53
ENV
  env_is PORT_SONARR 8990; env_is PORT_PIHOLE 53
  setup info "sonarr: 8990 (not checked)"
  setup warn "Port 53 not checked. Pi-hole can only serve your network on 53."
  setup_lacks "Port 53 is free"
}

case_ports_no_tools_fedora() {   # the hints follow the distro
  no_tool ss netstat
  os_release <<'EOF2'
NAME="Fedora Linux"
ID=fedora
VERSION_ID=43
EOF2
  doctor note "they are free. Install: sudo dnf install iproute"
  setup note "Install: sudo dnf install iproute, then re-run this script: it moves taken ports."
  doctor_lacks "apt install"; setup_lacks "apt install"
}

# qBittorrent listens on its host port inside Docker too (T-062): a move
# changes qbittorrent:<port> for Sonarr and Radarr, so setup.sh says so.
case_ports_qbit_moved() {   # 8181 taken since the last run: moves, and the arrs must follow
  listen 8181
  prev_env <<'ENV'
COMPOSE_PROFILES=qbittorrent,sonarr,radarr
PORT_QBITTORRENT=8181
ENV
  env_is PORT_QBITTORRENT 8182
  setup warn "qbittorrent: other containers now reach it at qbittorrent:8182, not qbittorrent:8181."
  setup note "client in Sonarr and Radarr (Settings > Download Clients)."
}

case_ports_qbit_back() {   # moved last time, default free again: back to 8181, and said
  prev_env <<'ENV'
COMPOSE_PROFILES=qbittorrent,sonarr,radarr
PORT_QBITTORRENT=8182
ENV
  env_is PORT_QBITTORRENT 8181
  setup warn "qbittorrent: other containers now reach it at qbittorrent:8181, not qbittorrent:8182."
}

case_ports_qbit_kept() {   # same port as last time: nothing to say
  listen 8181
  prev_env <<'ENV'
COMPOSE_PROFILES=qbittorrent,sonarr,radarr
PORT_QBITTORRENT=8182
ENV
  env_is PORT_QBITTORRENT 8182
  setup_lacks "other containers now reach it"
}

# ------------------------------------------------------------ disk (df helpers)
case_disk_ok() {
  disk 512 ext4 /srv
  is fs_of /srv; is fstype_of ext4; is free_gb 512
  doctor kv "This directory" "/srv  (ext4, 512 GB free)"
  doctor kv "Images" "/srv  (ext4, 512 GB free; /var/lib/containerd)"
  doctor ok "512 GB free for images."
}

# Where images go (T-069): Docker 29's default store keeps them in
# containerd's root (its config's "root", else /var/lib/containerd); the
# classic store in "Docker Root Dir". Not where Anteiku was cloned.
case_disk_images_elsewhere() {   # cloned onto a big media disk, / nearly full
  disk 800 ext4 /mnt/media; disk_at /var/lib/containerd 8 ext4 /
  is image_store /var/lib/containerd; is DET_DOCKER_STORE containerd; is DET_DOCKER_ROOT /var/lib/docker
  doctor kv "This directory" "/mnt/media  (ext4, 800 GB free)"
  doctor kv "Images" "/  (ext4, 8 GB free; /var/lib/containerd)"
  doctor err "$D_UNDER10"
  doctor note "Docker keeps images in /var/lib/containerd, not in this folder."
  doctor_lacks "800 GB free for images"
}

case_disk_images_containerd_root() {   # containerd's root moved to a big disk
  disk 5 ext4 /
  containerd_conf <<'EOF'
version = 3
#root = "/var/lib/old-containerd"
root = "/data/containerd"
#state = "/run/containerd"
EOF
  disk_at /data/containerd 300 xfs /data
  is image_store /data/containerd
  doctor kv "This directory" "/  (ext4, 5 GB free)"
  doctor kv "Images" "/data  (xfs, 300 GB free; /data/containerd)"
  doctor ok "300 GB free for images."
}

case_disk_images_containerd_default() {   # as containerd.io ships it: root commented out
  containerd_conf <<'EOF'
disabled_plugins = ["cri"]
#root = "/var/lib/containerd"
#state = "/run/containerd"
[plugins."io.containerd.example"]
  root = "/not/the/root"
EOF
  disk_at /var/lib/containerd 30 ext4 /
  is image_store /var/lib/containerd
  doctor warn "30 GB $D_LIBRARY"
}

case_disk_images_classic() {   # the classic store: images under Docker Root Dir
  docker_store classic /srv/docker; disk_at /srv/docker 30 xfs /srv; disk_at /var/lib/containerd 4
  is DET_DOCKER_STORE classic; is image_store /srv/docker
  doctor kv "Images" "/srv  (xfs, 30 GB free; /srv/docker)"
  doctor warn "30 GB $D_LIBRARY"
}

case_disk_images_docker_down() {   # can't ask Docker: say so, judge this folder
  docker_is down; disk 6
  is image_store ""
  doctor kv "Images" "unknown: Docker is not reachable"
  doctor note "Judged on this folder instead. Docker keeps images in its own folder,"
  doctor err "$D_UNDER10"
}

case_disk_images_docker_absent() {
  docker_is absent
  is image_store ""
  doctor kv "Images" "unknown: Docker is not installed"
  doctor ok "200 GB free for images."
}

case_disk_images_rootless() {   # rootless Docker runs its own containerd: not read
  docker_is rootless; disk_at /var/lib/containerd 8
  is image_store ""
  doctor kv "Images" "unknown: rootless Docker's image store is not read"
  doctor ok "200 GB free for images."
}

case_disk_images_not_here() {   # Docker Root Dir isn't on this machine (a remote daemon)
  docker_store classic /var/lib/docker; no_path /var/lib/docker
  is image_store /var/lib/docker
  doctor kv "Images" "unknown: /var/lib/docker is not on this machine"
}

# df counts 1K blocks; GB here are decimal, floored (T-069). GNU df's own
# --block-size rounds up, and 1G is GiB: 9.5 GB used to read "10 GB".
case_disk_gb_not_gib() {
  disk_kb 9667969   # 9.9 GB, 9.22 GiB
  is free_gb 9
  doctor kv "This directory" "/  (ext4, 9 GB free)"
  doctor err "$D_UNDER10"
}

case_disk_gb_edge() {
  disk_kb 9765625   # exactly 10 GB
  is free_gb 10
  doctor warn "10 GB $D_STARTER"
}

# Image sizes as a default Docker 29 install stores them (T-068): the
# starter set about 4 GB, every service about 17 GB.
D_UNDER10="Under 10 GB free. The starter set's images take about 4 GB, and an update needs room for new ones."
D_STARTER="free — enough for the starter set, not for every service: all the images take about 17 GB."
D_LIBRARY="free — enough for images and configs, not a library."
case_disk_tight() {
  disk 30 xfs
  doctor warn "30 GB $D_LIBRARY"
  doctor_lacks "starter set"
}

case_disk_full() {
  disk 6 btrfs
  doctor err "$D_UNDER10"
}

case_disk_edge_10() {   # 9 is under, 10 is the starter set
  disk 10
  doctor warn "10 GB $D_STARTER"
  doctor_lacks "Under 10 GB"
}

case_disk_below_10() {
  disk 9
  doctor err "$D_UNDER10"
}

case_disk_starter_only() {
  disk 24
  doctor warn "24 GB $D_STARTER"
  doctor_lacks "not a library"
}

case_disk_edge_25() {
  disk 25
  doctor warn "25 GB $D_LIBRARY"
  doctor_lacks "starter set"
}

case_disk_below_50() {
  disk 49
  doctor warn "49 GB $D_LIBRARY"
}

case_disk_edge_50() {
  disk 50
  doctor ok "50 GB free for images."
}

# ------------------------------------------------------------ other tools
case_tools_no_nproc() {
  no_tool nproc
  is DET_CORES "?"
}

# curl, git and crontab are never on the fixtures' PATH: every case is a
# machine without them. These check what doctor and update.sh say.
case_tools_debian() {   # Ubuntu (ID_LIKE=debian): apt
  is family debian; is hint "Install: sudo apt install iproute2 curl"
  doctor warn "curl not found: update.sh and the update check can't reach GitHub; ntfy messages aren't sent."
  doctor warn "git not found: update.sh can't move this folder to a new release."
  doctor note "Install: sudo apt install curl git"
  doctor warn "crontab not found: update.sh --schedule can't add the weekly check."
  doctor note "Install: sudo apt install cron"
  doctor_lacks "lspci not found"; doctor_lacks "ss not found"; doctor_lacks "timedatectl not found"
}

case_tools_debian_plain() {   # Debian itself: ID=debian, no ID_LIKE
  os_release <<'EOF2'
NAME="Debian GNU/Linux"
ID=debian
VERSION_ID="13"
EOF2
  is family debian; is cron_hint "Install: sudo apt install cron"
}

case_tools_ubuntu_derivative() {   # ID_LIKE=ubuntu only (some derivatives)
  os_release <<'EOF2'
NAME="Example OS"
ID=exampleos
ID_LIKE=ubuntu
EOF2
  is family debian
}

case_tools_fedora() {
  os_release <<'EOF2'
NAME="Fedora Linux"
ID=fedora
VERSION_ID=43
EOF2
  no_tool lspci
  is family fedora; is hint "Install: sudo dnf install iproute curl"
  is cron_hint "Install: sudo dnf install cronie && sudo systemctl enable --now crond"
  doctor info "lspci not found: GPUs are shown by PCI id, without model names."
  doctor note "Install: sudo dnf install pciutils curl git"
  doctor note "Install: sudo dnf install cronie && sudo systemctl enable --now crond"
  doctor_lacks "apt install"
}

case_tools_rocky() {   # ID_LIKE="rhel centos fedora": dnf
  os_release <<'EOF2'
NAME="Rocky Linux"
ID="rocky"
ID_LIKE="rhel centos fedora"
VERSION_ID="9.6"
EOF2
  is family fedora; is hint "Install: sudo dnf install iproute curl"
}

case_tools_arch() {
  os_release <<'EOF2'
NAME="Arch Linux"
ID=arch
BUILD_ID=rolling
EOF2
  is family arch; is hint "Install: sudo pacman -S iproute2 curl"
  is cron_hint "Install: sudo pacman -S cronie && sudo systemctl enable --now cronie"
  doctor note "Install: sudo pacman -S curl git"
  doctor_lacks "apt install"; doctor_lacks "dnf install"
}

case_tools_manjaro() {   # ID_LIKE=arch
  os_release <<'EOF2'
NAME="Manjaro Linux"
ID="manjaro"
ID_LIKE="arch"
EOF2
  is family arch
}

case_tools_other_distro() {   # openSUSE: no guess at a package manager
  os_release <<'EOF2'
NAME="openSUSE Tumbleweed"
ID="opensuse-tumbleweed"
ID_LIKE="opensuse suse"
EOF2
  is family ""; is hint "Install them with your distro's package manager: ss curl"
  doctor note "Install them with your distro's package manager: curl git"
  doctor note "Install a cron daemon (cronie or cron) with your distro's package manager, and start it."
  doctor_lacks "apt install"; doctor_lacks "dnf install"; doctor_lacks "pacman -S"
}

case_tools_no_os_release() {
  no_os_release
  is family ""
  doctor note "Install them with your distro's package manager: curl git"
}

# An install (copied into the case's temp dir, with a .env) reaches the
# update paths. Without curl, git or crontab nothing touches the network
# or a crontab.
case_tools_installed_doctor() {
  installed notify
  doctor note "Could not ask GitHub for the newest release: curl is not installed."
  doctor note "No weekly check scheduled, and none can be: crontab is not installed."
  doctor_lacks "(offline?)"; doctor_lacks "To add one:  ./update.sh --schedule"
}

case_tools_update_check() {
  installed
  exits update_check 2
  upd update_check err "curl is not installed: it asks GitHub for the newest release."
  upd update_check note "Install: sudo apt install curl"
}

case_tools_update() {   # git first: the old message blamed the folder
  installed
  exits update 1
  upd update err "git is not installed: update.sh needs it."
  upd update note "Install: sudo apt install git"
  upd_lacks update "not a git checkout"
}

case_tools_update_schedule() {
  installed
  exits update_schedule 1
  upd update_schedule err "crontab not found."
  upd update_schedule note "Install: sudo apt install cron"
}

case_tools_update_schedule_arch() {   # update.sh reads os-release itself; quoted, as Manjaro writes it
  os_release <<'EOF2'
NAME="Manjaro Linux"
ID="manjaro"
ID_LIKE="arch"
EOF2
  installed
  exits update_schedule 1
  upd update_schedule note "Install: sudo pacman -S cronie && sudo systemctl enable --now cronie"
  upd_lacks update_schedule "apt install"
}

# setup.sh's "Next" steps, from a real --yes run in a copy (setup_real).
# Step 6 offers ./update.sh --schedule only where it can work (T-060).
M_CRON="crontab not found: update.sh --schedule can't add the weekly check."
case_tools_next_no_crontab() {   # Ubuntu, cron not installed
  next step 4 "Start it" "docker compose up -d"
  next step 6 "Weekly update check" "./update.sh --schedule" "needs cron first"
  next note "$M_CRON"
  next note "Install: sudo apt install cron"
  next_lacks "one line in your crontab"
}

case_tools_next_no_crontab_fedora() {   # Fedora ships no cron: its own hint
  os_release <<'EOF2'
NAME="Fedora Linux"
ID=fedora
VERSION_ID=43
EOF2
  next note "$M_CRON"
  next note "Install: sudo dnf install cronie && sudo systemctl enable --now crond"
  next_lacks "apt install"
}

case_tools_next_crontab_empty() {   # cron installed, nothing scheduled yet
  crontab_lists < /dev/null
  next step 6 "Weekly update check" "./update.sh --schedule" "one line in your crontab"
  next_lacks "crontab not found"; next_lacks "Install:"
  doctor_lacks "crontab not found"
}

case_tools_next_crontab_scheduled() {   # the weekly line is there for this folder: no step 6
  crontab_lists <<EOF2
30 6 * * 1 cd '$FX/real' && ./update.sh --cron >/dev/null 2>&1 # anteiku-update $FX/real
EOF2
  next step 5 "See what is up" "docker compose ps"
  next_lacks "Weekly update check"; next_lacks "crontab not found"
}

case_tools_next_update_off() {   # update checks off: no step 6, cron or not
  prev_env <<'ENV'
COMPOSE_PROFILES=sonarr
PORT_SONARR=8989
UPDATE_MODE=off
ENV
  next step 4 "Apply it" "docker compose up -d" "starts what is new; running services are left alone"
  next_lacks "Weekly update check"; next_lacks "crontab not found"
}

# ------------------------------------------------------------ captured
# From a real machine (the workspace capture tool), checked against what
# doctor.sh and setup.sh printed on that machine itself, the same day.
case_capture_maintainer_laptop() {
  from 'captured: the maintainer server (laptop, i5-9300H, UHD 630 + GTX 1050 on nouveau), 2026-11-05; GPU ids and nvidia runtime 2026-11-06'
  os_release <<'EOS'
NAME="Ubuntu"
VERSION_ID="26.04"
EOS
  arch 'x86_64'; kernel '7.0.0-34-generic'; cores '8'
  cpu_model 'Intel(R) Core(TM) i5-9300H CPU @ 2.40GHz' 8
  mem_kb 15684192 4194300
  gpu '00:02.0 VGA compatible controller: Intel Corporation CoffeeLake-H GT2 [UHD Graphics 630]' 8086:3e9b 'i915'
  gpu '01:00.0 VGA compatible controller: NVIDIA Corporation GP107M [GeForce GTX 1050 3 GB Max-Q] (rev a1)' 10de:1c91 'nouveau'
  docker_is nvidia-runtime
  render renderD128 'nouveau' '0000:01:00.0'
  render renderD129 'i915' '0000:00:02.0'
  group render 991
  group video 44
  doctor kv Distro "Ubuntu 26.04"
  doctor kv Kernel "7.0.0-34-generic"
  doctor kv CPU "Intel(R) Core(TM) i5-9300H CPU @ 2.40GHz (8 CPUs)"
  doctor kv GPU "00:02.0 VGA compatible controller: Intel Corporation CoffeeLake-H GT2 "
  doctor kv "Render node" "/dev/dri/renderD128  (driver: nouveau)"
  doctor note "stable id: /dev/dri/by-path/pci-0000:00:02.0-render"
  doctor warn "More than one render node. Do NOT pass /dev/dri/renderD128 directly."
  is pick intel
  env_is COMPOSE_FILE compose.yaml:hw/gpu-intel.yaml
  env_is RENDER_GID 991
  env_is INTEL_RENDER_PATH /dev/dri/by-path/pci-0000:00:02.0-render
  is DET_NVIDIA_DRIVER nouveau; is DET_DOCKER_NVIDIA 1
  setup note "$M_NOUVEAU"; setup_lacks "if you disagree."
  env_absent AMD_RENDER_PATH
  setup ok "Intel Quick Sync (tested path)."
  setup note "You also have an NVIDIA card. Intel is still the better"
  is DET_MEM_MIB 15316; is DET_SWAP_MIB 4095
  doctor kv Memory "15.0 GiB (swap 4.0 GiB)"
  doctor ok "15.0 GiB RAM is comfortable for this stack."
}

# Test VMs (KVM, Ubuntu 26.04, docker base), T-042. MemTotal for RAM given
# to the VM; nproc = vCPUs. Larger sizes are typical values in mem_4gb/8gb.
case_vm_ubuntu_2gib() {
  from 'captured: Ubuntu 26.04 KVM VM, 2048 MiB, 1 vCPU, 2026-11-06'
  os_release <<'EOF'
NAME="Ubuntu"
VERSION_ID="26.04"
EOF
  arch 'x86_64'; kernel '7.0.0-43-generic'; cores '1'
  cpu_model 'Intel(R) Core(TM) i5-9300H CPU @ 2.40GHz' 1
  mem_kb 2009876 0
  group render 990
  group video 44
  is DET_MEM_MIB 1962; is DET_MEM_GIB 1.9; is DET_CORES 1
  doctor kv CPU "Intel(R) Core(TM) i5-9300H CPU @ 2.40GHz (1 CPU)"
  doctor kv Memory "1.9 GiB (swap 0.0 GiB)"
  doctor err "$M_UNDER4"
}

case_vm_ubuntu_3gib() {
  from 'captured: Ubuntu 26.04 KVM VM, 3072 MiB, 2 vCPU, 2026-11-06'
  os_release <<'EOF'
NAME="Ubuntu"
VERSION_ID="26.04"
EOF
  arch 'x86_64'; kernel '7.0.0-43-generic'; cores '2'
  cpu_model 'Intel(R) Core(TM) i5-9300H CPU @ 2.40GHz' 2
  mem_kb 2972336 0
  group render 990
  group video 44
  is DET_MEM_MIB 2902; is DET_MEM_GIB 2.8; is DET_CORES 2
  doctor kv CPU "Intel(R) Core(TM) i5-9300H CPU @ 2.40GHz (2 CPUs)"
  doctor kv Memory "2.8 GiB (swap 0.0 GiB)"
  doctor err "$M_UNDER4"
}
