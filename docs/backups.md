# Backups

**Not optional. Do this before you put anything you care about on here.**

A homelab is one second-hand disk away from losing everything on it.
That is fine — disks are cheap and expected to fail — but only if you
planned for it.

---

## What is worth backing up

Not everything. The split that matters:

| | Size | If you lose it |
|---|---|---|
| **Configs** (`appdata/`) | small — MBs | Weeks of setup. Every indexer, library, user, tweak |
| **Secrets** (`.env`) | tiny | Every password and API key |
| **Your own files** (photos, documents) | large | **Gone forever** |
| Media library | huge | Annoying. Re-obtainable |

So: back up configs, secrets and your own files. Do **not** back up
your media library — it is enormous and you can get it again. Backing
it up is how people conclude backups are impractical and then do none.

`scripts/backup.sh` covers the first two rows, plus a dump of every
database. It does **not** copy your photo files (`PHOTOS_LOCATION`):
they are large, and a fresh 200 GB archive each run fills any disk.
Copy them yourself, with one command; see [Your photos](#your-photos).

---

## Run one

```bash
./scripts/backup.sh --dry-run /mnt/backup      # show the plan
./scripts/backup.sh /mnt/backup                # do it
```

Or set `BACKUP_DEST` in `.env` and pass nothing.

What it produces, in a dated directory:

| File | Contents |
|---|---|
| `appdata-configs.tar.gz` | every installed service's config, caches excluded |
| `stack.tar.gz` | compose files + `.env`, mode 600 |
| `<service>-db.sql.gz` | a proper dump per database |

It exits non-zero if anything failed, so cron can act on it.

---

## Your photos

`backup.sh` dumps Immich's database: albums, people, shares, who
uploaded what. The photos and videos live in `PHOTOS_LOCATION`, and
they are not in that backup. You need both. The database without the
files is a timeline of broken images; the files without the database
lose every album and person.

Copy the folder with `rsync`, after `backup.sh` (database first, then
files, so the copy holds every file the dump knows about). After the
first run it only copies what is new:

```bash
rsync -a /path/to/PHOTOS_LOCATION/ /mnt/backup/photos/
```

- The trailing `/` on the source matters. Without it you get
  `photos/photos/`.
- No `--delete`, on purpose: a photo deleted on the server stays in the
  copy, so a mistake is not mirrored. Tidy the copy by hand now and then.
- Short on space? `--exclude=thumbs --exclude=encoded-video` skips what
  Immich can regenerate. After a restore, run the thumbnail and
  transcode jobs again (Administration → Jobs).
- To schedule it, add a line under `backup-cron.sh` in your crontab,
  an hour later. It does not notify you; look at the copy now and then.
  ```
  0 4 * * 0 rsync -a /path/to/PHOTOS_LOCATION/ /mnt/backup/photos/
  ```

Ubuntu's standard install includes `rsync`; elsewhere, install it from
your package manager.

---

## Where to put it

**This is the decision that actually determines whether you are backed
up.** The script checks and warns, because it is the easiest thing to
get wrong.

| Destination | Protects against |
|---|---|
| Same disk | Deleting a file, a bad config, a failed upgrade |
| **Different disk, same machine** | All of the above **plus the disk dying** |
| Different machine / NAS | Plus the machine dying |
| Off-site or cloud | Plus fire, flood, theft |

A backup on the same physical disk as the data is not a backup for the
most likely failure — that disk failing. It still has real value against
mistakes, which are more common than hardware death. Just do not mistake
it for being safe.

**The honest advice:** a £30 USB disk gets you most of the way. The
common pattern is nightly to a second local disk, plus a weekly
encrypted copy somewhere off-site.

### The 3-2-1 rule, plainly

Three copies, on two kinds of media, one off-site. For a homelab that
usually means: the live data, a local backup disk, and a cloud or
friend's-house copy. If that sounds like too much, start with two
copies. Two beats one by an enormous margin; three is refinement.

---

## Schedule it

A backup you run manually is a backup you stop running.

```bash
crontab -e
# weekly, Sunday 03:00
0 3 * * 0 /full/path/to/anteiku/scripts/backup-cron.sh
```

Use the **full absolute path** — cron has almost no environment and will
not find a relative one.

### Silence is the enemy

`backup-cron.sh` notifies on failure **and on success**, which sounds
like noise and is not.

A backup that silently stopped running six weeks ago looks exactly like
one that is working perfectly: you hear nothing either way. If success
is also announced, a missing Sunday message is itself the alarm.

Set `NTFY_URL` and `NTFY_TOPIC` in `.env` to get phone pushes. Without
them it still runs and logs to `backup-logs/` in this folder (set
`BACKUP_LOG_DIR` in `.env` to log elsewhere); it just cannot tell you.

---

## Test the restore. Really.

**An untested backup is not a backup — it is a hope with a filename.**

The common failure is not "the backup did not run". It is that it ran
for a year and quietly never included the one directory that mattered,
because it was root-owned and the error was hidden.

Test it. Five minutes, once:

```bash
# 1. fingerprint something you can check afterwards
docker compose exec sonarr \
  sh -c 'grep -o "<ApiKey>[^<]*" /config/config.xml'

# 2. stop the service and move its config aside (do not delete it yet)
docker compose stop sonarr
mv appdata/sonarr appdata/sonarr.old

# 3. restore just that service from the archive
tar xzf /mnt/backup/2026-10-28/appdata-configs.tar.gz -C appdata sonarr

# 4. start it and check the fingerprint matches
docker compose start sonarr
docker compose exec sonarr \
  sh -c 'grep -o "<ApiKey>[^<]*" /config/config.xml'

# 5. same key, service healthy? delete the .old copy. Different? you
#    just found out while it was safe to find out.
```

Do this once after setting backups up, and again after any change to
what you run. This exact procedure is how the script in this repo was
verified.

### Full disaster recovery

Rebuilding from nothing:

```bash
# 1. install Docker, clone this repo
# 2. restore the stack (brings back .env with all your secrets)
tar xzf /mnt/backup/2026-10-28/stack.tar.gz -C anteiku
# 3. restore configs
tar xzf /mnt/backup/2026-10-28/appdata-configs.tar.gz -C anteiku/appdata
# 4. put the photo files back (from your own copy, see "Your photos")
rsync -a /mnt/backup/photos/ /path/to/PHOTOS_LOCATION/
# 5. restore databases (below), then bring everything up
cd anteiku && docker compose up -d
```

### Restoring a database (Immich)

Tested as written, on the pinned Immich (v3.3.5): database dropped to
zero tables, restored from a `backup.sh` dump with no errors, and a fresh
dump of the result matched the original.

```bash
# 1. stop the app, keep the database container running
docker compose stop immich-server

# 2. replace the database with an empty one
docker compose exec immich-db psql -U immich -d postgres -c 'DROP DATABASE immich;'
docker compose exec immich-db psql -U immich -d postgres -c 'CREATE DATABASE immich;'

# 3. load the dump
gzip -dc /mnt/backup/2026-10-28/immich-db.sql.gz \
  | docker compose exec -T immich-db psql -U immich -d immich -q

# 4. start the app and log in - albums, users and shares should be back
docker compose start immich-server
```

If step 3 prints any `ERROR` line, the restore is incomplete, even
though `psql` exits 0. Dumps from older Immich versions can need an extra
`search_path` step; it is in Immich's own
[backup and restore guide](https://docs.immich.app/administration/backup-and-restore).

You do **not** need the original database password to restore — the
dump is plain SQL. What you *do* need is the photo files under
`PHOTOS_LOCATION` back in place first: the database knows about each
photo, but the photos themselves live on disk, and `backup.sh` does not
copy them. Restore them from your own copy ([Your photos](#your-photos))
before step 4.

---

## Databases are different

**Never back up a running database by copying its files.** A tar of a
live database captures it mid-write and produces an archive that looks
fine and restores into corruption.

The script runs `pg_dump` instead, which produces a consistent snapshot
while the service keeps running.

It also judges each dump by how many `CREATE TABLE` statements it
contains, not by file size. A 400-byte dump of an empty database is
correct; a 400-byte dump of a full one is a catastrophe — and a size
check passes both.

---

## Root-owned files

Several services write config as root. Without root, `tar` skips those
files — and historically it did so **silently**, which is how people
discover at restore time that their backup was incomplete.

The script uses `sudo -n` (never prompts, so cron cannot hang) and says
loudly when it does not have it. To grant just what is needed:

```bash
echo "$USER ALL=(root) NOPASSWD: /usr/bin/tar" | sudo tee /etc/sudoers.d/backup
```

That allows `tar` as root and nothing else.

---

## What is deliberately excluded

Caches and regenerable data, because they dominate the archive size and
rebuild themselves:

- `jellyfin/config/data/metadata` — re-fetchable artwork, often gigabytes
- `jellyfin/config/cache`, transcode scratch
- `immich/model-cache` — re-downloadable ML models
- `*/logs/*.log`

On a real system this is the difference between a 2.4 GB nightly and one
well under 1 GB. Across 30 dailies, 72 GB versus 20 GB.

---

## Traps

**Media is not backed up, on purpose.** If you have media you genuinely
cannot replace — your own recordings, ripped discs you no longer own —
that is irreplaceable data, not media. Copy it somewhere separately.

**`.env` contains every secret.** `stack.tar.gz` is mode 600 for that
reason. Think before putting it on a shared drive, and encrypt it before
any cloud.

**Retention cuts both ways.** 30 days of dailies is useless against
corruption you only notice after 40 days. Keep a monthly that you never
rotate.

**Test after changing what you run.** A new service means a new config
directory, and possibly a new database the script does not know about
yet.

**Backups are not monitoring, and monitoring is not backups.** Uptime
Kuma tells you something is down. It does not tell you a backup has
been failing for a month — that is what the success notification is for.
