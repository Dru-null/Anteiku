# Changelog

Every release is a set of pinned versions that was brought up and
tested together, every service at once, on real hardware. Versions are
dates, `YEAR.MONTH.N`: `2026.10.0` is the first release of October
2026, `2026.10.1` the second.

Read **Action needed** before updating. Everything else is for
interest. How to update: [docs/updating.md](docs/updating.md).

---

## Unreleased

### Changed

- `doctor.sh` shows memory to one decimal and compares it in MiB: "Under
  4 GiB" below 3584 MiB, "tight" below 7168 MiB, so 4 and 8 GB machines
  get what the README says. It used to round down to whole GiB, and a
  4 GB machine read 3. The CPU count says "CPUs", not "cores".
- `doctor.sh`'s disk tiers fit what Docker 29 stores by default: under
  10 GB free is an error, 10 to 24 GB is enough for the starter set but
  not every service, 25 to 49 GB not for a library, 50 GB and up fine.
  It used to call 10 GB enough for every image.
- `update.sh` lists the images earlier releases left behind (no
  container uses them, neither this release nor the way back pins
  them), with their sizes and the `docker image rm` command, after an
  update and with `--check`. It removes nothing.
  [docs/updating.md](docs/updating.md#old-images)
- `doctor.sh` checks free space where Docker keeps images, not in the
  install folder, and says so when it can't tell. Sizes are GB, rounded
  down; they were GiB, rounded up.
- `setup.sh` says when Docker is missing or not reachable, and what it
  couldn't check then. A re-run of an install in that state stops and
  writes nothing: its own ports would have moved.
- `doctor.sh` and `setup.sh` call it "the Compose plugin", not "Compose
  v2": the plugin's own versions are 5.x now.
- Without cron, `setup.sh`'s last step says to install it before
  `./update.sh --schedule`, with the command for your distro. It used to
  offer the command, which then failed with "crontab not found".
- `doctor.sh` and `setup.sh` warn about the media disk's filesystem:
  exFAT and FAT have no hardlinks and no owners, NTFS through ntfs-3g
  no owners. Where `chown` can't work they give the `uid=`/`gid=` mount
  option instead. `doctor.sh` reads `MEDIA_ROOT` from the shell or
  `.env`. [stacks/arr.md](stacks/arr.md#traps)
- `setup.sh` names each folder it couldn't create, with the reason, and
  no longer says they all exist. Its "different filesystems" note
  compares the folders themselves, so a media root that is its own
  mount counts.
- On a full disk `setup.sh` stops and leaves `.env` as it was. A re-run
  used to replace it with an empty file, passwords included.
- `--help` prints the script's header and nothing else, from any folder.
  `setup.sh --help` used to end in three lines of code, and every
  script's help printed only an error when run from another folder.

---

## 2026.10.1 — 2026-10-30

Adds `update.sh`, removes Diun, and moves two pins.

### Action needed

1. **Update by hand this once.** 2026.10.0 has no `update.sh`; this
   release adds it. From the install folder:

   ```bash
   ./scripts/backup.sh && git fetch --tags && git merge --ff-only 2026.10.1 && ./setup.sh && docker compose pull && docker compose up -d
   ```

   `backup.sh` needs a destination: `BACKUP_DEST` in `.env`, or pass
   one (`./scripts/backup.sh /mnt/backup-drive`). `setup.sh` asks how
   to handle new releases; for the weekly check, then run
   `./update.sh --schedule`. Later releases: `./update.sh`.
2. **Diun is removed.** If you had it, the `./setup.sh` step above
   drops it from your selection and prints the `docker rm -f` command
   for its container (usually `<STACK_PREFIX>diun`) and where its data
   is (`appdata/diun`). Nothing is deleted for you; delete the folder
   if you don't want it. Why: [docs/updating.md](docs/updating.md#diun).

### Changed

- `update.sh`: checks for a newer release, shows its changelog (Action
  needed first), backs up, moves to the release tag, re-runs
  `setup.sh --yes`, pulls and restarts. `--schedule` adds one weekly
  crontab line. See [docs/updating.md](docs/updating.md).
- `setup.sh` asks how to handle new releases: notify (default),
  automatic, or off. It says when an installed service is no longer
  part of Anteiku, and how to finish removing it.
- `doctor.sh` shows the release you are on and whether a newer one
  exists.
- `backup.sh` counts config folders per service, and `--dry-run` no
  longer creates the destination. It says plainly that photo files are
  not backed up; [docs/backups.md](docs/backups.md) has a one-line copy
  for them.
- Diun removed: with every version pinned it stayed quiet, or pointed
  at versions not tested together.

### Versions

| Service | 2026.10.0 | 2026.10.1 |
|---|---|---|
| LazyLibrarian | `8c70ea4d-ls386` | `d7e0cf3d-ls386` |
| ntfy | `v2.34.0` | `v2.35.0` |
| Diun | `4.33.1` | removed |

Everything else is unchanged. Tested on x86_64, Ubuntu 26.04, Intel
UHD 630 and NVIDIA GTX 1050.

---

## 2026.10.0 — 2026-10-30

First release.

### Action needed

None. This is the first release.

### Included

21 services in 7 stacks, `setup.sh` and `doctor.sh`, Intel, NVIDIA and
AMD GPU overrides (Intel tested), and scripts for backups, Uptime Kuma
monitors and ntfy.

### Versions

| Service | Version |
|---|---|
| Prowlarr | `2.7.0.5723-ls166` |
| qBittorrent | `release-5.3.0` |
| Sonarr | `4.0.20.3014-ls1` |
| Radarr | `6.4.4.10685-ls324` |
| Lidarr | `3.1.6.5079-ls46` |
| LazyLibrarian | `8c70ea4d-ls386` |
| Bazarr | `v1.6.2-ls370` |
| Seerr | `v3.5.1` |
| Jellyfin | `12.4ubu2604-ls57` |
| Navidrome | `0.64.2` |
| Kavita | `0.9.1` |
| Nginx Proxy Manager | `2.16.0` |
| Pi-hole | `2026.10.0` |
| Diun | `4.33.1` |
| Uptime Kuma | `1.23.17` |
| Dozzle | `v11.4.0` |
| Immich server + machine learning | `v3.3.5` |
| Immich Postgres | `14-vectorchord0.4.3-pgvectors0.2.0` |
| Immich Valkey | `9.1.3` |
| ntfy | `v2.34.0` |
| Vaultwarden | `1.37.4` |
| Calibre-Web Automated | `v4.0.8` |

Tested on x86_64, Ubuntu 26.04, Intel UHD 630 and NVIDIA GTX 1050.
