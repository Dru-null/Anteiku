# books — Calibre-Web-Automated

An ebook library manager with a web UI. Drop a book into a folder and it
is imported, converted if needed, given proper metadata and filed into a
real Calibre library. Also does Send-to-Kindle, and serves an OPDS feed
that most e-reader apps can browse.

| Service | Default port | Default |
|---|---|---|
| `calibre-web` | 8083 | off |

> Your actual port is in `ports.md`.

## How it fits with the other book services

| Service | Job |
|---|---|
| **Calibre-Web** | Manages the library: metadata, covers, conversion, Kindle |
| Kavita (`media`) | A nicer *reader*, especially for comics and manga |
| LazyLibrarian (`arr`) | Acquisition |

All three use `${MEDIA_ROOT}/books`. You do not need all of them.
Calibre-Web alone is a complete ebook setup.

## Setup

**1. Log in** with the default `admin` / `admin123`, and **change it
immediately** — Admin → Users → admin.

**2. Add a book.** Copy an epub into the ingest folder:

```bash
cp some-book.epub ${MEDIA_ROOT}/books/ingest/
```

Within a minute it disappears from `ingest/` and appears in the library.

**3. Optional — Send to Kindle:** Admin → Email Server Settings, then add
your Kindle address in your user profile, and allow the sending address
in your Amazon account.

**4. Optional — e-reader apps:** point any OPDS-capable app at
`http://<server>:<port>/opds`, using your Calibre-Web login.

## Traps

**Ingest consumes files.** Anything dropped in `books/ingest` is *moved*
into the library, not copied. Never put your only copy of a book there.

**Permissions are the usual ingest failure.** The library directory must
be writable by your `PUID:PGID`. A book that sits in `ingest/` forever is
almost always that, or a half-written file still being copied in.

**Several writers, one directory.** If you also run LazyLibrarian or
Kavita, they share `books/`. Calibre-Web renames and reorganises files
into its own structure, so Kavita needs a rescan to see the result, and
two tools filing the same book can collide.

**`metadata.db` is the library.** It lives in the books folder alongside
the files, and holds every title, author, series and tag. Losing it
leaves you with a pile of loosely named files. Your app config —
shelves, read status, users — is in `appdata/calibre-web`, which
`scripts/backup.sh` covers.

**The converted copies are disposable.** `processed_books` and
`thumbnails` can grow to gigabytes and are excluded from backups on
purpose; they regenerate.
