# Anteiku

A self-hosted starter kit for people who have never run one — a working
Docker stack you can boot, with the reasoning written down next to it,
and a setup script that reads your machine and adapts to it.

Built from a real single-machine homelab, with the mistakes left in on
purpose. Most guides show you the happy path. The failures are the
useful part.

```bash
git clone <repo-url> anteiku && cd anteiku
./doctor.sh      # read-only. what you have, what will work, what will bite
./setup.sh       # pick your services, write your config
docker compose up -d
```

---

## Scope — what this is NOT

**This project does not provide, bundle, recommend or link to any indexers,
trackers, sources or content of any kind.** None. Prowlarr installs empty
and stays empty until you configure it yourself.

This is infrastructure: it manages, organises, transcodes and serves a
library that **you supply**. What you put in it is your decision and your
responsibility alone, under the laws that apply to you. That is nothing to
do with this project and we will not help with it.

There are plenty of legitimate ways to fill a library, and they are what
this kit is built for:

- **Rip discs you already own** — DVDs, Blu-rays, CDs on your shelf
- **DRM-free stores** — Bandcamp, Humble, GOG, Blu-ray with digital copies
- **Public domain and open archives** — Internet Archive, Project Gutenberg,
  Librivox, open-access film restorations
- **Your own files** — photos, home video, music you recorded, documents
- **Creative Commons and freely licensed media**

Home recording and disc-ripping rules differ by country. Check yours.

## What it gives you

| | |
|---|---|
| `doctor.sh` | Read-only survey: CPU, RAM, GPU, render nodes, Docker, ports, disk. Writes nothing. Prints no secrets, so it's safe to paste into an issue. |
| `setup.sh` | Interactive checklist. Detects clashes, shifts ports, writes `.env`. `--dry-run` shows every decision and writes nothing. |
| `stacks/*.yaml` | The services, templated. Every value is a `${VAR}`. |
| `scripts/backup.sh` | Backs up configs, secrets and databases — not your media. Warns if the destination is the same disk. |
| `docs/backups.md` | **Read before you put anything you care about on here.** |
| `scripts/ntfy-setup.sh` | Creates the ntfy user and topic so backups and uptime alerts reach your phone. |
| `scripts/kuma-bootstrap.sh` | Creates an uptime monitor for every service you installed, grouped sensibly. Re-runnable. |
| `stacks/*.md` | One guide per stack: what each service is for, setup order, the traps. |
| `docs/remote-access.md` | Getting in from outside without exposing anything. Read before forwarding any port. |
| `ports.md` | **Generated.** Every service you installed, the port it actually got, and the name other containers reach it by. Rewritten each `setup.sh` run. |

Nothing is started for you. `setup.sh` writes config and stops; you read it,
then run compose yourself.

**Picking services** is a full-screen list: `↑` `↓` to move, `space` to
tick, `a` / `n` for all or none, `enter` to continue, `q` to quit without
writing anything. It explains whatever is highlighted at the bottom of the
screen. On a terminal that cannot draw a full screen — or with
`./setup.sh --plain` — you get a numbered menu instead.

**Adding services later is safe.** Re-run `./setup.sh`: anything already
installed is shown as locked and cannot be unticked by accident, so you
can only add. Its ports, paths and passwords are kept exactly as they
are, and `docker compose up -d` starts just the new ones. To change or
remove something you already run, `./setup.sh --reconfigure` unlocks
it — after spelling out what can break and asking you to type
`reconfigure`. It never deletes a container or its data; it prints the
exact command for you to run.

**If a port you need is already taken**, setup.sh walks upward one port at a
time until it finds a free one — 5055 busy becomes 5056, and so on — then
records what each service actually got in `ports.md`. Nothing fails and
nothing silently collides; the guides tell you to trust `ports.md` over
their own default tables.

## Status

Early. What is tested, and how:

| Stack | Services | Verified |
|---|---|---|
| `arr` | Prowlarr, Byparr, qBittorrent, Sonarr, Radarr, Lidarr, LazyLibrarian, Bazarr, Seerr | root folders, download client, Prowlarr sync, hardlink import |
| `media` | Jellyfin, Navidrome, Kavita | Intel Quick Sync hardware encode, accounts created |
| `infra` | Nginx Proxy Manager, Pi-hole, Diun | hostname → Pi-hole → NPM → correct container |
| `monitoring` | Uptime Kuma, Dozzle | a monitor auto-created per service, all reporting up |
| `photos` | Immich (+ optional ML) | photo upload, database dropped and restored |
| `extras` | ntfy, Vaultwarden | backup alerts delivered; signups closed on re-run |
| `books` | Calibre-Web-Automated | epub ingested into the library, served over OPDS |

All 24 containers were brought up **together** from a fresh copy of this
repo, with `setup.sh` run as a new user would, on x86_64 / Ubuntu 26.04
with an Intel iGPU and an NVIDIA dGPU — then re-run three more times to
confirm a re-run changes nothing.

**Hardware paths:** Intel iGPU is tested on real hardware. NVIDIA, AMD,
ARM64 and rootless Docker are written from documented behaviour and are
**not** maintainer-tested. The scripts tell you when you are on an
unverified path rather than pretending otherwise.

## Requirements

- Linux (x86_64 tested; ARM64 partly works, 32-bit ARM does not)
- Docker Engine + Compose v2 plugin
- 4 GiB RAM minimum, 8+ comfortable
- Somewhere to put a library

Run `./doctor.sh` and it will tell you which of these you are missing.

## Back it up

A homelab is one second-hand disk away from losing everything. Configs
and secrets are small and precious; your media library is large and
re-obtainable. `scripts/backup.sh` backs up the first kind, and
`docs/backups.md` covers scheduling and — the part people skip — how to
verify a restore works.

## Getting to it from outside

When you want Jellyfin on a train, **do not forward ports on your
router** — that publishes the service to the whole internet, and
scanners find it within hours. A mesh VPN puts your phone on your home
network from anywhere with nothing exposed, in about ten minutes, and
can make your local hostnames work remotely too.

See [`docs/remote-access.md`](docs/remote-access.md).

## Two rules worth knowing before you start

**1. Downloads and library must be on one filesystem.** Every service
mounts a single `${MEDIA_ROOT}` at `/data`. Imports then become hardlinks:
instant, no extra disk. Split them across two mounts and every import
silently becomes a full copy — double the disk, slow imports, and a drive
that fills for no visible reason. This catches almost everyone once.

**2. You probably don't need a GPU.** If your TV plays the file as-is, it
direct-plays and nothing transcodes. Hardware encoding matters for several
simultaneous streams or remote viewing over thin upload. `doctor.sh` tells
you what you have and whether it's worth wiring up.

## Checking your changes

If you change anything here, run this before you commit:

```bash
./scripts/check.sh          # about 30 seconds
./scripts/check.sh --tui    # also drives the picker in a real terminal
```

It lints every script, parses the Python and the compose files, checks
every combination of stacks, runs `setup.sh` in a temporary copy (first
run, re-runs, dry runs) and fails if a password reaches the output. It also
scans for keys, tokens and image metadata. It starts no containers and
changes nothing in your checkout. It needs Docker and git; shellcheck and
Python come from containers if you don't have them.

`LEAK_PATTERNS_FILE=~/my-patterns.txt ./scripts/check.sh` adds your own
patterns (your name, your LAN), one regex per line. Keep that file outside
the repo.

## License

MIT. See `LICENSE`.
