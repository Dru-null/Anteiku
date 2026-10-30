# infra — reverse proxy and network-wide DNS

**Optional, but recommended once the basics work.**

Everything you have installed already works. This stack is about
comfort and reach: instead of remembering `http://192.168.1.50:8989`,
you type `sonarr.home`, from any device on your network, and it works.

Do not start here. Get one or two services running and used first, then
come back. Half-configured DNS is more annoying than typing ports.

| Service | Default port | What it does | Default |
|---|---|---|---|
| `nginx-proxy-manager` | 80 / 443 / 81 | Hostnames and HTTPS | off |
| `pihole` | 53 / 8053 | DNS server and ad blocking | off |

---

## How the two pieces fit together

This confuses almost everyone at first, because it is two separate jobs
that only make sense together.

```
   Your phone types   sonarr.home
            |
            v
   [ 1. Pi-hole ]   "sonarr.home? That is 192.168.1.50."
            |          (DNS - turns a name into an address)
            v
   [ 2. Nginx Proxy Manager ]  listening on port 80 at .50
            |          reads the requested hostname and decides
            |          "sonarr.home means container sonarr:8989"
            v
   [ sonarr container ]
```

**Pi-hole answers "where is it".** Every name points at the *same* IP —
the machine running your homelab.

**NPM answers "which service".** It reads the hostname from the request
and forwards to the right container.

You need both. Pi-hole alone gets you to the machine but not to a
service. NPM alone works only if you type the IP or edit every device's
hosts file.

---

## Pick a domain suffix first

Use something that cannot collide with the real internet.

| Suffix | Verdict |
|---|---|
| `.home`, `.lan`, `.box` | **Good.** Reserved for exactly this |
| `.internal` | Good, slightly longer |
| A real domain you own | Best, and required for public HTTPS |
| `.local` | **Never.** Reserved for mDNS/Bonjour; breaks Apple and Linux discovery in confusing ways |
| `.dev`, `.app` | **Never.** Real TLDs with enforced HTTPS |

This guide uses `.home`.

---

## Part 1 — free port 53

Pi-hole needs port 53. On most Ubuntu and Debian systems
`systemd-resolved` already has it, and Pi-hole will not start.
`doctor.sh` detects this and names the holder.

Check:

```bash
sudo ss -lntup | grep :53
```

If it names `systemd-resolve`, free it:

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
echo -e '[Resolve]\nDNSStubListener=no' \
  | sudo tee /etc/systemd/resolved.conf.d/99-pihole.conf

# keep the HOST able to resolve names even when Pi-hole is down
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

sudo systemctl restart systemd-resolved
```

**What this does:** systemd-resolved stops listening on 53 but keeps
working as the host's internal resolver. The symlink is the important
half — without it, your server cannot resolve anything whenever Pi-hole
is stopped, which includes while you are trying to pull the image that
fixes Pi-hole.

To undo it, delete that file and restart the service.

Then re-run `./setup.sh`. **If Pi-hole did not get port 53, it cannot
serve your network** — clients only ever ask on 53. It will start and
answer test queries, but nothing will use it for real.

---

## Part 2 — set up Nginx Proxy Manager

Open the admin UI (see `ports.md`, default `:81`).

**On first visit you create the admin account.** Older guides tell you
to log in with `admin@example.com` / `changeme`. That default no longer
exists in NPM 2.16+; the first visit asks you to make a real account.

### Add a proxy host

For each service: **Hosts → Proxy Hosts → Add Proxy Host**

| Field | Value |
|---|---|
| Domain Names | `sonarr.home` |
| Scheme | `http` |
| Forward Hostname | `sonarr` ← the *container name* |
| Forward Port | `8989` ← the *internal* port |
| Block Common Exploits | on |
| Websockets Support | on (needed by several services) |

> **Use the container name and internal port**, from the "Inside Docker"
> column of `ports.md`. Not your LAN IP, not the published host port.
> Containers reach each other by name on the shared network, and that
> keeps working when your IP changes or a host port moves.
>
> The two differ more often than you would expect: qBittorrent is
> `qbittorrent:8080` even though you browse to it on 8181.

Repeat per service. A typical set:

| Hostname | Forwards to |
|---|---|
| `jellyfin.home` | `jellyfin:8096` |
| `sonarr.home` | `sonarr:8989` |
| `radarr.home` | `radarr:7878` |
| `qbit.home` | `qbittorrent:8080` |
| `requests.home` | `seerr:5055` |
| `music.home` | `navidrome:4533` |
| `pihole.home` | `pihole:80` |

**NPM cannot proxy its own admin UI.** Port 81 stays as it is.

---

## Part 3 — tell Pi-hole where those names live

NPM now routes by hostname, but nothing yet *resolves* those names. Add
a local DNS record per hostname, all pointing at the **server's IP**.

Pi-hole admin → **Settings → Local DNS Records**

| Domain | IP |
|---|---|
| `jellyfin.home` | `192.168.1.50` |
| `sonarr.home` | `192.168.1.50` |
| … | same IP for every one |

Yes, every record is the same address. That is correct — they all point
at the machine running NPM, and NPM sorts out which service from the
hostname.

If you prefer, one wildcard CNAME can cover all of them, but explicit
records are easier to debug when you are starting out.

### Give the server a static IP first

All of this breaks the day DHCP gives your server a different address.
Either set a static IP on the server, or — easier and safer — reserve
its current address in the router's DHCP settings (usually "DHCP
Reservation" or "Static Lease", keyed to the server's MAC address).

---

## Part 4 — point the whole network at Pi-hole

Until now only devices you configured by hand use Pi-hole. This step
makes it automatic for every phone, TV and laptop that joins the
network.

**Do it in the router, in one place:**

1. Open the router admin page — usually `192.168.1.1` or `192.168.0.1`
2. Find **DHCP settings** (sometimes under LAN, or Advanced)
3. Set **Primary DNS** to your server's IP, e.g. `192.168.1.50`
4. **Leave Secondary DNS empty** — see the warning below
5. Save, then reconnect a device (or wait out the DHCP lease)

Verify from another machine:

```bash
nslookup sonarr.home
# should answer with your server's IP
```

### Do not set a secondary DNS

This is the mistake that wastes the most time. A secondary DNS server
is **not** a fallback that only gets used when the first one fails —
clients query whichever they like, whenever they like. Set your router
or ISP as secondary and you get:

- ad blocking that works perhaps half the time
- `sonarr.home` resolving on one device, failing on the next
- and no obvious pattern to it

Leave it blank. The real cost is honest: **if Pi-hole goes down, DNS
goes down for the whole house.** That is the trade. Mitigate it with
`restart: unless-stopped` (already set) and by knowing the undo step:
put the router's own IP back as primary DNS and everything returns to
normal.

### Changing the router is not always possible

Some ISP-supplied routers do not let you change DNS. Options:

- Set DNS manually per device (works, tedious)
- Put the ISP router in bridge mode behind your own
- Use Pi-hole as the DHCP server instead, and turn off the router's

---

## Verify the whole chain

```bash
# 1. Pi-hole resolves the name to the server
dig +short sonarr.home
#    -> 192.168.1.50

