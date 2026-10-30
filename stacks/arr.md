# arr — library management

Automates organising a media library: you tell it what you want, it
watches for it, files it correctly and keeps it tidy.

> **This stack ships no indexers and no sources.** Prowlarr starts empty.
> What you point it at is your decision and your responsibility. See
> "Scope" in the README.

## The services

> **Ports below are the defaults, and yours may differ.** If something on
> your machine already had one, `setup.sh` moved it to the next free port
> and recorded the real one in **`ports.md`**. That file is generated for
> your machine — trust it over this table and over any tutorial online.

| Service | Default port | What it does | Default |
|---|---|---|---|
| `prowlarr` | 9696 | Indexer manager. Define sources once, syncs to the rest | on |
| `qbittorrent` | 8181 | Download client | on |
| `sonarr` | 8989 | TV | on |
| `radarr` | 7878 | Movies | on |
| `seerr` | 5055 | Request UI for the household | on |
| `byparr` | 8191 | CAPTCHA solver some indexers need | off |
| `lidarr` | 8686 | Music | off |
| `lazylibrarian` | 5299 | Books and audiobooks | off |
| `bazarr` | 6767 | Subtitles | off |

Start with the five defaults. Add the rest once that works.

## The path contract

The single most important thing here.

```
host ${MEDIA_ROOT}  ->  container /data        (every service, same mount)

  /data/torrents    downloads land here
  /data/movies      Radarr library
  /data/series      Sonarr library
  /data/music       Lidarr library
  /data/books       LazyLibrarian library
```

One root, mounted identically everywhere. Importing a finished download is
then a **hardlink** — instant, no extra disk, original left intact for
seeding.

Break it — mount `/downloads` and `/media` separately, a common pattern in
older guides — and every import becomes a full copy. Twice the disk, slow
imports, and a drive that fills with no obvious cause. If you remember one
thing from this repo, remember this.

## Setup order

Order matters; each step depends on the one before.

Open each service at the address in `ports.md`. The ports named below are
the defaults; substitute yours if they moved.

**1. qBittorrent** — get the temporary password from the log:

```bash
docker compose logs qbittorrent | grep -i password
```

Log in (see `ports.md` for the address), change the password immediately.
Set the default save path to `/data/torrents`.

**Then set a seeding ratio limit** (Options → BitTorrent → Seeding Limits).
With no limit, nothing ever retires a finished torrent and the download
directory grows until the disk is full. Ask how we know.

**2. Prowlarr** — create the admin account. Add whatever indexers
you have decided to use. None are provided.

**3. Sonarr / Radarr** —

- Media Management → Root Folder → `/data/series` (Sonarr), `/data/movies` (Radarr)
- Settings → Download Clients → add qBittorrent, host `qbittorrent`, port `8080`

> Use the **container name and internal port**, not the host IP and published
> port. Containers talk to each other on the compose network, so
> `qbittorrent:8080` works; a LAN IP plus host port is a detour that breaks
> the moment your IP changes or a port moves. The internal port is often not
> the one you browse to — qBittorrent is `8080` inside whatever host port you
> use. `ports.md` lists both, side by side.

**4. Back to Prowlarr** — Settings → Apps → add Sonarr and Radarr
(`http://sonarr:8989`, `http://radarr:7878`) with each app's API key from
its Settings → General. Indexers now sync automatically.

**5. Seerr** — point it at Jellyfin, then Sonarr and Radarr. This is the
front door for everyone who isn't you.

**6. Bazarr / Lidarr / LazyLibrarian** — same pattern, only if you enabled them.

## Verifying it works

```bash
docker compose ps                  # all Up
docker compose logs -f sonarr      # follow one service

# containers can reach each other by name:
docker compose exec sonarr curl -sI http://qbittorrent:8080

# hardlinks working? link count 2 means yes, 1 means it copied:
find ${MEDIA_ROOT}/series -type f -links +1 | head
```

That last one is worth running early. Catching a broken path contract on
file three is much better than on file three thousand.

## Traps

**byparr and zombie processes.** `init: true` in the compose file is not
decorative. Each CAPTCHA solve leaves chromium children behind; with no
init process to reap them they pile up as zombies until the host cannot
fork at all. It is invisible in CPU, memory and healthchecks — look at the
PID column. Keep `init: true`.

**Check file type, not extension.** Anything that arrives from the internet
can be something other than what it claims. A padded `.exe` renamed to look
like an episode will be imported happily, and if it stays hardlinked in the
download client you will also redistribute it. Harmless on Linux, not
harmless on the Windows machine that opens the share.

```bash
# nothing executable should ever be in a media library:
find ${MEDIA_ROOT} -type f \( -iname '*.exe' -o -iname '*.scr' \
  -o -iname '*.bat' -o -iname '*.msi' \)

# extension proves nothing — check what the file actually is:
file -b "${MEDIA_ROOT}/series/Some Show/S01E01.mkv"
```

Target state for the first command is zero results.

**The disk fills faster than you think.** With no seeding ratio limit,
`/data/torrents` grows forever. Two things make it hard to measure:
sparse in-progress files report a far larger apparent size than they
occupy, and most of the directory is hardlinked into the library, so
deleting it frees nothing. Only files with link count 1 are reclaimable.

**Your media root must be owned by PUID:PGID.** Sonarr and Radarr run as
the user you set in `.env` and refuse any root folder they cannot write
to. The error is genuinely confusing — it names a user that does not exist
on your machine:

```
Folder '/data/series' is not writable by user 'abc'
```

`abc` is the in-container user, mapped to your `PUID`. Fix it on the host:

```bash
sudo chown -R 1000:1000 /path/to/your/media    # your PUID:PGID
```

This bites most often on a second-hand drive, or one that previously held
files written by root. `setup.sh` checks for it and warns before you start.

**Jellyseerr and Overseerr are discontinued.** Both were folded into
**Seerr** in February 2026, and most guides online still name the old
ones. If you run Jellyseerr today, the `latest` tag now literally reports
its version as `-deprecated`. Migrating is a one-line image change: point
Seerr at your existing config directory and it converts it on first
start. Back the directory up before you do.

**Seerr runs as a fixed uid 1000** and ignores `PUID`/`PGID`. On most
single-user Linux installs your user *is* 1000 and nothing needs doing.
If not, its config directory must be owned by `1000:1000`; `setup.sh`
tells you when this applies.

**"No indexers available" on a fresh install is expected.** Sonarr reports
it as an error on the Health page. It is correct: this repo ships no
indexers, so until you add your own there is nothing to search. Everything
else can be fully working and this warning will still show.

**Readarr is gone.** Retired in early 2026, metadata service dead. Old
guides still recommend it. LazyLibrarian is the maintained path.
