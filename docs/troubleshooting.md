# Troubleshooting

By what you see. Each entry gives the text you'll meet, what it really
means (many of these name the wrong cause), a command that confirms it,
and the fix, or the guide that has it.

Run the commands in your Anteiku folder. None of them prints a password.
Never paste your `.env` anywhere: it holds them all.

---

## First, look

```bash
docker compose ps -a                         # what is running, restarting, or stopped
docker compose logs <service> --tail 50      # its last 50 lines
./doctor.sh                                  # the machine: memory, disks, ports, Docker
```

`<service>` is the name in `docker compose ps`: `sonarr`, `jellyfin`,
`immich-server`, `nginx-proxy-manager`. A service that says
`Restarting` prints the same fatal line in its log on every attempt;
that line is what to search for below.

| You see | Section |
|---|---|
| `is not writable by user 'abc'` | [Permissions](#folder--is-not-writable-by-user-abc) |
| `Database could not be opened!` | [Permissions](#database-could-not-be-opened) |
| `password authentication failed`, `28P01` | [Passwords](#password-authentication-failed-28p01) |
| Jellyfin works, the CPU does all the work | [Transcoding](#jellyfin-plays-but-on-the-cpu) |
| `FFmpeg exited with code 251`, playback keeps retrying | [Transcoding](#ffmpeg-exited-with-code-251) |
| "Congratulations!" or "Default Site" | [Names](#congratulations--default-site) |
| "could not resolve the hostname" in the browser | [Names](#the-proxy-could-not-resolve-the-hostname) |
| `Port 53 is taken by` | [Names](#port-53-is-taken-by) |
| `Machine learning server became unhealthy` | [Messages that aren't faults](#machine-learning-server-became-unhealthy) |
| `No indexers available with RSS sync enabled` | [Messages that aren't faults](#no-indexers-available) |
| Uptime Kuma all green, something is broken | [Quiet failures](#uptime-kuma-is-all-green-and-something-is-broken) |
| A container's PIDS count keeps growing | [Quiet failures](#a-containers-pids-count-keeps-growing) |
| The disk is filling up | [Quiet failures](#the-disk-fills-up) |

---

## Permissions

### `Folder '…' is not writable by user 'abc'`

Sonarr or Radarr, when you add a root folder:

```
Folder '/data/series' is not writable by user 'abc'
```

**Means:** `abc` is the user *inside* the container. It runs as your
`PUID`. The folder on the host belongs to someone else, usually root (a
second-hand disk, or files copied with `sudo`).

**Confirm:**

```bash
ls -ldn "$(sed -n 's/^MEDIA_ROOT=//p' .env)"/*     # owner and group, as numbers
id -u; id -g                                       # yours: they should match
docker compose exec -u abc sonarr sh -c 'touch /data/series/.w && rm /data/series/.w && echo writable'
```

`Permission denied` from the last line is this problem.

**Fix:** give the media folder to your user, or for exFAT/FAT/ntfs-3g
disks mount it as your user: [arr Traps](../stacks/arr.md#traps).

### `Database could not be opened!`

Navidrome, restarting over and over:

```
level=fatal msg="Database could not be opened!" error="unable to open database file: no such file or directory"
```

**Means:** not a missing file. Its data folder belongs to root. Docker
creates a missing folder as root when a container starts, and Navidrome
runs as your user, so it can't write there. Anything you add by hand
without making its folder first does the same.

**Confirm:**

```bash
find appdata -maxdepth 1 ! -user "$(id -u)"     # folders that aren't yours
```

`appdata/npm` and `appdata/uptime-kuma` are root's on purpose: Nginx
Proxy Manager and Uptime Kuma run as root. Leave those two as they are.

**Fix:**

```bash
sudo chown -R "$(id -u):$(id -g)" appdata/navidrome
docker compose restart navidrome
```

The error and the cause were reproduced on Anteiku's Navidrome; there,
a folder of the user's in place of root's made it start. The `chown`
itself wasn't run (it needs root). [media Traps](../stacks/media.md#traps)
has the background. `setup.sh` makes every folder of the services you
pick with the right owner, so this only happens to a folder it didn't
make.

## Passwords

### `password authentication failed` (28P01)

Immich won't start; its log or the database's says:

```
password authentication failed for user "immich"
```

with the Postgres error code `28P01`.

**Means:** the database still has the password it was created with, and
`.env` now holds another one: `.env` was deleted or edited, or restored
from an older copy. The data is fine.

**Confirm** (compares, prints no password):

```bash
cmp -s <(grep '^IMMICH_DB_PASSWORD=' .env) <(grep '^IMMICH_DB_PASSWORD=' .env.bak) && echo same || echo different
```

`.env.bak` is `.env` as it was before the last `setup.sh` re-run. To
compare with a backup instead, set `B` to that backup's folder:

```bash
cmp -s <(grep '^IMMICH_DB_PASSWORD=' .env) <(tar -xOzf "$B/stack.tar.gz" ./.env | grep '^IMMICH_DB_PASSWORD=') && echo same || echo different
```

**Fix:** put the old `IMMICH_DB_PASSWORD` line back into `.env`, then
`docker compose up -d`. Don't wipe the database: that loses every album
and face. [photos Traps](../stacks/photos.md#traps).

The log line is Postgres's own wording; Anteiku's tests haven't
produced it. The two commands above were run on test files.

## Transcoding

### Jellyfin plays, but on the CPU

**You see:** nothing. Playback works, the CPU works hard while
something converts, and nothing is logged. The two usual causes are in
[media: the two silent failures](../stacks/media.md#the-two-silent-failures).

**Confirm:**

```bash
grep '^RENDER_GID=' .env; stat -c '%g %n' /dev/dri/renderD*     # the numbers must match
docker compose exec jellyfin id                                  # RENDER_GID among the groups
docker compose exec jellyfin /usr/lib/jellyfin-ffmpeg/vainfo --display drm --device /dev/dri/intel-render 2>&1 | grep 'Driver version'
```

The last line should name the Intel driver (`Intel iHD driver`); an
error means Jellyfin can't use the card. It applies with Intel
graphics: AMD uses `/dev/dri/amd-render`, NVIDIA has no device here.

**Fix:** a numbers mismatch: run `./setup.sh` again (it reads the group
again), then `docker compose up -d jellyfin`. Then in Jellyfin,
Dashboard → Playback → Transcoding: VAAPI, device
`/dev/dri/intel-render`, as [media](../stacks/media.md#turning-it-on-in-jellyfin)
shows.

### `FFmpeg exited with code 251`

A TV or phone says "error, retrying", then gives up; Jellyfin's log has
`FFmpeg exited with code 251` for every attempt.

**Means:** on a machine with two graphics cards, Jellyfin was pointed
at a bare `/dev/dri/renderD128`, and after a reboot that number belongs
to the other card. 251 is the code seen when the Intel driver was handed
the NVIDIA card; another mix-up may give another code.

**Confirm:** which card each number is, today:

```bash
ls -l /dev/dri/by-path/
docker compose exec jellyfin /usr/lib/jellyfin-ffmpeg/vainfo --display drm --device /dev/dri/renderD128 2>&1 | grep 'Driver version'
```

`Intel iHD driver` is the Intel card; `NV…` (nouveau) is NVIDIA. Try
`renderD129` too.

**Fix:** set Jellyfin's VA-API device to `/dev/dri/intel-render`, the
name Anteiku ties to the card's slot so it never moves:
[media: which device](../stacks/media.md#which-device).

## Names

### "Congratulations!" / "Default Site"

You open `sonarr.home` and get Nginx Proxy Manager's welcome page
("Congratulations!", page title "Default Site"), with a normal 200.

**Means:** the name reached Nginx Proxy Manager, but it has no proxy
host for that name: a typo, or a record added to Pi-hole but not to it.

**Confirm** (your server's address; add `:<port>` if `ports.md` moved
it off 80):

```bash
curl -s -H 'Host: sonarr.home' http://192.168.1.50/ | grep -o '<title>[^<]*'
```

`<title>Default Site` is this. The service's own name is the fix
working.

**Fix:** add the proxy host, spelled exactly as you type it:
[infra: add a proxy host](../stacks/infra.md#add-a-proxy-host).

### "The proxy could not resolve the hostname"

The browser shows an error page that seems to come from a proxy, often
"The requested URL could not be retrieved" and something like "not able
to resolve the hostname presented in the URL". The wording depends on
who sent it.

**Means:** a VPN on the device you browse from, not your homelab. The
VPN asks its own DNS, which has never heard of `.home`. A VPN that is a
browser extension is a proxy: even the server's address and port fail,
while other apps on the same device work.

**Confirm:** from the same device (Windows, macOS and Linux all have
`nslookup`):

```bash
nslookup sonarr.home 192.168.1.50     # your server's address
```

If it answers with your server's address, DNS is fine and the VPN is
the problem. Or turn the VPN off and reload. Not tested by Anteiku:
there is no VPN on its test machines.

**Fix:** VPN off, or let it bypass your LAN range and your suffix:
[remote access Traps](remote-access.md#traps).

### `Port 53 is taken by`

`setup.sh` says `Port 53 is taken by systemd-resolve — Pi-hole moved
to 54.` (or another process and port); `doctor.sh` says `Port 53 is
taken by:`. `systemd-resolve` is systemd-resolved, its name cut to 15
characters.

**Means:** something else answers DNS on this machine. Pi-hole still
starts on the moved port, but no device ever asks there: clients only
use 53.

**Confirm:**

```bash
sudo ss -lntup | grep ':53 '
```

**Fix:** for systemd-resolved, [infra: free port 53](../stacks/infra.md#part-1--free-port-53),
then run `./setup.sh` again.

## Messages that aren't faults

### `Machine learning server became unhealthy`

Immich's log, over and over:

```
Machine learning server became unhealthy (http://immich-machine-learning:3003).
```

**Means:** machine learning isn't installed (it's off by default), but
Immich still has it switched on in its own settings, so it keeps
looking for it.

**Confirm:**

```bash
grep '^COMPOSE_PROFILES=' .env     # no immich-ml in the list = not installed
```

**Fix:** Administration → Settings → Machine Learning → untick Enabled:
[photos](../stacks/photos.md#if-you-skip-it-do-this-one-thing-after-first-login).
If `immich-ml` *is* in the list, read
`docker compose logs immich-machine-learning --tail 50` instead.

### `No indexers available`

Sonarr's or Radarr's System → Status, as an error:

```
No indexers available with RSS sync enabled, Sonarr will not grab new releases automatically
No indexers available with Automatic Search enabled, Sonarr will not provide any automatic search results
```

**Means:** what it says, and expected. Anteiku ships no indexers, so
there is nothing to search until you add your own. Everything else can
work fine meanwhile.

**Confirm:** `[]` means none is set up:

```bash
docker compose exec sonarr sh -c 'k=$(sed -n "s:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p" /config/config.xml); curl -s -H "X-Api-Key: $k" http://localhost:8989/api/v3/indexer'
```

For Radarr, `radarr` and port `7878`.

**Fix:** none needed. [arr Traps](../stacks/arr.md#traps).

## Quiet failures

### Uptime Kuma is all green, and something is broken

**Means:** Kuma only watches what has a monitor. A service added after
the monitors were made has none.

**Confirm:** the monitors your install should have (needs `python3` on
the machine); compare them with the list in Kuma:

```bash
./scripts/kuma-bootstrap.sh --dry-run
docker compose ps -a        # anything not "running"
```

**Fix:** `./scripts/kuma-bootstrap.sh` again: it adds what is missing
and skips the rest. [monitoring Traps](../stacks/monitoring.md#traps).

### A container's PIDS count keeps growing

**You see:** nothing. CPU and memory are normal, the healthcheck and
Kuma are green. Weeks later the whole machine fails in ways that look
unrelated, because it has run out of process ids.

**Means:** a container that starts helper processes (a headless
browser, say) without an init process never cleans up the ones that
finish. They are zombies: no CPU, no memory, only a process id each. In
the homelab this kit comes from, one container held 11,862 of them
after 26 days, at 0.2 % CPU.

**Confirm:**

```bash
docker stats --no-stream --format 'table {{.Name}}\t{{.PIDs}}'     # the PIDS column, per container
ps -eo stat= | grep -c '^Z'                                         # zombies on the whole machine
docker inspect --format '{{.Name}} {{.HostConfig.Init}}' <container>   # <nil> or false: no init
```

A count in the hundreds that only goes up is the sign.

**Fix:** `init: true` on that service, then `docker compose up -d
<service>`. `docker restart` isn't enough: the container has to be made
again. Anteiku sets it where an image needs it (Seerr); if one of its
services shows this, [open an issue](https://github.com/dru-null/Anteiku/issues).

### The disk fills up

**Means**, usually: torrents seed forever with no ratio limit, and two
things make the size hard to read. A download in progress is a sparse
file that looks far bigger than it is. And an imported file is a
hardlink: the same data in `torrents/` and the library, so deleting it
from one frees nothing.

**Confirm:**

```bash
M="$(sed -n 's/^MEDIA_ROOT=//p' .env)"
df -h "$M"
du -sh "$M/torrents" "$M/series" "$M/movies"          # shared data is counted once, in the first
du -sh --apparent-size "$M/torrents"                  # much more than du -sh: sparse downloads
find "$M/torrents" -type f -links 1 -printf '%b\n' | awk '{s+=$1*512} END {printf "%.1f GB only in torrents\n", s/1e9}'
```

The last line is what deleting from `torrents/` would free: files with
a link count of 1, never imported.

**Fix:** set a seeding ratio limit (qBittorrent, Options → BitTorrent →
Seeding Limits); remove finished torrents in qBittorrent and keep their
files; never by hand in `torrents/`. [arr Traps](../stacks/arr.md#traps).
Images older releases left behind: `./update.sh --check` lists them,
with the command to remove them.

---

## How this page was checked

| | Entries |
|---|---|
| Error text and confirm commands run on a test install of the pinned images | `not writable by user 'abc'`, `Database could not be opened!`, Jellyfin's group and `vainfo` lines, `No indexers available` (Sonarr; Radarr's wording from its source), the PIDS and init commands |
| Run on test files | the password comparisons, the disk commands |
| Error text from the project's source, at the pinned version | `password authentication failed` (Postgres), `FFmpeg exited with code` (Jellyfin), `Machine learning server became unhealthy` (Immich), the Default Site page (Nginx Proxy Manager), `Port 53 is taken by` (`setup.sh`) |
| Not run | `nslookup` behind a VPN, the `chown` fixes, `ss` with `sudo` |

Not here? [Open an issue](https://github.com/dru-null/Anteiku/issues)
with your `./doctor.sh` output and the log line.
