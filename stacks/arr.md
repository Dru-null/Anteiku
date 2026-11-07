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
- Settings → Download Clients → add qBittorrent, host `qbittorrent`, port
  `8181` (the default; use the "Inside Docker" port from `ports.md`)

> Use the **container name**, not the host IP. Containers talk to each other
> on the compose network, so `qbittorrent:8181` works; a LAN IP is a detour
> that breaks the moment your IP changes. qBittorrent listens on the same
> port inside Docker as the one you browse to (see Traps), so if `setup.sh`
> moved it, the internal port moved too. `ports.md` lists both.

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
docker compose exec sonarr curl -sI http://qbittorrent:8181   # your qBittorrent port

# hardlinks working? link count 2 means yes, 1 means it copied:
find ${MEDIA_ROOT}/series -type f -links +1 | head
```

That last one is worth running early. Catching a broken path contract on
file three is much better than on file three thousand.

## Traps

**qBittorrent answers "Unauthorized" (401) to a browser** when the port in
the address isn't the one it listens on. It checks the request's `Host`
header against its own port, so with Docker publishing host 8181 to 8080
inside, every page is refused and its log says `Invalid Host header, port
mismatch`. That is why this stack runs it on the same port inside and out
(`WEBUI_PORTS` in `arr.yaml`). The cost: if its host port changes, the
address other containers use changes with it, and Sonarr and Radarr keep
the old one until you edit their download client. `setup.sh` warns when
that happens.

**qBittorrent asks your router to forward a port, unless told not to.**
Its UPnP/NAT-PMP setting is on out of the box. On this stack's own
Docker network the request never reaches the router (tested: nothing
left the machine), but with `network_mode: host` it does, and your
router opens a port nobody decided to open. This repo forwards no
ports, so `setup.sh` turns it off before the first start
(`PortForwardingEnabled=false` in `qBittorrent.conf`). It never edits a
config that already exists, so an install from before this change keeps
qBittorrent's default; `setup.sh` says which one you have. To check or
change it: Options → Connection → "Use UPnP / NAT-PMP port forwarding
from my router".

qBittorrent's own log (`qbittorrent/data/logs/qbittorrent.log` in your
`APPDATA` folder) also records the public IP it learns (`Detected external IP`). Read it
before you paste it anywhere. `docker compose logs qbittorrent` doesn't
show those lines.

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

**exFAT and FAT disks have no hardlinks and no owners.** Every import is a
full copy, and the `chown` above fails, even with `sudo`: every file
belongs to whoever mounted the disk. Mount it as your user instead (the
same options go in its `/etc/fstab` line):

```bash
sudo mount -o uid=1000,gid=1000 /dev/sdX1 /path/to/your/media    # your PUID:PGID
```

NTFS depends on the driver `df -T` names. `ntfs3` (the kernel's) kept
hardlinks and owners in our tests. `fuseblk` (ntfs-3g) keeps hardlinks,
but `chown` changes nothing: mount it with `uid=`/`gid=` as above. Debian
12's kernel has no `ntfs3`. For a library, a Linux filesystem (ext4, xfs,
btrfs) is the safe choice; reformatting erases the disk. `doctor.sh` and
`setup.sh` name the filesystem and warn.

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
