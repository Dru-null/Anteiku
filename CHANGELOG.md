# Changelog

Every release is a set of pinned versions that was brought up and
tested together, every service at once, on real hardware. Versions are
dates, `YEAR.MONTH.N`: `2026.10.0` is the first release of October
2026, `2026.10.1` the second.

Read **Action needed** before updating. Everything else is for
interest. How to update: [docs/updating.md](docs/updating.md).

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