# 2. Pi-hole is blocking ads
dig +short doubleclick.net
#    -> 0.0.0.0  (or NXDOMAIN)

# 3. NPM routes the hostname to the right container - check the TITLE,
#    not just the status code
curl -s -H 'Host: sonarr.home' http://192.168.1.50/ | grep -i '<title>'
#    -> <title>Sonarr</title>

# 4. the real thing
#    open http://sonarr.home in a browser
```

**"Congratulations!" / "Default Site" is not success.** NPM shows that
page, with a perfectly healthy HTTP 200, for any hostname it has no
proxy host for — usually a typo in the domain name, or a record added to
Pi-hole but not to NPM. It looks like things are working; they are not.
That is why step 3 checks the page title rather than the status code.

A timeout means DNS sent you somewhere wrong.

---

## HTTPS

Optional, and more involved than it looks.

**On a LAN-only setup you cannot get a normal certificate.** Let's
Encrypt must verify you control the domain, and `sonarr.home` is not a
real domain. Your choices:

| Approach | Notes |
|---|---|
| Plain HTTP on the LAN | Perfectly reasonable at home. Simplest |
| Own a real domain + DNS-01 challenge | NPM supports it; gives real certs with nothing exposed publicly |
| Self-signed cert | Works, but every device warns every time |

If you do want public certificates, NPM needs ports **80 and 443**
reachable from the internet for the HTTP challenge. If `setup.sh` moved
those because something else held them, `setup.sh` says so explicitly —
automatic certificates will not work until they are free.

**Do not forward ports to get at this from outside.** A mesh VPN gives
you remote access with nothing exposed to the internet, takes about ten
minutes, and also solves the HTTPS problem above via Tailscale Serve.

It can additionally make these same `.home` names resolve when you are
away, so one bookmark works everywhere. See
[`../docs/remote-access.md`](../docs/remote-access.md).

---

## Traps

**Pi-hole on a non-standard port serves nothing.** Clients only ask on
53. If `setup.sh` had to move it, fix port 53 and re-run.

**DNS rebind protection.** Some routers refuse DNS answers that point to
a private IP, which breaks exactly this setup. Symptom: works on the
server, fails from other devices. Look for "DNS Rebind Protection" in
the router and add an exception for your suffix, or disable it.

**Never use `.local`.** It is reserved for mDNS. Things will half-work
in ways that take hours to diagnose.

**Browsers cache DNS hard.** After changing records, a browser may hold
the old answer well past the TTL. Test with `dig`/`nslookup` first, and
use a private window.

**Clients hold DHCP leases.** After changing router DNS, devices keep the
old server until their lease renews. Reconnect the wifi to force it.

**The server's own DNS.** With `DNSStubListener=no` and the resolv.conf
symlink above, your server resolves names through systemd-resolved
independently of Pi-hole, so a Pi-hole outage does not stop you fixing
Pi-hole.
