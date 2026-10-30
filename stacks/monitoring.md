# monitoring — knowing when something broke

| Service | Default port | What it does | Default |
|---|---|---|---|
| `uptime-kuma` | 3001 | Checks each service, alerts your phone | off |
| `dozzle` | 8888 | All container logs in a browser | off |

---

## The thing worth understanding first

**A dashboard full of green ticks means "the things I am watching are
up". It says nothing at all about the things I forgot to add.**

This is not a hypothetical. The homelab this repo is drawn from ran 38
monitors, all green, while several services were quietly broken — they
were simply never added. All-green read as all-fine for weeks.

That is why `setup.sh` knows what you installed and
`scripts/kuma-bootstrap.sh` turns that list into monitors. The list
cannot drift from reality, because it *is* reality.

Re-run it whenever you add services.

---

## Generate your monitors

```bash
./scripts/kuma-bootstrap.sh --dry-run   # show the plan
./scripts/kuma-bootstrap.sh             # create them
```

It is safe to re-run — anything already there by name is skipped.

Example output for an eight-service install:

```
  Critical
      pihole                 http://pihole:80/admin/login
  Media
      jellyfin               http://jellyfin:8096/health
  Acquisition
      qbittorrent            http://qbittorrent:8080/
      radarr                 http://radarr:7878/
      sonarr                 http://sonarr:8989/
  Infra
      dozzle                 http://dozzle:8080/
  External
      Internet               ping 1.1.1.1
```

Kuma has no REST API — only socket.io — so the script runs a throwaway
container on your compose network to talk to it. Nothing is installed
on your host, and the container is discarded afterwards.

The admin account is created on the first run, using `KUMA_USER` and
`KUMA_PASSWORD` from `.env` (generated for you). Change the password in
the UI afterwards if you like; `.env` is only used for the first setup.

---

## How the monitors are structured

### Grouped by what they mean, not alphabetically

| Group | Holds | Why separate |
|---|---|---|
| **Critical** | Pi-hole, reverse proxy | If these are down, *everything* looks down. Check here first |
| **Media** | Jellyfin, Navidrome, Kavita, Seerr | What the household notices |
| **Acquisition** | *arrs, download client | Annoying when broken, nothing is on fire |
| **Infra** | Dozzle, dashboards | Supporting cast |
| **Containers** | things with no HTTP (none in the kit today) | Checked by container state instead |
| **External** | Internet ping | See below — the most useful one |

The point of grouping is triage at a glance. Six red ticks under
*Acquisition* with *Critical* green is a different morning from one red
tick under *Critical*.

### Why there is an Internet monitor

`ping 1.1.1.1` is the most valuable monitor in the list, and it watches
nothing you own.

When everything goes red at once, it answers the only question that
matters first: **is my stack broken, or is my internet down?** Without
it you start debugging containers when the actual problem is your ISP.

### Checks use container names, not host ports

```
http://sonarr:8989        <- yes
http://192.168.1.50:8989  <- no
```

Kuma sits on the same docker network, so it reaches services directly.
That is more accurate — you are testing the service, not your port
mapping — and it keeps working if a published port moves.

Note the internal port is often not the one you browse to:
qBittorrent is `qbittorrent:8080` even though you open it on 8181.

### Real health endpoints where they exist

| Service | Path | Why |
|---|---|---|
| Jellyfin | `/health` | Purpose-built; proves the app works, not just that a port answers |
| Navidrome | `/ping` | Same |
| Pi-hole | `/admin/login` | `/` redirects in a way that hides failures |
| most others | `/` | No health endpoint exists |

Hitting `/` usually works, but often only proves a login page renders.
Use a real health endpoint when the service offers one.

### A 401 means up

Accepted status codes are `200-299` and `300-399`, plus `401` for
services that demand auth at the root.

That is deliberate. For an **availability** check, a 401 means "up, and
asking who you are" — the service is clearly alive. Only a 5xx or no
answer at all means down. Treating 401 as a failure gives you an alert
every time a login page works correctly.

### Intervals and retries

60 seconds, 2 retries before alerting (3 for the internet ping, which
is the most prone to a harmless blip). Roughly two minutes from "broke"
to "phone buzzed" — fast enough to be useful, slow enough not to cry
wolf over one dropped packet.

---

## Do this bit yourself: notifications

**The script cannot do it, and without it none of this is monitoring.**
A dashboard you have to remember to open is not telling you anything;
it is waiting to be asked.

Kuma → **Settings → Notifications → Setup Notification**. It supports
ntfy, Discord, Telegram, Gotify, email, webhooks and more. ntfy is the
easiest route to a phone push with no account anywhere.

Then attach it: either edit each monitor, or tick **Default enabled**
when creating the notification so it applies to everything, including
monitors you add later.

Test it by stopping something harmless:

```bash
docker compose stop dozzle
# wait ~2 minutes, expect a notification
docker compose start dozzle
```

If no notification arrives, you have a dashboard, not an alerting
system. Fix it now rather than finding out during a real outage.

---

## Docker-type monitors

Services with no HTTP endpoint (none in the kit today) cannot be checked
with a URL. Kuma can watch the container itself, but that needs a
**Docker Host** entry first, which the script cannot create blind. It
reports these and moves on.

To set one up: Kuma → **Settings → Docker Hosts → Add**, connection
type *Socket*, path `/var/run/docker.sock` (the compose file already
mounts it read-only). Then add a Docker monitor per container.

---

## Dozzle

Container logs in a browser, no setup. The first place to look once
Kuma says something is down.

It reads the Docker socket **read-only**. Keep it that way — the socket
is effectively root on the host.

Dozzle has no authentication by default. Fine on a trusted LAN; put it
behind the reverse proxy with an access list if that is not your
situation, and never expose it publicly.

---

## Traps

**All green only covers what is listed.** Re-run `kuma-bootstrap.sh`
after adding services, or your newest service is the one nobody is
watching.

**Monitoring on the same box as the services.** If the machine dies,
Kuma dies with it and nothing alerts. That is the honest limitation of
a single-machine homelab. The cheap mitigation is an external
free-tier uptime check pointed at one service, so something outside the
house notices when the whole house is gone.

**Alert fatigue is a real failure mode.** If you are pinged for every
restart, you will mute it, and then it is worthless. Raise retries on
anything flappy rather than ignoring it.

**Kuma stores everything in `${APPDATA}/uptime-kuma`.** Back it up with
the rest of your appdata; losing it means rebuilding every monitor and
all your history.
