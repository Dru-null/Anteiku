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
database. Its local backup does **not** copy your photo files
(`PHOTOS_LOCATION`): they are large, and a fresh 200 GB archive each
run fills any disk. Copy them yourself, with one command (see
[Your photos](#your-photos)), or let the
[encrypted off-site copy](#off-site-copy-encrypted) take them: it only
sends photos it doesn't have yet.

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
| `appdata-configs.tar.gz` | every installed service's config, caches and Immich's database files excluded |
| `stack.tar.gz` | the install folder (compose files, `.env`, scripts, logs) without `appdata`, media, photos or the backups; mode 600 |
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

## Off-site copy (encrypted)

Optional. Set it up and `backup.sh` ends each run by sending that
day's backup, and your photos, to a second place, **encrypted**:
[restic](https://restic.net), run from its official image (pinned, so
nothing is installed on your machine). That place is a folder (another
disk, a USB disk you take elsewhere, a NAS share mounted on this
machine) or cloud storage that speaks S3: see
[Cloud storage](#cloud-storage-s3) below. Other restic backends (SFTP,
B2's own protocol) are not supported.

Add to `.env` (`setup.sh` keeps these lines when you re-run it):

```bash
OFFSITE_REPO=/mnt/usb/anteiku-offsite
OFFSITE_PASSWORD=          # paste the output of: head -c 32 /dev/urandom | base64
# OFFSITE_PHOTOS=no        # leave your photos out (default: in)
```

The first run creates the repository there. Then:

- **What goes:** `stack.tar.gz` (your `.env`), the configs, the
  database dumps and your photo files, as one snapshot per run. Kept: 7
  daily, 5 weekly, 12 monthly; older ones are removed.
- **Encrypted:** nothing in that folder can be read without
  `OFFSITE_PASSWORD`. The local backup is not encrypted; keep it on a
  disk only you use.
- **Interrupted** (Ctrl-C, `kill`, a closed terminal), it stops restic
  and removes its temporary key files; the local backup is already
  written, and the next run sends the copy. An interrupted restore
  leaves part of the copy in its folder: empty that before running it
  again.
- `./scripts/backup.sh --local-only` skips the off-site copy.
  `update.sh` always skips it: an update needs the local backup, not an
  upload.

### Cloud storage (S3)

Most cloud storage providers speak S3, the protocol Amazon made and
others copied (Backblaze B2, Wasabi, AWS S3 itself, and more), so the
copy can go to a bucket there. Tested against an S3 server on a test
machine, not against any provider: **untested with each provider**.

1. At your provider, create a **private bucket** and a key that can
   read and write it (an *application key* or *access key*: two parts,
   an ID and a secret). Create the bucket yourself: `backup.sh` never
   does, so a typo in its name fails instead of starting a second copy
   somewhere else.
2. Add to `.env`, with the S3 endpoint from your provider's bucket page:

```bash
OFFSITE_REPO=s3:https://s3.your-provider.example/your-bucket
OFFSITE_PASSWORD=          # paste the output of: head -c 32 /dev/urandom | base64
OFFSITE_ACCESS_KEY_ID=     # the key's ID
OFFSITE_SECRET_ACCESS_KEY= # the key's secret
```

3. Run `./scripts/backup.sh`. The first run creates the repository in
   the bucket; then it works as with a folder (above).

- The keys reach restic as a file only you can read, never on a
  command line. `setup.sh` keeps them when you re-run it and hides them
  in its preview, like the password.
- A wrong key, a missing bucket or no connection: restic itself would
  retry for 15 minutes. `backup.sh` and `offsite-restore.sh` stop it
  after 3 tries (3 to 4 seconds in our test) and print what restic
  said, such as `Stat: The specified bucket does not exist` or `Stat:
  The Access Key Id you provided does not exist in our records.` (the
  test server's words; your provider's may differ).
- The keys must be plain text, as providers give them: a space, `#`,
  `;` or a quote is refused.

### Lose the password, lose the copy

There is no recovery: not by you, not by restic, not by anyone. The
password is also in `.env`, but `.env` is *inside* the copy, locked
with that same password, and the machine holding the other `.env` is
the one you are recovering from. Keep the password somewhere else too:
a password manager, or on paper with your important documents.
With cloud storage, keep the bucket's two keys with it: you can make
new keys at your provider, but only if you can still log in there.

### Size

Measured on a small install (Immich with three photos): a 17.1 MiB
local backup added 17.1 MiB off-site; a second run straight after, its
local backup 18.1 MiB, added 18.1 MiB. The backup's archives are
compressed, so restic can't find their unchanged parts: **every run
adds about the size of your local backup**. Photos are stored once; a
run only adds new ones.

So size the off-site disk for your photos, plus up to 24 snapshots
(7 + 5 + 12, fewer where they overlap) of your local backup. A
backup.sh run prints the size of the local one.

### What cloud storage costs

You pay for what is stored each month, and some providers also for
what you download. A restore downloads everything, so check that line
before you pick one. One example: Backblaze's price page
(<https://www.backblaze.com/cloud-storage/pricing>), read on
2026-11-07, said B2 costs $6.95 per TB per month, the first 10 GB free;
downloads free up to 3 times what you store (averaged over the month),
then $0.01 per GB; no minimum storage time. Prices change: read the
page itself.

At those prices, 200 GB of photos plus 24 snapshots of a 20 MB local
backup (200.48 GB) cost about $1.32 a month ($15.89 a year), and a
full restore (about 200 GB down) is inside the free 3 times.

### Restore from the off-site copy

Tested as written, on the pinned Immich (v3.3.5): everything deleted
but the off-site folder, then restored with these steps; same login,
same album, same photos (byte for byte), thumbnails back.

```bash
# 1. Install Docker, clone this repo to the same path as before (.env
#    holds absolute paths), and run the rest from inside that folder.
# 2. The newest off-site copy, into an empty folder (asks for the password;
#    cloud storage: OFFSITE_REPO=s3:https://… asks for its two keys first):
OFFSITE_REPO=/mnt/usb/anteiku-offsite ./scripts/offsite-restore.sh ~/restore
B=~/restore/backup
# 3. The stack (brings back .env) and the configs; root keeps their owners:
tar xzf $B/stack.tar.gz
A="$(sed -n 's/^APPDATA=//p' .env)"; P="$(sed -n 's/^PHOTOS_LOCATION=//p' .env)"
mkdir -p "$A"
sudo tar xzf $B/appdata-configs.tar.gz -C "$A"
# 4. Immich only: start its database empty and load the dump. (A backup
#    from an older backup.sh also holds its live files: rm drops them.)
sudo rm -rf "$A/immich/postgres"
docker compose up -d immich-db
until docker compose exec -T immich-db pg_isready -h localhost -U immich -q; do sleep 2; done
gzip -dc $B/immich-db.sql.gz | docker compose exec -T immich-db psql -U immich -d immich -q
# 5. The photo files, where .env says, then everything:
rsync -a ~/restore/photos/ "$P/"
docker compose up -d
```

- `--list` shows the snapshots; `--snapshot=<ID>` restores an older one.
- Step 4 prints a few `set_config` and `setval` results. An `ERROR`
  line means the restore is incomplete.
- `~/restore` holds every password (`stack.tar.gz`). Delete it when
  you are done.

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

Set `NTFY_URL` and `NTFY_TOPIC` in `.env` to get phone pushes (a
`setup.sh` re-run keeps them, ntfy installed here or not). Without
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

Rebuilding from nothing, with your local backup and your own copy of
the photos (see [Your photos](#your-photos)). Tested as written, on the
pinned Immich (v3.3.5): the install folder and every container deleted,
then restored with these steps; same login, same album, same photos
(byte for byte), thumbnails back.

```bash
# 1. Install Docker, clone this repo to the same path as before (.env
#    holds absolute paths), and run the rest from inside that folder.
# 2. The backup to restore: a dated folder in your BACKUP_DEST.
B=/mnt/backup/2026-10-28
# 3. The stack (brings back .env) and the configs; root keeps their owners:
tar xzf $B/stack.tar.gz
A="$(sed -n 's/^APPDATA=//p' .env)"; P="$(sed -n 's/^PHOTOS_LOCATION=//p' .env)"
mkdir -p "$A"
sudo tar xzf $B/appdata-configs.tar.gz -C "$A"
# 4. Immich only: start its database empty and load the dump. (A backup
#    from an older backup.sh also holds its live files: rm drops them.)
sudo rm -rf "$A/immich/postgres"
docker compose up -d immich-db
until docker compose exec -T immich-db pg_isready -h localhost -U immich -q; do sleep 2; done
gzip -dc $B/immich-db.sql.gz | docker compose exec -T immich-db psql -U immich -d immich -q
# 5. The photo files from your own copy, then everything:
rsync -a /mnt/backup/photos/ "$P/"
docker compose up -d
```

- Step 4 prints a few `set_config` and `setval` results. An `ERROR`
  line means the restore is incomplete.
- No Immich? Skip step 4 and the `rsync`.
- The same steps restore the [off-site copy](#restore-from-the-off-site-copy),
  with `B` and the photos taken from what `offsite-restore.sh` brought back.

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

Also `immich/postgres`, Immich's database files: a copy taken while
the database runs may not start, and the dump (`immich-db.sql.gz`)
already holds everything in them. A restore loads the dump into a fresh
database.

Folders of their own, when they sit inside the install folder (the
defaults put `./media` and `./photos` there): `MEDIA_ROOT`,
`PHOTOS_LOCATION` and the backup destination are left out of
`stack.tar.gz`, and the plan names them. Outside the install folder,
the archive never reaches them.

---

## Traps

**Media is not backed up, on purpose.** If you have media you genuinely
cannot replace — your own recordings, ripped discs you no longer own —
that is irreplaceable data, not media. Copy it somewhere separately.

**`.env` contains every secret.** `stack.tar.gz` is mode 600 for that
reason. Think before putting it on a shared drive, and encrypt it before
it leaves the house: the [off-site copy](#off-site-copy-encrypted) does.

**Live databases.** `backup.sh` archives `appdata/` while your
services run. Most of them keep their data in a SQLite file they can
write to at any moment. When a file changes while tar is reading it,
tar says `file changed as we read it`, and that file's copy may not
match itself: a database copied mid-write can fail to open after a
restore. Apps also delete short-lived files, such as a database's
`-journal`; one listed in a folder and gone by the time tar opens it
gives `File removed before we read it`, and the archive holds no
half-copy of it.

Those two messages are warnings: `backup.sh` names the files under
each, the backup still counts as done, and `update.sh` goes on.
Anything else tar reports is a failure, with tar's reason underneath:
a file it can't read, or `File shrank by N bytes; padding with zeros`
(the archive holds zeros where that data was). Immich's database is
safe either way: it is dumped with `pg_dump`, never archived live.

The same file named run after run? Back that service up stopped, or
let it make its own copy first:

| Service | How |
|---|---|
| Any | `docker compose stop uptime-kuma && ./scripts/backup.sh; docker compose start uptime-kuma`: offline while the backup runs, an exact copy. Stop only that service, not the stack: `backup.sh` needs Immich's database running to dump it |
| Sonarr, Radarr, Lidarr, Prowlarr | Already covered. Each writes its own backup every 7 days to `Backups/scheduled` in its config folder, keeps 28 days of them, and that folder is in the archive. Restore one under System → Backup |
| Vaultwarden | `docker compose exec vaultwarden /vaultwarden backup` before `backup.sh`: it writes `db_<date>_<time>.sqlite3` next to the database, so the archive holds a consistent copy |

**Retention cuts both ways.** 30 days of dailies is useless against
corruption you only notice after 40 days. Keep a monthly that you never
rotate.

**Test after changing what you run.** A new service means a new config
directory, and possibly a new database the script does not know about
yet.

**Backups are not monitoring, and monitoring is not backups.** Uptime
Kuma tells you something is down. It does not tell you a backup has
been failing for a month — that is what the success notification is for.
