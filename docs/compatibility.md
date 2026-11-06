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

Virtual machines have run too: clean cloud images of Ubuntu 22.04,
24.04 and 26.04 and Debian 12 and 13 (KVM, 2 vCPU, 3 GiB), each with
Docker Engine 29.9.3 and Compose 5.7.0 from Docker's apt repository,
installed the way the README says. On `main`, 2026-11-06, after
`2026.10.1`, each one ran `doctor.sh`, `setup.sh --dry-run` (nothing
written), `setup.sh` and a re-run (`.env` unchanged), then the
default services: all six running, no restarts, every web UI
answering on its host port, qBittorrent's login included.

---

## Distro

| Distro | Level | Run / case | Notes |
|---|---|---|---|
| Ubuntu 26.04 | Physical | `2026.10.1`; `os_ubuntu_2604` | Every service. In `2026.10.1` qBittorrent's web UI answers 401 "Unauthorized" on its host port (`8181`): it rejects a Host header whose port is not the one it listens on (`8080` inside). Fixed after `2026.10.1`: it listens on `8181` inside too. The clean VM above opens it and logs in on its host port, and the release check now checks that. `doctor.sh` is not part of the release check; it last ran there on `main`, after `2026.10.1` |
| Ubuntu 24.04 | Virtualized; Mocked | 2026-11-06, after `2026.10.1`; `baseline` | Default services deployed in a clean VM (above). CI also runs `setup.sh` and `compose config` on an Ubuntu 24.04 runner |
| Ubuntu 22.04 | Virtualized; Mocked | 2026-11-06, after `2026.10.1`; `os_ubuntu_2204` | Default services deployed in a clean VM (above) |
| Debian 12 | Virtualized; Mocked | 2026-11-06, after `2026.10.1`; `os_debian_12` | Default services deployed in a clean VM (above), Docker from [Docker's Debian instructions](https://docs.docker.com/engine/install/debian/); the README links the Ubuntu ones. The cloud image has no `git` or `cron`: Docker's packages bring `git`; `doctor.sh` names the missing `cron` |
| Debian 13 | Virtualized; Mocked | 2026-11-06, after `2026.10.1`; `os_debian_13` | As Debian 12 |
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
| NVIDIA, proprietary driver + container toolkit | Mocked | `gpu_nvidia_driver` | Picked only when the `nvidia` driver is bound to the card and `docker info` lists the `nvidia` runtime. NVENC Untested |
| NVIDIA, nouveau | Physical (failure path); Mocked | `main`, 2026-11-06; `gpu_nvidia_nouveau`, `gpu_nvidia_override_unready` | CPU transcoding; `setup.sh` names the missing driver. Forced with `GPU_PROFILE_OVERRIDE=nvidia` on that machine (toolkit installed): `docker compose up` fails, Jellyfin stays Created, the error names `libnvidia-ml.so.1`. Nothing falls back to the CPU. NVENC Untested |
| NVIDIA, no driver | Mocked | `gpu_nvidia_no_driver` | CPU transcoding; `setup.sh` names what is missing |
| NVIDIA, driver but no toolkit, or Docker not reachable | Mocked | `gpu_nvidia_no_runtime`, `gpu_nvidia_docker_down` | CPU transcoding; `setup.sh` says which |
| NVIDIA, no `lspci` | Mocked | `gpu_no_lspci` | Found from `/sys`, shown with its PCI ids. Picked when the driver and runtime are there |
| virtio-gpu (VM) | Mocked | `gpu_virtio` | CPU transcoding; both scripts say the adapter has no video encoder |
| QEMU standard VGA | Mocked | `gpu_bochs` | CPU transcoding; as above |
| ASPEED (server BMC) | Mocked | `gpu_aspeed` | CPU transcoding; as above |
| No GPU | Mocked | `baseline` | CPU transcoding. Detection only |
| No `/dev/dri/by-path` | Mocked | `gpu_no_by_path` | CPU transcoding; the node is shown, never written to `.env` |
| Render group: `render`, `video`, none | Mocked | `gpu_no_render_group`, `gpu_video_group_only`, `gpu_no_group_no_node` | |

## Storage

| Layout | Level | Run / case | Notes |
|---|---|---|---|
| One ext4 disk, configs and media together | Physical | `2026.10.1` | Imports are hardlinks (link count 2) |
| Free space warnings | Mocked | `disk_ok`, `disk_tight`, `disk_full`, `disk_below_10`, `disk_edge_10`, `disk_starter_only`, `disk_edge_25`, `disk_below_50`, `disk_edge_50`, `disk_gb_not_gib`, `disk_gb_edge` | Thresholds and the filesystem name only. GB are decimal, rounded down. The image sizes they quote (starter set about 4 GB, every service about 17 GB) were measured on a default Docker 29 install, 2026-11-06, after `2026.10.1`. Nothing else about xfs or btrfs is tested |
| Images on another filesystem than the install folder | Virtualized; Mocked | 2026-11-06, after `2026.10.1`; `disk_images_elsewhere`, `disk_images_containerd_root`, `disk_images_containerd_default`, `disk_images_classic`, `disk_images_docker_down`, `disk_images_docker_absent`, `disk_images_rootless`, `disk_images_not_here` | `doctor.sh` asks `docker info` where images go (containerd's root for Docker 29's default store, Docker Root Dir for the older one) and judges the free space there. Run with the install folder on a second filesystem, with each store, and with the image folder moved onto it. Docker stopped: said so, judged on the install folder. Rootless: not read, said so |
| Downloads and library on separate disks | Untested | — | Hardlinks can't cross filesystems; imports become copies |
| exFAT, NTFS, FAT32 media disks | Untested | — | No hardlinks, no Unix ownership |
| Read-only or missing folders | Untested | — | |

## Docker

| Setup | Level | Run / case | Notes |
|---|---|---|---|
| Docker Engine, rootful, Compose plugin | Physical | `2026.10.1` | |
| Not installed; daemon down; user not in `docker` group | Mocked | `docker_absent`, `docker_down_not_in_group`, `docker_down_in_group`, `docker_down_rerun`, `docker_absent_rerun` | `doctor.sh` reports each as a blocker. `setup.sh` writes a first install with a warning in the same words, says container names and the network name were not checked, and asks for a re-run once Docker answers. A re-run with Docker installed but not reachable is refused and writes nothing: the install's own ports would look taken and move |
| Distro `docker.io` without the Compose plugin | Virtualized (Debian 12); Mocked | 2026-11-06, after `2026.10.1`; `docker_no_compose`, `docker_down_no_compose` | `doctor.sh` reports the missing plugin as a blocker. `setup.sh` warns in the same words before its `docker compose` steps, and still writes the config. Docker 20.10.24 from Debian, then the plugin installed by hand as Docker's Compose page describes (5.6.0): the default services started from that config without re-running `setup.sh` |
| Rootless | Mocked | `docker_rootless` | Detection only. Deploy Untested |

## Other detection

| Item | Level | Run / case | Notes |
|---|---|---|---|
| Memory | Virtualized (2 and 3 GiB); Mocked | 2026-11-06, after `2026.10.1`; `vm_ubuntu_2gib`, `vm_ubuntu_3gib`, `mem_2gb`, `mem_4gb`, `mem_8gb`, `mem_16gb`, `mem_edge_4`, `mem_below_edge_4`, `mem_edge_8`, `mem_below_edge_8`, `mem_unreadable`, `capture_maintainer_laptop` | Shown to one decimal as the kernel reports it, a little under what is installed. "Under 4 GiB" below 3.5 GiB, "tight" below 7.0 GiB, so 4 and 8 GiB machines get what the README says. VMs given 2 and 3 GiB read 1.9 and 2.8 GiB; the 4 and 8 GiB values are typical ones, not run |
| CPU count | Virtualized (1 and 2 vCPUs); Mocked | 2026-11-06, after `2026.10.1`; `vm_ubuntu_2gib`, `vm_ubuntu_3gib`, `cpu_amd` | Logical CPUs (`nproc`): threads on real hardware, vCPUs in a VM, fewer when a cpuset limits the process. Display only |
| Ports, with `ss` or `netstat` | Virtualized (Ubuntu 26.04, defaults running); Mocked | 2026-11-06, after `2026.10.1`; `ports_container`, `ports_ours`, `ports_ours_other_service`, `ports_dns`, `ports_netstat_only`, `ports_doctor_own`, `ports_doctor_foreign`, `ports_doctor_both`, `ports_doctor_no_env`, `ports_doctor_env_project`, `ports_doctor_shell_project`, `ports_doctor_own_pihole` | A taken port moves to the next free one. On a running install, `doctor.sh` reports a port held by the install's own container (its compose project) as its own, not a clash; another container or a process still warns |
| Ports, with neither tool | Mocked | `ports_no_tools`, `ports_no_tools_rerun`, `ports_no_tools_fedora` | Not checked, and both scripts say so. `setup.sh` keeps the last run's port, or the default; a taken one makes `docker compose up` fail with "port is already allocated" or "address already in use" |
| Timezone without `timedatectl` | Mocked | `tz_file`, `tz_ctl_fails`, `tz_localtime`, `tz_localtime_relative`, `tz_localtime_file`, `tz_none` | Falls back to `/etc/timezone`, then the `/etc/localtime` link, then UTC |
| Missing `curl`, `git`, `crontab`, `lspci`, `ss`, `timedatectl` | Mocked | `tools_debian`, `tools_fedora`, `tools_arch`, `tools_installed_doctor`, `tools_update_check`, `tools_update`, `tools_update_schedule`, `tools_next_no_crontab`, `tools_next_crontab_empty`, `tools_next_crontab_scheduled`, `tools_next_update_off` | `doctor.sh` lists each one and what doesn't work without it; `update.sh` names the missing tool. Without `crontab`, `setup.sh`'s last steps say cron is needed before `./update.sh --schedule`, and how to install it |
| Install hints | Mocked | `tools_debian`, `tools_debian_plain`, `tools_ubuntu_derivative`, `tools_fedora`, `tools_rocky`, `tools_arch`, `tools_manjaro`, `tools_other_distro`, `tools_no_os_release`, `tools_update_schedule_arch`, `tools_next_no_crontab_fedora` | `apt`, `dnf` or `pacman` from `/etc/os-release` (`ID`, `ID_LIKE`); any other distro gets the tool names only. Package names checked against each distro's package search, 2026-11-06. On Fedora and Arch the cron hint also starts the service |
| User and group ids other than 1000 | Mocked | `user_ids` | |

---

## Where the scripts disagree with this page

| Script says | This page |
|---|---|
| `doctor.sh`, ARM64: "a few are x86-only" | All pinned images publish `linux/arm64` |

Both scripts label the NVIDIA and AMD paths "NOT maintainer-tested";
`doctor.sh` labels rootless Docker too. Neither labels ARM64.
