# Changelog

Every release is a set of pinned versions that was brought up and
tested together, every service at once, on real hardware. Versions are
dates, `YEAR.MONTH.N`: `2026.10.0` is the first release of October
2026, `2026.10.1` the second.

Read **Action needed** before updating. Everything else is for
interest. How to update: [docs/updating.md](docs/updating.md).

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
