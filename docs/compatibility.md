# Compatibility

What Anteiku has actually been run on, and how. Anything not listed
here, or listed as Untested, may work. Nobody has checked.

---

## Levels

| Level | Means |
|---|---|
| **Physical** | Ran on that real hardware: setup, deploy, and the checks named in the row |
| **Virtualized** | Ran in a virtual machine (real CPU, virtual devices) |
| **Emulated** | Ran under QEMU emulating another architecture |
| **Mocked** | `doctor.sh` and `setup.sh --dry-run` ran against a fake machine: files and tool output typed from upstream formats or copied from real hardware. Shows what the scripts make of that machine, not that anything runs on it |
| **Untested** | Not run |

Detected is not working. A GPU row needs a transcode, a distro row
needs a deploy, before either is more than Mocked.

**Run / case** is the release a row last ran on, or for Mocked rows
the case in [`tests/detect/cases.sh`](../tests/detect/cases.sh)
(`case_<name>`). Mocked cases run in CI (`check.sh`) on every push.
A row marked **known problem** records what the scripts do today; it is
not what they should do.

Today one machine is above Mocked: x86_64, Ubuntu 26.04, i5-9300H,
16 GB, Intel UHD 630 + NVIDIA GTX 1050 (nouveau driver), rootful
Docker, the test install on one ext4 filesystem. Before each release,
every service is brought up there together and checked: arr imports,
Jellyfin, reverse proxy and DNS, monitoring, Immich backup and restore,
notifications.

---

## Distro

| Distro | Level | Run / case | Notes |
|---|---|---|---|
| Ubuntu 26.04 | Physical | `2026.10.1`; `os_ubuntu_2604` | Every service. `doctor.sh` is not part of the release check; it last ran there on `main`, after `2026.10.1` |
| Ubuntu 24.04 | Mocked | `baseline` | Name and version read correctly. CI runs `setup.sh` and `compose config` on an Ubuntu 24.04 runner; no service is deployed |
| Ubuntu 22.04 | Mocked | `os_ubuntu_2204` | Name and version only |
| Debian 12 | Mocked | `os_debian_12` | Name and version only |
| Debian 13 | Mocked | `os_debian_13` | Name and version only |
| Fedora 43 | Mocked | `os_fedora` | Name and version only. SELinux not handled |
| Arch | Mocked | `os_arch` | Name only; rolling, so the version is blank |
| No `/etc/os-release` | Mocked | `os_none` | Shown as `unknown` |
| Anything else | Untested | — | |

## Architecture

| Arch | Level | Run / case | Notes |
|---|---|---|---|
| x86_64 | Physical | `2026.10.1`; `cpu_amd` | Intel CPU on hardware; an AMD CPU name Mocked only |
| aarch64 (ARM64) | Mocked, **known problem** | `arch_aarch64_pi5`, `arch_aarch64_vm` | `doctor.sh` says "a few are x86-only". Every pinned image publishes `linux/arm64` (registry, 2026-11-05), so the line is wrong. Nothing has run on ARM |
| armv7 (32-bit ARM) | Mocked | `arch_armv7` | `doctor.sh` reports an error. Not supported |
| riscv64 | Mocked | `arch_riscv64` | "Unrecognised architecture". Not supported |
| 32-bit x86 | Untested | — | Not supported |

## GPU (Jellyfin transcoding)

