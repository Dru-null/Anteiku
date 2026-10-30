# extras — notifications and passwords

| Service | Default port | Default |
|---|---|---|
| `ntfy` | 8095 | off |
| `vaultwarden` | 8222 | off |

---

# ntfy — the piece that makes monitoring real

Uptime Kuma can tell you a service is down. `backup.sh` can tell you a
backup failed. Neither is any use if the only place they say so is a
dashboard you are not looking at.

ntfy is a self-hosted push server. Your scripts POST to it; it pushes to
your phone. No account with anyone, no third party.

## Set it up

```bash
./scripts/ntfy-setup.sh --dry-run
./scripts/ntfy-setup.sh
```

That creates the user, grants it read-write on your topic, and sends a
test message. It is re-runnable.

Then install the ntfy app (iOS, Android, or the web app), add your
server, log in, and subscribe to the topic.

## Why it is locked down

It ships with `NTFY_AUTH_DEFAULT_ACCESS=deny-all`. An open ntfy lets
anyone who can reach the port read every notification you send — and
those say things like *"backup failed on <host>"*, or name services you
run. The setup script grants your user access to **one topic**, not to
everything.

Verified behaviour: publishing without credentials returns **403**.

## Wire it up

**Backups** already work — `NTFY_URL`, `NTFY_TOPIC`, `NTFY_USER` and
`NTFY_PASS` are in `.env`, and `scripts/backup-cron.sh` uses them. A
successful backup pushes at normal priority; a failure pushes at urgent
priority with a different tag, so you can tell them apart on a lock
screen without opening anything.

**Uptime Kuma** — Settings → Notifications → ntfy:

| Field | Value |
|---|---|
| Server URL | `http://ntfy` ← container name, not localhost |
| Topic | `homelab` |
| Authentication | username + password from `.env` |

Tick **Default enabled** so it applies to monitors you add later too.

**The *arrs, Seerr and others** all support webhooks or ntfy
directly. Same URL, same topic.

## Traps

**Use the container name from other containers.** Kuma reaching
`http://localhost:8095` is reaching *Kuma's own* localhost, which has no
ntfy on it. From a host script, `localhost:<published port>` is right.
That split is why `.env` has `NTFY_URL` pointing at the host port while
Kuma is configured with the container name.

**A quiet phone is ambiguous.** It means nothing is broken, *or* the
notification path is broken. Send a test message every so often — or
keep success notifications on, so silence is itself the alarm.

---

# Vaultwarden — your own password manager

Bitwarden-compatible, so the official Bitwarden apps and browser
extensions work against it. It is excellent, and it is the service in
this repo that demands the most care.

## Two things that make it different

### 1. The apps require HTTPS

This is the part that surprises people. The web vault works over plain
HTTP in a browser tab, so it looks fine — but **the browser extensions
and mobile apps refuse to connect to an http:// server.** They use web
crypto APIs that browsers only expose on a secure origin.

So `http://vault.home` is not enough for real use. Your options:

| Approach | Verdict |
|---|---|
| **Tailscale Serve** | **Easiest.** Real certificate, no domain, no open ports. One command |
| Own a domain + DNS-01 via NPM | Proper, works on the LAN, more setup |
| Self-signed certificate | Works on desktop with warnings; mobile apps often refuse |
| Plain HTTP | Web vault only. Fine to try it, not fine to rely on it |

**Tailscale Serve**, which also gets you remote access:

```bash
sudo tailscale serve --bg --https=443 http://localhost:8222
```

You get `https://machine.your-tailnet.ts.net` with a genuine
certificate, reachable only from your tailnet. Then set `DOMAIN` in
`.env` to exactly that URL and restart. See
[`../docs/remote-access.md`](../docs/remote-access.md).

> `DOMAIN` must match the URL you actually use, scheme included. A
> mismatch breaks client connections and attachment links in ways that
> are hard to diagnose.

### 2. It holds every password you own

Losing this is worse than losing your media library, and worse than
losing your photos — it locks you out of everything else you own.

- **Back it up** and **test the restore**. `scripts/backup.sh` includes
  it; [`../docs/backups.md`](../docs/backups.md) shows how to verify.
- **Keep a second way in.** An export, or a few critical passwords
  written down somewhere safe. If your homelab is the only copy of the
  password to your email, a dead disk is a very bad day.
- Consider whether a hobby server should hold your passwords at all.
  It is a legitimate thing to self-host; it is also legitimate to decide
  the stakes are too high.

## Setup

**1. Open it** (see `ports.md`) and create your account. The first
account is yours; there is no admin prompt like other services.

You do **not** need email configured. With no SMTP set up the server
issues the registration token directly, so sign-up works out of the box.

**2. Turn signups off immediately.** In `.env`:

```
VAULTWARDEN_SIGNUPS=false
```

then `docker compose up -d`.

While it is `true`, anyone who can reach the page can create an account
on your password manager. It starts as `true` only so you can make your
first account. Turn it off the moment you have.

To add someone later, flip it on, let them register, flip it back — or
invite them from the admin panel.

**3. The admin panel** is at `/admin`, using `VAULTWARDEN_ADMIN_TOKEN`
from `.env` (generated for you). It manages users and settings. Do not
expose it beyond your LAN or tailnet.

**4. Install the clients** — official Bitwarden apps and extensions.
On first launch, set the **server URL** to your HTTPS address *before*
logging in. The setting is behind a gear or "Self-hosted" option on the
login screen.

**5. Turn on two-factor** for your account.

## Traps

**`DOMAIN` must be exactly right**, including `https://` and any port.
Wrong value gives confusing client errors and broken attachments.

**Extensions silently refuse plain HTTP.** If the extension will not
connect but the web vault works, this is why. It is not a bug.

**Back up before you trust it.** Move your passwords in, then
immediately take a backup and test restoring it — before you delete
them from wherever they are now.

**`SIGNUPS_ALLOWED=true` is a real exposure**, not a formality.
`setup.sh` reminds you after install for exactly this reason.
