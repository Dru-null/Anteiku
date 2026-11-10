# Getting started

From "I have an old computer" to services running. If your machine
already runs Linux with Docker, skip to [The first run](#the-first-run).

What has been tested on what hardware is in
[compatibility.md](compatibility.md). This page doesn't repeat it.

---

## The machine

An old laptop, a mini-PC or a spare desktop. Nothing here needs a
server, a fast CPU or a graphics card.

| Memory | What it runs |
|---|---|
| 4 GB | The starter set (the six services ticked by default). Measured: about 1.3 GiB in use in a 3 GiB virtual machine, idle after the first start |
| 8 GB | Comfortable for most choices. A rule of thumb, not measured |
| 16 GB | Every service at once, with room to spare. Measured, below |

The maintainer's machine (Intel i5-9300H, 4 cores, 16 GB) runs every
Anteiku service, 22 containers, for each release check, next to 52
containers of its own. During the November 2026 check its free memory
never went below 1.7 GiB. Memory per service hasn't been measured one
by one.

Immich's machine learning is the one heavy part: it can keep every core
busy for hours. It is off by default; [photos](../stacks/photos.md#machine-learning-the-one-real-decision)
says what it costs.

`doctor.sh` reads your memory, CPU, disks and graphics and says what
fits. Linux reports a little less memory than is installed, and
`doctor.sh` allows for that.

### Disks

| What | Where | Why |
|---|---|---|
| `appdata/` (configs) and the databases | an SSD, if you have one | Small, but read and written all the time |
| Docker's images | where Docker keeps them, usually the system disk | 10 GB free for the starter set, 25 GB for every service |
| Media: downloads **and** library | one big disk, one filesystem | Imports are hardlinks: no second copy |

**Downloads and library on one filesystem.** Sonarr and Radarr move a
finished download into the library as a hardlink, which takes no extra
space. Across two disks it becomes a full copy, and the disk fills twice
as fast. Why and how: [the path contract](../stacks/arr.md#the-path-contract).

**A Linux filesystem for media** (ext4, xfs, btrfs). exFAT and FAT have
no hardlinks and no file owners; `doctor.sh` and `setup.sh` name the
filesystem and warn. Details: [arr Traps](../stacks/arr.md#traps).

**A used or "recertified" drive needs watching.** Second-hand disks are
fine for media you can get again, but check their health when they
arrive and now and then after. Anteiku doesn't watch disks, and Uptime
Kuma doesn't either. The usual tool is `smartmontools` (not part of
Anteiku, and not run by its tests):

```bash
sudo apt install --no-install-recommends smartmontools
sudo smartctl -H /dev/sdX     # the drive's own health verdict
sudo smartctl -a /dev/sdX     # everything it reports, sector counts included
```

`lsblk` shows which `/dev/sdX` is which. A drive that reports failing
health, by the manual's own words, "has already failed, or … is
predicting its own failure within the next 24 hours": copy your data
off. Its `smartd` service can check on a schedule; see
`man smartd.conf`.

### Graphics

You probably don't need a graphics card. Jellyfin only uses one to
convert video that a phone or TV can't play directly, and the CPU can do
that too: on the maintainer's i5-9300H, 60 seconds of 1080p took 15
seconds on the CPU and 6 on its integrated graphics. An Intel CPU with integrated graphics (Quick
Sync) is the best case: no drivers to add, a few watts, and `setup.sh`
picks it over a discrete card on purpose.
[media](../stacks/media.md#hardware-transcoding) explains the choice and
how to check it's really used.

### Power, noise, and laptops

A homelab runs day and night, so the machine's idle power and its fan
matter more than its top speed. A mini-PC or a laptop draws little and
is quiet; an old gaming desktop may not be.

**A laptop works as a server**, with two things to know:

- **Closing the lid suspends it**, and every service stops with it. On a
  laptop `doctor.sh`'s `Chassis` line says so, and a line below says what
  closing the lid does now. If it stops the machine, `doctor.sh` prints
  the commands that change it (a small logind setting, applied after a
  reboot). The first `./setup.sh` asks whether to show them;
  later runs say that `./doctor.sh` shows them. Neither script changes
  the setting itself. Once it's done, `doctor.sh` says closing the lid
  keeps it running.
- **Keep it plugged in.** On battery, every service stops when it runs
  out; `doctor.sh` warns when it's on battery. A battery kept full all
  the time may age faster: if the firmware or power settings offer a
  charge limit, use it.

**After a power cut.** A desktop or mini-PC usually has a firmware
setting to switch itself back on when power returns (names vary:
"Restore on AC power loss", "AC back", "Power on after power failure").
Some firmware can't: it has no such setting, and the machine stays off
until someone presses the button.

Wake-on-LAN is a partial workaround: another machine on your network
sends a packet and this one starts. It needs the firmware to support
it, an Ethernet cable (few wifi cards can), and on Ubuntu Server netplan's
`wakeonlan: true` for that interface ([netplan's
reference](https://netplan.readthedocs.io/en/stable/netplan-yaml/)). It
doesn't help when nothing is left running to send the packet, which is
exactly the case after a power cut. For that, a small UPS is the real
answer. Neither is tested by Anteiku.

---

## The operating system

**Ubuntu Server LTS or Debian.** Both are tested (see
[compatibility.md](compatibility.md)), both get security updates for
years, and every command in these guides is written for them. A desktop
edition spends memory on a screen nobody looks at.

The README walks through installing Ubuntu Server step by step:
[Start with a machine](../README.md#start-with-a-machine). The parts
that matter most:

- Tick **Install OpenSSH server** in the installer. You'll manage the
  machine from another computer: `ssh you@<its address>`.
- **Give it a fixed address.** Add a DHCP reservation for it in your
  router (it usually lives under DHCP, LAN or "address reservation").
  `hostname -I` shows its current address. Every bookmark, and later the
  DNS names, point at that address; if it changes, they all break.

### Docker

Install Docker Engine and the Compose plugin from Docker's own apt
repository, following the page for your distro:
[Ubuntu](https://docs.docker.com/engine/install/ubuntu/) or
[Debian](https://docs.docker.com/engine/install/debian/). Not the
`docker` snap, which only sees your home folder, and not the distro's
`docker.io` package (Debian 12's comes without the Compose plugin).

Then let your user run Docker, and **log out and back in** (a new SSH
session is enough). Group membership is read at login:

```bash
sudo usermod -aG docker $USER
```

Being in the `docker` group is [root-level
access](https://docs.docker.com/engine/install/linux-postinstall/).
Keep it to your own user. Check both, without `sudo`:

```bash
docker ps                # a header line, not a permission error
docker compose version   # the Compose plugin
```

---

## The first run

Nothing starts until you start it, in step 4.

**1. Clone it.** `sudo apt install git` first if `git --version` fails.

```bash
git clone https://github.com/dru-null/Anteiku.git anteiku && cd anteiku
```

**2. Read your machine.** `doctor.sh` changes nothing.

```bash
./doctor.sh
```

It ends with a summary: blockers first (fix those before going on), then
warnings (worth reading, not stopping for). Its output holds no
passwords, so it's safe to paste into an issue.

**3. Pick and write.** `setup.sh` shows a list of services with a
starter set ticked. Then it explains each decision (ports, paths, the
graphics card, updates) and writes `.env`, `ports.md` and the folders.
It starts nothing.

```bash
./setup.sh --dry-run     # every decision, nothing written
./setup.sh
```

On the first run it also asks how you want to hear about updates, and
on a laptop whether to show the lid commands. A re-run keeps your
answers, passwords and ports, and only adds services.

**4. Start it.**

```bash
docker compose up -d
docker compose ps        # what is running
```

The first start downloads every image, which takes a while. After it,
`setup.sh`'s last section lists what you'll see on first start that
looks wrong but isn't.

**5. Find your services.** `ports.md` has the address of each one.

```bash
cat ports.md
```

**6. Set them up, in this order.** Each guide has a setup order and a
Traps section. Read the traps: they're the mistakes that really
happened.

1. [arr](../stacks/arr.md): the download client, then Sonarr and Radarr
2. [media](../stacks/media.md): Jellyfin, pointed at the same library
3. Anything else you ticked: [photos](../stacks/photos.md),
   [books](../stacks/books.md), [extras](../stacks/extras.md)

To add a service later, run `./setup.sh` again.

---

## What next

In this order.

| Step | Why now | Guide |
|---|---|---|
| 1. Backups | Before you put anything you care about on it. A second-hand disk is one failure away from losing everything | [backups](backups.md) |
| 2. Notifications and monitoring | So you hear when something stops, instead of finding out weeks later | [extras](../stacks/extras.md) (ntfy), then [monitoring](../stacks/monitoring.md) |
| 3. Reverse proxy and DNS | `sonarr.home` instead of an address and a port. Optional; worth it once the basics are used | [infra](../stacks/infra.md) |
| 4. Remote access | Your services from outside, without opening your router | [remote access](remote-access.md) |

Never forward ports on your router to get at a service from outside.
[remote access](remote-access.md) says why, and what to do instead.

When a new release comes out: [updating](updating.md).