| GPU | Level | Run / case | Notes |
|---|---|---|---|
| Intel, i915 (UHD 630) | Physical | `2026.10.1`; `gpu_intel_i915` | VAAPI h264 encode inside Jellyfin, through the `by-path` node |
| Intel + NVIDIA in one machine | Physical | `2026.10.1`; `gpu_intel_nvidia` | Intel chosen, on purpose |
| Render node numbers swapped (Intel not on `renderD128`) | Physical | `2026.10.1`; `gpu_nodes_swapped` | On that machine `renderD128` is NVIDIA, `renderD129` Intel. The `by-path` link finds the Intel node either way |
| Intel, xe (Lunar Lake and newer) | Mocked | `gpu_intel_xe` | Detection only |
| Intel, no `lspci` | Mocked | `gpu_no_lspci_intel` | Still found, from `/sys` |
| AMD, amdgpu | Mocked | `gpu_amd` | Detection only. VAAPI Untested |
| NVIDIA, proprietary driver | Mocked | `gpu_nvidia_driver` | Detection only. NVENC Untested. The container toolkit is not checked |
| NVIDIA, nouveau | Physical (detection); Mocked, **known problem** | `2026.10.1`; `gpu_nvidia_nouveau` | On the Physical machine Intel wins, so nouveau is never used. Alone, `setup.sh` picks the NVIDIA profile anyway; nouveau has no NVENC. NVENC Untested |
| NVIDIA, no driver | Mocked, **known problem** | `gpu_nvidia_no_driver` | NVIDIA profile picked from `lspci` alone |
| NVIDIA, no `lspci` | Mocked, **known problem** | `gpu_no_lspci` | Never picked, even with the driver loaded |
| virtio-gpu (VM) | Mocked | `gpu_virtio` | CPU transcoding |
| QEMU standard VGA | Mocked | `gpu_bochs` | CPU transcoding |
| ASPEED (server BMC) | Mocked | `gpu_aspeed` | CPU transcoding |
| No GPU | Mocked | `baseline` | CPU transcoding. Detection only |
| No `/dev/dri/by-path` | Mocked | `gpu_no_by_path` | CPU transcoding; the node is shown, never written to `.env` |
| Render group: `render`, `video`, none | Mocked | `gpu_no_render_group`, `gpu_video_group_only`, `gpu_no_group_no_node` | |

## Storage

| Layout | Level | Run / case | Notes |
|---|---|---|---|
| One ext4 disk, configs and media together | Physical | `2026.10.1` | Imports are hardlinks (link count 2) |
| Free space warnings | Mocked | `disk_ok`, `disk_tight`, `disk_full` | Thresholds and the filesystem name only. Nothing else about xfs or btrfs is tested |
| Downloads and library on separate disks | Untested | — | Hardlinks can't cross filesystems; imports become copies |
| exFAT, NTFS, FAT32 media disks | Untested | — | No hardlinks, no Unix ownership |
| Read-only or missing folders | Untested | — | |

## Docker

| Setup | Level | Run / case | Notes |
|---|---|---|---|
| Docker Engine, rootful, Compose v2 plugin | Physical | `2026.10.1` | |
| Not installed; daemon down; user not in `docker` group | Mocked | `docker_absent`, `docker_down_not_in_group`, `docker_down_in_group` | |
| Distro `docker.io` without the Compose plugin | Mocked | `docker_no_compose` | `doctor.sh` reports an error |
| Rootless | Mocked | `docker_rootless` | Detection only. Deploy Untested |

## Other detection

| Item | Level | Run / case | Notes |
|---|---|---|---|
| Memory | Mocked, **known problem** | `mem_2gb`, `mem_4gb`, `mem_8gb`, `mem_16gb`, `mem_unreadable`, `capture_maintainer_laptop` | Memory and swap are rounded down to whole GiB: a 4 GB machine reads 3 and gets the "under 4 GiB" error, 8 GB reads 7 |
| Ports, with `ss` or `netstat` | Mocked | `ports_container`, `ports_ours`, `ports_dns`, `ports_netstat_only` | A taken port moves to the next free one |
| Ports, with neither tool | Mocked, **known problem** | `ports_no_tools` | Every port reads as free |
| Timezone without `timedatectl` | Mocked | `tz_file`, `tz_ctl_fails`, `tz_none` | Falls back to `/etc/timezone`, then UTC |
| User and group ids other than 1000 | Mocked | `user_ids` | |

---

## Where the scripts disagree with this page

| Script says | This page |
|---|---|
| `doctor.sh`, ARM64: "a few are x86-only" | All pinned images publish `linux/arm64` |
| `setup.sh`, NVIDIA: "Falls back to CPU transcoding if either is missing" | Not run. Docker normally refuses to start a container whose GPU request it can't meet, so expect no Jellyfin rather than CPU transcoding |

Both scripts label the NVIDIA and AMD paths "NOT maintainer-tested";
`doctor.sh` labels rootless Docker too. Neither labels ARM64.
