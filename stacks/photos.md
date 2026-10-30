# photos — Immich

Phone photo and video backup you host yourself. For most people this is
the whole reason to build a homelab: it is the one service that
genuinely replaces a paid cloud product feature-for-feature.

| Service | Default port | Default |
|---|---|---|
| `immich` (server + database + cache) | 2283 | off |
| `immich-ml` (face recognition, smart search) | — | **off** |

---

## Before anything else

**This will hold data you cannot replace.** Everything else in this
repo is re-obtainable; your photos are not.

Two rules:

1. **Do not delete anything off your phone** until you have a working
   backup of the server, and have tested restoring it. "It is on the
   server" means one copy on one second-hand disk. See
   [`../docs/backups.md`](../docs/backups.md).
2. `PHOTOS_LOCATION` is **separate from `MEDIA_ROOT`** on purpose, so
   you can back up photos without backing up 900 GB of films, and so a
   media-disk accident cannot take your photos with it.

---

## Machine learning: the one real decision

Immich can do face recognition, object detection and smart search
("show me photos of a dog on a beach"). It is genuinely impressive.

**It is also off by default here, deliberately.**

### What it costs

All of it runs on your **CPU** unless you have a supported GPU.

- The first scan of an existing library pegs **every core for hours** —
  days for tens of thousands of photos
- Everything else on the box feels slow while it runs. Jellyfin
  transcodes, *arr imports, the web UIs
- On a laptop or mini-PC: sustained full load, hot machine, loud fans
- The image is ~1.5 GB; the model cache adds a few GB more

This is the single most demanding thing in this repo. On a modest
machine the initial scan is not a background task you forget about —
it is the machine's whole job for a while.

### What you lose without it

Only this:

- Face recognition and grouping by person
- Object/scene detection
- Searching by what is *in* a photo

### What still works without it

Essentially everything people actually use day to day:

- Automatic phone backup, the entire point
- The timeline, albums, favourites, archive
- Sharing links and shared albums
- EXIF data, map view, search by **date, filename, camera, location**
- Multi-user accounts
- Video playback and thumbnails

### Choosing

| | |
|---|---|
| **Skip it** (default) | Recommended for a first install, a laptop, a mini-PC, or any machine also doing other work |
| **Add it** | You have cores to spare, or you specifically want face grouping and are happy to let it chew for a while |

You can add it later with no downside — re-run `./setup.sh` and select
`immich-ml`. Immich will then scan your existing library.

To tame it, raise or lower `IMMICH_ML_CPUS` in `.env`. It defaults to
`2.0`, which deliberately leaves cores for the rest of your homelab and
makes the scan take longer.

### If you skip it, do this one thing after first login

**Administration → Settings → Machine Learning → untick Enabled.**

Until you do, Immich keeps looking for a container you chose not to
install and logs:

```
Machine learning server became unhealthy
```

That is noise, not a fault — but it looks exactly like a fault, so turn
it off and keep your logs honest.

> **Advanced:** you *can* disable it without the UI by pointing
> `IMMICH_CONFIG_FILE` at a JSON file containing
> `{"machineLearning":{"enabled":false}}`. It works — and it also makes
> the **entire settings UI read-only**, which is a bad trade for one
> toggle. Verified: with a config file present the API reports
> `configFile: true` and settings can no longer be changed in the
> browser. Not recommended for a first install.

---

## Capacity

Phone libraries are bigger than people expect: **50–200 GB** is
ordinary, and a family's shared library can pass 500 GB.

```bash
df -h /path/to/PHOTOS_LOCATION
```

`setup.sh` warns if there is under 20 GB free. Point
`PHOTOS_LOCATION` at a disk with room before you back up a phone — the
one thing you do not want is to run out mid-upload.

**Put the database on your fastest disk.** It follows `${APPDATA}`, so
if that is on an SSD you are already right. A Postgres database on a
spinning disk is the single biggest reason an Immich install feels
sluggish.

---

## Setup

**1. Create the admin account.** Open Immich (see `ports.md`) — the
first account you create is the administrator.

**2. Turn off machine learning** if you did not install it (above).

**3. Install the phone app** — Immich, on iOS and Android. Point it at
your server's address, log in, and enable backup.

Use the hostname from `ports.md`. If you set up the reverse proxy,
`photos.home` works on your LAN; add Tailscale and the same address
works away from home too, which is what makes automatic backup actually
automatic. See [`../docs/remote-access.md`](../docs/remote-access.md).

**4. Choose what backs up** — all photos, or selected albums. Start
with one album to confirm the whole path works before committing
30,000 photos to it.

**5. Check it landed:**

```bash
find /path/to/PHOTOS_LOCATION/upload -type f | wc -l
```

---

## Traps

**Re-running `setup.sh` must not change your database password.** A
Postgres database only reads `POSTGRES_PASSWORD` when it first
initialises. Hand it a different one later and the server cannot log
in:

```
FATAL: password authentication failed   (code 28P01)
```

…while the data sits there, perfectly intact. `setup.sh` reuses
existing generated secrets from `.env` so this cannot happen. **If you
hit it anyway** — because you deleted `.env`, or edited the password —
the fix is to set `IMMICH_DB_PASSWORD` back to the original value, not
to wipe the database. Only wipe it if the original is genuinely gone,
and then restore from a dump.

**Back up with `pg_dump`, never by copying the files.** Immich's
metadata — albums, faces, shared links, who uploaded what — lives in
Postgres, not in the photo files. Copying a live database directory
produces an archive that looks fine and restores into corruption.
`scripts/backup.sh` dumps it properly and knows about Immich.

**The photo files alone are not a full backup.** You would keep the
images and lose every album, person and share. **Nor is the database
alone**, and that is all `backup.sh` takes: it does not copy
`PHOTOS_LOCATION`. Copy the files yourself with one `rsync` line; see
[Your photos](../docs/backups.md#your-photos).

**The Postgres image is version-locked to the server.** Immich ties
them together and the tag naming changes. Before a major upgrade:

```bash
curl -s https://raw.githubusercontent.com/immich-app/immich/main/docker/docker-compose.yml | grep image:
```

**First start takes a minute.** The server may log that the database is
still starting and retry. That is a startup race, it resolves itself,
and it is not a fault.

**Immich moves fast.** Releases are frequent and occasionally include
breaking changes. Read the release notes before jumping versions.
Anteiku releases move Immich only after testing it with everything
else, and `./update.sh --check` shows what a release needs from you.
