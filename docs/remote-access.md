# Getting to your homelab from outside

**Optional. Read the first section even if you skip the rest.**

At some point you will want Jellyfin on a train, or to fix something
while away. There are two ways to do that, and the difference between
them matters more than anything else in this repo.

---

## Do not forward ports

The obvious move is to open port 8096 on the router and point it at
Jellyfin. Many guides tell you to. Please do not.

Forwarding a port publishes that service to the entire internet. Within
hours, automated scanners will find it — this is not hypothetical, it is
constant background traffic on every residential IP. From then on, the
only thing between strangers and your files is that service's login
page, and whether it has an unpatched vulnerability this week.

You are also volunteering to patch it forever. A *arr app or a media
server is not written to be internet-facing, and a homelab run as a
hobby does not get security updates applied within hours of disclosure.

**The alternative costs nothing and is easier.** A mesh VPN puts your
phone *on your home network* from anywhere, with no open ports at all.
Nothing is exposed; there is no login page for strangers to find,
because there is no reachable service to find.

| Approach | Exposed to internet | Effort | Verdict |
|---|---|---|---|
| **Tailscale** | nothing | 10 minutes | **Start here** |
| Self-hosted WireGuard | one UDP port | an afternoon | Great if you want no third party |
| Cloudflare Tunnel | nothing (proxied) | moderate | Good for genuinely public sites |
| Port forwarding | everything you forward | minutes | Don't |

The rest of this page covers Tailscale, because it is the one most
people should use.

---

## What Tailscale actually is

A managed WireGuard mesh. Every device you enrol gets a private
`100.x.y.z` address and can reach every other device directly,
encrypted, wherever they are. Your phone on mobile data and your server
at home behave as if they share a LAN.

It punches through NAT by itself, so **no router configuration and no
open ports**. A coordination server handles key exchange and discovery;
your actual traffic goes peer to peer and Tailscale cannot read it.

Free for personal use, generously so.

**The trade:** you depend on a third-party coordination service for
device authentication. If that is unacceptable, self-host
[Headscale](https://github.com/juanfont/headscale) (same clients) or
plain WireGuard.

---

## Install it

### On the server

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

It prints a URL — open it, sign in, and the machine joins your tailnet.

```bash
tailscale status          # who is on the tailnet
tailscale ip -4           # this machine's 100.x address
```

### On your phone and laptop

Install the Tailscale app, sign in with the same account. That is the
whole process.

### Reach a service

Everything already works, by tailnet IP:

```
http://100.x.y.z:8096       # Jellyfin, from anywhere
```

With **MagicDNS** on (Tailscale admin → DNS → enable), use the machine
name instead:

```
http://homelab:8096
http://homelab.your-tailnet.ts.net:8096
```

No ports opened. Nothing exposed. Works on mobile data, hotel wifi, and
other people's networks.

---

## Make your `.home` names work away from home

If you set up Pi-hole and Nginx Proxy Manager, you have nice names like
`jellyfin.home` on your LAN. By default those do **not** work over
Tailscale, because your phone is asking its normal DNS server, which has
never heard of `.home`.

Fixing it takes one setting, and this is the piece that makes the whole
setup feel finished.

**Tailscale admin console → DNS → Nameservers → Add nameserver →
Custom**

1. Enter your server's **tailnet** IP (`tailscale ip -4` on the server)
2. Turn on **Restrict to search domain**
3. Enter your suffix: `home`

That is a **split DNS** route: only `*.home` lookups go to Pi-hole, over
the tailnet. Everything else uses the device's normal resolver.

Now `http://jellyfin.home` works identically at home and away. The same
bookmark, the same app config, the same URL you give the household.

### Why restrict it to one suffix

You *can* send all DNS through Pi-hole for remote devices — that gives
you ad blocking on mobile data too, which is tempting. But then every
lookup on your phone depends on your home server being up and reachable.
If the box reboots while you are out, your phone has no DNS at all.

Restricting to `.home` is the safer default. Enable the broader version
later if you want it.

---

## Optional extras

### Subnet router — reach devices that cannot run Tailscale

Printers, smart plugs, the router's admin page. Advertise your LAN from
the server:

```bash
sudo tailscale up --advertise-routes=192.168.1.0/24
```

Then approve the route in the admin console (**Machines → your server →
Edit route settings**). Remote devices can now reach anything on your
home LAN by its normal address.

### Exit node — route all traffic through home

Useful on untrusted wifi, and makes you appear to be at home.

```bash
sudo tailscale up --advertise-exit-node
```

Approve it in the console, then pick it in the client app. Note this
sends *all* your traffic through your home upload, so it is slower.

### Tailscale Serve — HTTPS without certificate work

```bash
sudo tailscale serve --bg --https=443 http://localhost:8096
```

Gives a real, valid HTTPS certificate on your
`machine.tailnet.ts.net` name, reachable only from your tailnet. This
solves the LAN-HTTPS problem described in `../stacks/infra.md` without
owning a domain.

> `tailscale funnel` makes that URL public to the entire internet.
> That is port forwarding with extra steps. Use it deliberately or not
> at all.

---

## Traps

**A commercial VPN on the client breaks your local names.** This one
costs people an entire evening. With a privacy VPN active, `jellyfin.home`
fails with an error page that looks like your proxy is broken — often
something like *"the proxy server could not resolve the hostname"*.

That page comes from the VPN provider's exit proxy. The VPN tunnels DNS
to its own resolver, which has never heard of your suffix. Your homelab
is completely fine.

```bash
# prove it from the server - if this answers, the stack is healthy
dig +short jellyfin.home @127.0.0.1
```

Fix: turn the VPN off, or split-tunnel your LAN range and your suffix.
It is especially confusing right after a real outage, when you are
already expecting the stack to be broken.

Tailscale and a commercial VPN also compete for the same tunnel
interface; most phones will only run one at a time.

**Do not make the server use Tailscale's DNS.** On the machine running
Pi-hole, keep `--accept-dns=false`. Otherwise the server asks Tailscale
for DNS, which routes `.home` back to Pi-hole, which is itself — a loop.
Clients should use Tailscale DNS; the server should not.

**Key expiry.** By default a device's key expires after ~6 months and it
drops off the tailnet — always while you are away. For your server,
open the admin console → Machines → your server → **Disable key
expiry**. Do this for the server only, not for phones.

**Approve routes and exit nodes.** Advertising is only half; nothing
takes effect until approved in the admin console. Easy to miss.

**Jellyfin clients and "local network" detection.** Some clients decide
you are remote and transcode harder than needed. In Jellyfin, add your
tailnet range (`100.64.0.0/10`) to **Dashboard → Networking → LAN
networks** so tailnet clients count as local.

**Tailscale is not a backup.** It gets you *to* your data. It does not
protect you from losing it.

---

## Verify

```bash
# on the server
tailscale status                     # devices and their state
tailscale ip -4                      # your 100.x address

# from a phone on MOBILE DATA (not home wifi - that proves nothing)
#   http://100.x.y.z:8096            should load Jellyfin
#   http://jellyfin.home             should load too, if split DNS is set
```

Testing from home wifi is the classic false pass: it works because you
are on the LAN, not because remote access works. Turn wifi off first.
