# Updating

Every image in this kit is pinned to an exact version. Nothing updates
unless you change a version and run `docker compose up -d`.

---

## Why pinned

`latest` is not a version. It is whatever the project pushed most
recently, so two installs a month apart run different software, and an
update arrives whenever something happens to pull: a reboot, a re-run, a
new service. Moving tags also change underneath you. During testing, one
project was discontinued and its `latest` tag quietly started reporting
a `-deprecated` version.

Pinned, the versions in this repo are the ones that were tested
together. Updating becomes something you choose to do, after reading
what changed and making a backup.

---

## Where the versions are

In the stack files, one line per image:

```yaml
    image: lscr.io/linuxserver/sonarr:${SONARR_VERSION:-4.0.20.3014-ls1}
```

The part after `:-` is the pinned version. `SONARR_VERSION` is an
optional override you can set in `.env` (below). To list them all:

```bash
grep -h 'image:' stacks/*.yaml
```

The variable is the service's name in capitals, `-` becoming `_`:
`NGINX_PROXY_MANAGER_VERSION`, `UPTIME_KUMA_VERSION`. Immich is the
exception: one `IMMICH_VERSION` sets both the server and machine
learning, because they must match.

LinuxServer images (`lscr.io/linuxserver/...`) carry a build suffix,
`-ls324`. They rebuild each app weekly with operating-system fixes; the
suffix pins the exact build.

---

## Before any update

1. **Read the release notes** for every version between yours and the
   new one, not just the newest. Breaking changes are announced once.
2. **Back up.** `./scripts/backup.sh` (see [`backups.md`](backups.md)).
   Most apps convert their database to the new version on first start,
   and most cannot convert it back. The backup is your way back.
3. Update one service at a time, and check it works before the next.

---

## Update one service

Set its override in `.env`:

```bash
SONARR_VERSION=4.0.21.3050-ls5
```

Then:

```bash
docker compose pull sonarr
docker compose up -d sonarr
docker compose logs -f sonarr      # Ctrl-C when it has settled
```

You are now ahead of what this kit tested. That is fine; it is your
server. Re-running `./setup.sh` keeps the line and reminds you it is
there.

## Go back to the pinned version

Delete the line from `.env`, then `docker compose up -d`.

## Roll back after a bad update

1. Set the override to the version you had before, in `.env`.
2. If the app converted its database on the new version, the old version
   may refuse to start, or start and misbehave. Restore that service's
   config from the backup you made first. The steps are in
   [`backups.md`](backups.md), "Test the restore. Really.".
3. `docker compose up -d <service>`

## Update the whole kit

When this repo moves to newer pins, the ones tested together:

```bash
./scripts/backup.sh
git pull
./setup.sh                          # keeps your settings, passwords and overrides
docker compose pull
docker compose up -d
```

Overrides in `.env` still win over the new pins. Remove the ones you no
longer need.

---

## Immich

The service most likely to need care, and the one holding photos you
cannot get back.

- `IMMICH_VERSION` sets both `immich-server` and
  `immich-machine-learning`. Never set them apart.
- Postgres and Valkey are pinned to what Immich's own compose file
  ships for that release. They have no override on purpose. When a new
  Immich release changes them, so does this repo.
- Immich publishes breaking changes in its release notes, often
  database-related. Read them.
- Back up first, every time. `backup.sh` dumps the Immich database;
  restoring it is in [`backups.md`](backups.md).
- **Never roll the database image back.** If an Immich update goes
  wrong, restore the database dump into the version it came from.

## Uptime Kuma

Pinned to the 1.x line. `scripts/kuma-bootstrap.sh` uses the
`uptime-kuma-api` library, which speaks to 1.x. Kuma 2 exists; moving
to it means checking the bootstrap first.

## Diun

Older releases shipped Diun, which reported new upstream images. With
every version pinned and tested in releases, it either stayed quiet or
pointed at versions nobody had tested together, so it was removed. If
you have it, the release that removed it says how to take it out.
