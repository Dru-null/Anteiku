# Contributing

Fixes, guides, tested hardware and new services are welcome. Read the
rules first; a change that breaks one won't be merged however good it is.

## Rules

- **No indexers, no sources, ever.** No indexer lists, trackers, "where to
  get" links or hints, in code, docs, issues or comments. This project
  ships infrastructure only. See the note at the top of the README.
- **Accurate over complete.** Check behaviour against the running software
  and upstream docs before writing it down. If you couldn't test something
  (another GPU, another distro, ARM), say so in the doc.
- **Output is safe to paste.** Nothing `doctor.sh` or `setup.sh` prints may
  contain a secret. People post it in issues.
- **`setup.sh` never starts containers**, and re-running it never breaks an
  install.
- **Bash and Docker on the host, nothing else.** Anything more runs in a
  container or a venv.

## Before you commit

```bash
./scripts/check.sh --tui; echo "exit $?"
```

It must print `All checks passed.` and exit 0. It lints (shellcheck from
its pinned image, the same version as CI, never a host copy), parses, checks
every compose combination, runs `setup.sh` in a temporary copy, runs
detection against fake machines (`tests/detect`), drives the picker, and
scans for secrets and image metadata. It starts none of the
stack's containers.

Add your own leak patterns (your name, your LAN) with
`LEAK_PATTERNS_FILE=~/my-patterns.txt`, one regex per line, kept outside
the repo.

## Test in an isolated copy

If you already run a stack on this machine, never test in it. Copy the
repo and give the copy its own prefix, project and network:

```bash
T=~/anteiku-test
mkdir -p "$T" && git ls-files | tar cf - -T - | tar xf - -C "$T" && cd "$T"
env -i PATH="$PATH" HOME="$HOME" TERM="$TERM" \
  STACK_PREFIX=t- COMPOSE_PROJECT_NAME=anteiku-test DOCKER_NETWORK=anteiku-test \
  ./setup.sh
docker compose up -d
```

`env -i` keeps passwords exported in your shell out of the test. Ports
already in use move up by one, so the copy runs beside your real stack.
Tear it down with `docker compose -p anteiku-test down`, then delete the
folder (some files are owned by root).

Test re-runs as well as first installs: run `setup.sh` again and add a
service. That path is where most bugs have been.

## Suggesting a service

Open an issue with the
[Suggest a service](https://github.com/dru-null/Anteiku/issues/new?template=service.md)
template before writing any code. A service fits when it is:

- **Self-hosted**: it runs on the one machine, with no account at the
  project's own cloud.
- **Maintained**: recent releases, and issues that get answers.
- **Infrastructure, not sources**: nothing that lists, finds or solves
  access to indexers or trackers. The first rule above.
- **Pinnable**: a published image with exact version tags. `check.sh`
  refuses `latest` and other tags that move.
- **Useful to a beginner on one machine**: something a household would
  use, not a cluster tool.

The issue needs the image (registry and name), what it's for and who
would use it, and how it fits with the services already here.

## Adding a service

One service touches all of these. `check.sh` catches most of what you miss.

| Where | What |
|---|---|
| `setup.sh` `CATALOGUE` | `key\|stack\|default\|hostport\|internalport\|description`. Keep the description ASCII |
| `stacks/<stack>.yaml` | The service, with `profiles: ["<key>"]`, `container_name: ${STACK_PREFIX}<key>` and an exact pinned image: `repo:${KEY_VERSION:-1.2.3}`. `check.sh` refuses a major.minor tag; if the version really has two parts, end the line with `# two-part: <why>`. A service that runs as the user takes `PUID`/`PGID` in its environment (or `user: "${PUID}:${PGID}"`): that is how `setup.sh` knows its `${APPDATA}` folders must be the user's |
| `stacks/<stack>.md` | What it is, setup order, and a Traps section |
| `scripts/kuma-monitors.py` | Its monitor. The drift check fails without one |
| `setup.sh` `_mk` lines | Data directories, if it needs any |
| `setup.sh` `svc_of()` | If the compose service name differs from the key |
| `scripts/backup.sh` | `appdir_of()`, if its config isn't in `appdata/<key>` or it keeps none. Excludes, if it keeps caches |

Any `${VAR}` that `setup.sh` writes only sometimes needs a `:-default` in
the yaml. Compose parses every stack even when a profile is off, and one
unset variable breaks all of them.

## Changing the picker

Regenerate the screenshot in `assets/picker.svg` with
`tests/screenshot.py` (the command is at the top of the file). Use a
throwaway copy and a demo prefix, so nothing from your machine is on
screen.

## Changing detection

`lib/detect.sh` decides the GPU profile, the render device, the ports and
more, on hardware no one person owns. `tests/detect/cases.sh` describes
fake machines (lspci lines, render nodes, `/proc`, os-release, which tools
exist) and what `doctor.sh` and `setup.sh` must make of them. Add or change
a case with your change, and run just that one while you work:

```bash
bash tests/detect/run.sh --list
bash tests/detect/run.sh gpu_amd
```

These results are *mocked*: they show what the scripts do with that
input, not that the hardware works. A case from your own machine is
welcome. Copy only hardware lines: no host or user names, addresses or
timezone.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/):
`feat(setup): …`, `fix(arr): …`, `docs: …`, `chore: …`, with a short body
saying why. One change per commit.

## Reporting a bug

Use the bug template. It asks for `doctor.sh` output, which holds no
passwords, and the part of `setup.sh` output that went wrong.
