# media — playback

Serves the library to your TVs, phones and browsers. Nothing here
downloads anything; it plays what is already on disk.

| Service | Default port | What it does | Default |
|---|---|---|---|
| `jellyfin` | 8096 | Film and TV | on |
| `navidrome` | 4533 | Music, works with Subsonic apps | off |
| `kavita` | 5000 | Ebooks and comics | off |

> Your actual ports are in **`ports.md`**. If something already had one,
> setup.sh moved it.

Jellyfin also publishes two UDP ports — 7359 and 1900 — used only for
client auto-discovery. If those were taken and got moved, clients will
not find the server by themselves and you type the address in manually.
Playback is unaffected.

## Hardware transcoding

**First, the question nobody asks: do you need it?**

If your client can play a file as it is, it *direct plays* — nothing is
converted and the GPU is idle. Transcoding happens when the client cannot
handle the codec, container, or bitrate, or when you cap quality for
remote viewing. One person watching compatible files on a modern TV may
never transcode at all.

It matters when you have several simultaneous streams, remote viewers on
limited upload, or clients that cannot handle your files.

**Measured on the reference machine** (i5-9300H, UHD 630), encoding 60
seconds of 1080p30 to 4 Mbit H.264:

| | Time | Host impact |
|---|---|---|
| Intel Quick Sync | **6s** | load barely moved |
| CPU (libx264, medium) | 15s | load average spiked past 4 |

Two and a half times faster, and — more importantly for a box doing other
work — it keeps the CPU free.

### Which device

`setup.sh` detects your hardware and writes the right override into
`.env` as `COMPOSE_FILE`. To change it, edit that line:

| Override | For | Status |
|---|---|---|
| `hw/gpu-intel.yaml` | Intel iGPU, Quick Sync | **tested** |
| `hw/gpu-nvidia.yaml` | NVIDIA, NVENC | not maintainer-tested |
| `hw/gpu-amd.yaml` | AMD, VAAPI | not maintainer-tested |
| `hw/cpu-only.yaml` | no acceleration | always works |

**If you have both an Intel iGPU and a gaming GPU, setup.sh picks Intel,
on purpose.** Quick Sync is built for exactly this, needs no extra host
packages, draws a few watts, and leaves the discrete card free. The
bigger card is not the better tool here.

### Turning it on in Jellyfin

Installing the override is only half of it — Jellyfin does not use the
GPU until you tell it to:

```
Dashboard > Playback > Transcoding
  Hardware acceleration : Video Acceleration API (VAAPI)
  VA-API Device         : /dev/dri/intel-render
```

For NVIDIA, choose **Nvidia NVENC** instead and leave the device blank.

Verify it is really working — play something that must transcode, then:

```bash
docker compose logs jellyfin | grep -i vaapi
```

You should see ffmpeg invoked with VAAPI arguments. If playback works but
no VAAPI appears, it silently fell back to CPU. The two usual causes are
below.

## The two silent failures

Both produce no error. Jellyfin keeps working, just on the CPU, and you
find out months later when four streams melt the box.

**1. The device number moves.** `/dev/dri/renderD128` is not stable on a
machine with two GPUs — `renderD128` and `renderD129` can swap which card
they refer to across a reboot. Point Jellyfin at the bare number and one
day it is addressing the wrong card.

The fix, and what `hw/gpu-intel.yaml` does: pass the `by-path` symlink,
which is tied to the PCI slot and never moves, and expose it inside the
container under the fixed name `/dev/dri/intel-render`. Configure that
name and it keeps working.

```bash
ls -l /dev/dri/by-path/          # the stable ids
# pci-0000:00:02.0-render -> ../renderD129   <- iGPU
# pci-0000:01:00.0-render -> ../renderD128   <- discrete card
```

Note those two in the example: on the reference machine the *discrete*
card is `renderD128`, not the iGPU. Guessing would pick the wrong one.

**2. The render group id differs per machine.** `/dev/dri/render*` is
owned by group `render` (or `video`) — gid 991 on one machine, 104 on
another. A container outside that group opens the device read-only and
Jellyfin falls back to CPU without logging anything. `setup.sh` detects
the gid and writes `RENDER_GID` for the override to use.

```bash
getent group render      # yours
```

## Setup order

**1. Jellyfin** — open it, create the admin account, add libraries:

| Library type | Path |
|---|---|
| Movies | `/data/movies` |
| Shows | `/data/series` |
| Music | `/data/music` |
| Books | `/data/books` |

These are the same paths the arr stack files into, so anything Sonarr or
Radarr imports appears here automatically.

Then turn on hardware transcoding as above.

**2. Navidrome** — first account created becomes admin. Scans `/music`
read-only on start and hourly. Any Subsonic-compatible phone app works.

**3. Kavita** — create the admin account, then add a library pointing at
`/data/books`.

## Traps

**Migrating an existing Jellyfin?** Its database stores *absolute
container paths*. If your old install mounted the library somewhere other
than `/data`, change the mount in `stacks/media.yaml` to match the old
path exactly, or your libraries, watch history and metadata will not
resolve. A fresh install should leave it at `/data`.

**Navidrome runs as your user, not as PUID.** It uses compose's `user:`
instead. That matters because Docker creates a missing bind-mount
directory as **root**, and Navidrome then cannot create its database:

```
level=fatal msg="Database could not be opened!"
  error="unable to open database file: no such file or directory"
```

It restart-loops forever, and the error names a missing file when the
real problem is permissions. `setup.sh` pre-creates every data directory
with the right owner so this cannot happen. If you add a service by hand,
create its directory first:

```bash
mkdir -p appdata/<service> && chown $(id -u):$(id -g) appdata/<service>
```

**Transcoding scratch gets hammered.** It is a separate mount
(`/config/transcodes`) so you can point it at fast storage, or a tmpfs if
you have RAM to spare. Leaving it on a slow disk makes seeking feel bad
even when the encode itself is fast.

**Navidrome and Kavita mount their libraries read-only.** Deliberate — a
player has no business writing to your library. Remove `:ro` only if you
specifically want in-app editing.
