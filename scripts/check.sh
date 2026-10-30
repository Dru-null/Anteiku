#!/usr/bin/env bash
# ============================================================
#  check.sh — every automated check, in one place.
#
#    ./scripts/check.sh         lint, parse, compose, setup.sh runs
#    ./scripts/check.sh --tui   also drive the picker in a real terminal
#                               (needs python3 with venv; downloads pyte)
#
#  Run it before every commit. Exits non-zero if anything failed.
#  Starts no containers and writes nothing here: setup.sh runs in a
#  temporary copy, with its own prefix and project name.
#
#  Needs bash, git and Docker. shellcheck and python3 are used from the
#  host when installed, otherwise from a container.
#
#  LEAK_PATTERNS_FILE=<file>  extra patterns to keep out of the repo (your
#  name, your LAN), one extended regex per line. Keep that file outside
#  the repo. Matches are reported by file name only.
# ============================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# A clean environment, always. Your shell may export real passwords;
# setup.sh must be tested without them, and they must never reach the
# output of a check that might run in public CI.
if [ -z "${ANTEIKU_CHECK_CLEAN:-}" ]; then
  keep=(ANTEIKU_CHECK_CLEAN=1 "PATH=$PATH" "HOME=$HOME")
  for v in TERM LANG LC_ALL LC_CTYPE NO_COLOR CI DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG LEAK_PATTERNS_FILE; do
    [ -n "${!v:-}" ] && keep+=("$v=${!v}")
  done
  exec env -i "${keep[@]}" bash "$0" "$@"
fi

# shellcheck source=lib/detect.sh
. lib/detect.sh

TUI=0
for a in "$@"; do case "$a" in
  --tui) TUI=1 ;;
  -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
  *) echo "unknown option: $a (try --help)" >&2; exit 2 ;;
esac; done

ROOT="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SHELLCHECK_IMAGE="koalaman/shellcheck:v0.11.0"
PYTHON_IMAGE="python:3.12.16-alpine3.24"
PYTE_VERSION="0.8.2"
# Only these may appear in yaml without a :-default (ARCHITECTURE.md).
ALLOWED_BARE="APPDATA MEDIA_ROOT PGID PUID STACK_PREFIX TZ UMASK"

banner "anteiku $S_DOT check" "everything that can be checked without starting it"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  err "Not a git checkout. check.sh lists files with git."; exit 1
fi
have docker || { err "Docker not found. Most checks need it."; exit 1; }

# Everything that would be committed: tracked, plus new files not ignored.
FILES=()
while IFS= read -r -d '' f; do [ -e "$f" ] && FILES+=("$f"); done \
  < <(git ls-files -z -co --exclude-standard)
SH=();  for f in "${FILES[@]}"; do case "$f" in *.sh) SH+=("$f") ;; esac; done
PY=();  for f in "${FILES[@]}"; do case "$f" in *.py) PY+=("$f") ;; esac; done

# python3 from the host if it has one, otherwise from a container.
# Always run from the repo root, with repo-relative paths.
py() {
  if have python3; then python3 -I -B "$@"
  else docker run --rm -i -v "$ROOT:/src:ro" -w /src "$PYTHON_IMAGE" python -I -B "$@"
  fi
}

indent() { sed 's/^/     /'; }

# The catalogue, straight from setup.sh: key|stack|...
CATALOGUE="$(sed -n '/^CATALOGUE="$/,/^"$/{/|/p}' setup.sh)"
KEYS=$(cut -d'|' -f1 <<< "$CATALOGUE")
STACKS=$(cut -d'|' -f2 <<< "$CATALOGUE" | sort -u)
[ -n "$KEYS" ] || err "Could not read CATALOGUE from setup.sh"

# ------------------------------------------------------------ shell
h1 "Shell"
n=0
for f in "${SH[@]}"; do bash -n "$f" || { err "bash -n: $f"; n=$((n+1)); }; done
[ "$n" -eq 0 ] && ok "bash -n: ${#SH[@]} scripts"

if have shellcheck; then
  out="$(shellcheck -x "${SH[@]}" 2>&1)"; rc=$?; how="shellcheck $(shellcheck --version | awk '/^version/{print $2}')"
else
  docker image inspect "$SHELLCHECK_IMAGE" >/dev/null 2>&1 || docker pull -q "$SHELLCHECK_IMAGE" >/dev/null
  out="$(docker run --rm -v "$ROOT:/mnt:ro" -w /mnt "$SHELLCHECK_IMAGE" -x "${SH[@]}" 2>&1)"; rc=$?; how="$SHELLCHECK_IMAGE"
fi
if [ "$rc" -eq 0 ]; then ok "shellcheck: clean ($how)"
else err "shellcheck: findings ($how)"; printf '%s\n' "$out" | indent; fi

# ------------------------------------------------------------ parse
h1 "Parse"
if [ "${#PY[@]}" -gt 0 ]; then
  if out="$(py -c 'import ast,sys
for f in sys.argv[1:]: ast.parse(open(f).read(), f)' "${PY[@]}" 2>&1)"
  then ok "python: ${#PY[@]} files parse"
  else err "python: parse error"; printf '%s\n' "$out" | indent; fi
fi

# YAML is parsed by docker compose below: it is the only consumer, and it
# also checks the schema. Here, make sure every file is actually reached.
n=0
for f in stacks/*.yaml; do
  grep -qE "^[[:space:]]*- path: $f\$" compose.yaml || { err "$f is not included in compose.yaml"; n=$((n+1)); }
done
for k in $STACKS; do
  [ -f "stacks/$k.yaml" ] || { err "catalogue stack '$k' has no stacks/$k.yaml"; n=$((n+1)); }
  [ -f "stacks/$k.md" ]   || { err "catalogue stack '$k' has no guide stacks/$k.md"; n=$((n+1)); }
done
[ "$n" -eq 0 ] && ok "every stack file is included and has a guide"

# ------------------------------------------------------------ rules
h1 "Rules"
# Bare variables: compose parses every included file, even for profiles
# that are off, so one ${VAR} without a default breaks every stack.
bare="$(sed -e 's/[[:space:]]#.*$//' -e 's/^#.*$//' -e 's/\$\$//g' stacks/*.yaml hw/*.yaml compose.yaml \
  | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*(:?\?[^}]*)?\}|\$[A-Za-z_][A-Za-z0-9_]*' \
  | sed -E 's/^\$\{?([A-Za-z0-9_]+).*/\1/' | sort -u)"
extra="$(comm -23 <(printf '%s\n' "$bare") <(tr ' ' '\n' <<< "$ALLOWED_BARE"))"
if [ -z "$extra" ]; then ok "bare variables: only the allowed ones"
else err "variables without a :-default: $(echo "$extra" | tr '\n' ' ')"
     note "Add a default (\${VAR:-value}) or have setup.sh always write it."; fi

# Monitor drift: a service with no monitor is never watched.
mon="$(sed -n '/^CATALOGUE = """$/,/^"""$/{/|/p}' scripts/kuma-monitors.py | cut -d'|' -f1)"
miss="$(comm -23 <(grep -vx uptime-kuma <<< "$KEYS" | sort) <(sort <<< "$mon"))"
orph="$(comm -13 <(sort <<< "$KEYS") <(sort <<< "$mon"))"
[ -n "$miss" ] && err "no monitor in kuma-monitors.py for: $(echo "$miss" | tr '\n' ' ')"
[ -n "$orph" ] && err "monitor for a service not in the catalogue: $(echo "$orph" | tr '\n' ' ')"
[ -z "$miss$orph" ] && ok "monitors: every service has one ($(wc -l <<< "$mon"))"

# Images pinned: a moving tag means two installs a month apart run
# different software (docs/updating.md). The form is repo:${X_VERSION:-tag},
# or repo:tag for images that must not be overridden.
n=0; c=0
while IFS= read -r line; do
  ref="${line#*image:}"; ref="${ref//[[:space:]\"\']/}"; where="${line%%:*}"
  c=$((c+1))
  if [[ $ref =~ ^[^$]+:\$\{[A-Z0-9_]+_VERSION:-([^}]+)\}$ ]]; then tag="${BASH_REMATCH[1]}"
  elif [[ $ref == *\$* ]]; then err "image: use \${NAME_VERSION:-tag}: $ref ($where)"; n=$((n+1)); continue
  elif [[ ${ref##*/} == *:* ]]; then tag="${ref##*:}"
  else tag=""; fi
  if [ -z "$tag" ] || [[ $tag =~ ^(latest|release|stable|master|main|nightly|develop|dev|edge|beta)$ ]] \
     || [[ $tag =~ ^v?[0-9]+(-[a-z0-9]+)?$ ]] || [[ $tag == version-* ]]; then
    err "image not pinned to an exact version: $ref ($where)"; n=$((n+1))
  fi
done < <(grep -HE '^[[:space:]]*image:' stacks/*.yaml hw/*.yaml compose.yaml)
[ "$n" -eq 0 ] && ok "images: all $c pinned to an exact version"
k_py="$(sed -n 's/^PYTHON_IMAGE="\(.*\)"$/\1/p' scripts/kuma-bootstrap.sh)"
[ "$k_py" = "$PYTHON_IMAGE" ] || err "kuma-bootstrap.sh and check.sh use different Python images (${k_py:-none} vs $PYTHON_IMAGE)"

# ------------------------------------------------------------ leaks
h1 "Leaks"
# Built-in: things that are never right in a public repo. This file
# describes them, so it is skipped here; it is still covered by your own
# patterns below.
BUILTIN='-----BEGIN [A-Z ]*PRIVATE KEY|sk-(ant|or-v1)-|gh[pousr]_[A-Za-z0-9]{30}|github_pat_|AKIA[0-9A-Z]{16}|xox[abpr]-[0-9]|tail[0-9a-f]{4,}\.ts\.net|/home/([a-z_][a-z0-9_-]*)'
# grep exits 2 on an error. Treat that as a failure, never as "clean".
scan=(); for f in "${FILES[@]}"; do [ "$f" = scripts/check.sh ] || scan+=("$f"); done
hits="$(grep -aoHE -e "$BUILTIN" -- "${scan[@]}")"
rc=$?
if [ "$rc" -gt 1 ]; then err "leak scan: grep failed (exit $rc)"
else
  # /home/you is the placeholder the docs use. Show the file, not the match.
  hits="$(grep -v ':/home/you$' <<< "$hits" | cut -d: -f1 | sort -u)"
  if [ -z "$hits" ]; then ok "no keys, tokens, home paths or tailnet names"
  else while IFS= read -r f; do err "possible secret or personal path: $f"; done <<< "$hits"; fi
fi

if [ -n "${LEAK_PATTERNS_FILE:-}" ]; then
  if [ -r "$LEAK_PATTERNS_FILE" ]; then
    pat="$(grep -vE '^[[:space:]]*(#|$)' "$LEAK_PATTERNS_FILE" | paste -sd'|')"
    # -l: name the file, never print the match. It is what we are hiding.
    hits="$(grep -laiE -e "$pat" -- "${FILES[@]}")"; rc=$?
    if [ "$rc" -gt 1 ]; then err "your patterns: grep failed (exit $rc)"
    elif [ -z "$hits" ]; then ok "your patterns: no matches ($(grep -cvE '^[[:space:]]*(#|$)' "$LEAK_PATTERNS_FILE") patterns)"
    else while IFS= read -r f; do err "matches your leak patterns: $f"; done <<< "$hits"; fi
  else err "LEAK_PATTERNS_FILE is set but not readable"; fi
else
  info "no LEAK_PATTERNS_FILE: personal names and addresses not checked"
fi

# Images: tools embed metadata (camera, location, the software that made
# it). PNGs may keep only the chunks needed to draw them.
imgs=(); for f in "${FILES[@]}"; do case "$f" in *.png|*.jpg|*.jpeg|*.gif|*.webp) imgs+=("$f") ;; esac; done
if [ "${#imgs[@]}" -gt 0 ]; then
  if out="$(py -c 'import struct,sys
bad = 0
for f in sys.argv[1:]:
    d = open(f, "rb").read()
    if not f.endswith(".png"):
        print(f + ": only PNG is checked; convert it or extend check.sh"); bad = 1; continue
    i, extra = 8, []
    while i < len(d):
        n, t = struct.unpack(">I4s", d[i:i+8]); i += 12 + n
        if t not in (b"IHDR", b"PLTE", b"tRNS", b"IDAT", b"IEND"): extra.append(t.decode("latin-1"))
    if extra: print(f + ": metadata chunks " + " ".join(sorted(set(extra)))); bad = 1
sys.exit(bad)' "${imgs[@]}" 2>&1)"
  then ok "images: no metadata (${#imgs[@]})"
  else err "images carry metadata"; printf '%s\n' "$out" | indent; fi
fi

# State that belongs to one install must never be committable.
n=0
for f in "${FILES[@]}"; do
  case "/$f" in
    */.env.example) ;;
    */.env|*/.env.*|*/ports.md|*/__pycache__/*|*.pyc|/appdata/*|/media/*|/photos/*|/testdata/*|/backup-logs/*|*.bak|*.log)
      err "install state would be committed: $f"; n=$((n+1)) ;;
  esac
done
for p in .env .env.bak ports.md appdata/x media/x photos/x backup-logs/x scripts/__pycache__/x.pyc; do
  git check-ignore -q --no-index "$p" || { err ".gitignore does not cover $p"; n=$((n+1)); }
done
[ "$n" -eq 0 ] && ok "no install state committable; .gitignore covers it"

# ------------------------------------------------------------ compose
h1 "Compose"
# The committable files only, so a local .env cannot hide a problem.
mkdir -p "$WORK/repo"
printf '%s\0' "${FILES[@]}" | tar -cf - --null -T - | tar -xf - -C "$WORK/repo"

# Only the variables yaml may use bare. Anything else that compose finds
# unset is a bug, and compose only warns about it, so the warning is
# treated as a failure here.
mkenv() {
  printf '%s\n' "PUID=$(id -u)" "PGID=$(id -g)" "TZ=Etc/UTC" "UMASK=002" \
    "APPDATA=./appdata" "MEDIA_ROOT=./media" "STACK_PREFIX=chk-" \
    "COMPOSE_PROFILES=$1" "COMPOSE_FILE=$2" > "$WORK/compose.env"
}
FAILED=(); FIRST_OUT=""; c=0
compose_ok() { # label profiles compose-files
  local out rc
  c=$((c+1)); mkenv "$2" "$3"
  out="$(cd "$WORK/repo" && docker compose --env-file "$WORK/compose.env" -p anteiku-check config -q 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] || grep -q 'variable is not set' <<< "$out"; then
    FAILED+=("$1"); [ -n "$FIRST_OUT" ] || FIRST_OUT="$(sed -E 's/^time="[^"]*" //' <<< "$out" | sort -u)"
  fi
}
ALL="$(paste -sd, <<< "$KEYS")"
compose_ok "no services" "" compose.yaml
compose_ok "every service" "$ALL" compose.yaml
for s in $STACKS; do
  compose_ok "stack $s alone" "$(awk -F'|' -v s="$s" '$2==s{print $1}' <<< "$CATALOGUE" | paste -sd,)" compose.yaml
done
for k in $KEYS; do compose_ok "$k alone" "$k" compose.yaml; done
for h in hw/*.yaml; do compose_ok "every service + $h" "$ALL" "compose.yaml:$h"; done
if [ "${#FAILED[@]}" -eq 0 ]; then ok "compose config: $c combinations valid, no unset variables"
else
  err "compose config: ${#FAILED[@]} of $c combinations fail"
  note "$(printf '%s, ' "${FAILED[@]:0:4}")$([ "${#FAILED[@]}" -gt 4 ] && echo "and $(( ${#FAILED[@]} - 4 )) more")"
  note "first failure (${FAILED[0]}):"; printf '%s\n' "$FIRST_OUT" | head -n 10 | indent
fi

# ------------------------------------------------------------ setup.sh
h1 "setup.sh"
# Its own prefix, project and network, so it can run beside a real stack.
# NTFY_PASS is a canary: secrets must never come from the environment.
CANARY="canary$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
S="$WORK/repo"
run_setup() { # log-name args...
  local log="$WORK/$1.log"; shift
  (cd "$S" && env -i "PATH=$PATH" "HOME=$HOME" ${DOCKER_HOST:+"DOCKER_HOST=$DOCKER_HOST"} \
    STACK_PREFIX=chk- COMPOSE_PROJECT_NAME=anteiku-check DOCKER_NETWORK=anteiku-check \
    APPDATA=./appdata MEDIA_ROOT=./media PHOTOS_LOCATION=./photos NTFY_PASS="$CANARY" \
    ./setup.sh "$@" < /dev/null > "$log" 2>&1)
}
# Secret values from .env must not appear in any output. Compared, never shown.
leaks_in() { # log
  local k v
  grep -q "$CANARY" "$1" && { echo "the NTFY_PASS from the environment"; return; }
  [ -f "$S/.env" ] || return 0
  for k in $SECRET_KEYS; do
    v="$(sed -n "s/^$k=//p" "$S/.env")"
    [ -n "$v" ] && grep -qF -- "$v" "$1" && echo "$k"
  done
}
step() { # label log rc
  local l; l="$(leaks_in "$WORK/$2.log")"
  [ -f "$S/.env" ] && grep -q "$CANARY" "$S/.env" && err "$1: NTFY_PASS was taken from the environment into .env"
  if [ "$3" -ne 0 ]; then err "$1: exit $3"; tail -n 15 "$WORK/$2.log" | indent
  elif [ -n "$l" ]; then err "$1: printed a secret ($(echo "$l" | tr '\n' ' '))"
  else ok "$1: exit 0, no secrets printed"; fi
}
SECRET_KEYS="$(sed -n 's/^SECRET_KEYS="\(.*\)"$/\1/p' setup.sh)"
secrets() { grep -E "^(${SECRET_KEYS// /|})=" "$S/.env"; }

run_setup dry1 --dry-run --yes; rc=$?
step "first run, --dry-run --yes" dry1 "$rc"
[ -e "$S/.env" ] && err "--dry-run wrote .env"

run_setup yes1 --yes; rc=$?
step "first run, --yes" yes1 "$rc"
if [ -f "$S/.env" ]; then
  [ "$(stat -c %a "$S/.env")" = "600" ] || err ".env is not mode 600"
  # Re-runs are how people add services. Picking needs a terminal, so
  # mark services installed in .env instead: setup.sh then generates
  # their secrets and ports as on a real add. (--tui covers the picker.)
  sed -i "s/^COMPOSE_PROFILES=\(.*\)/COMPOSE_PROFILES=\1,ntfy,vaultwarden/" "$S/.env"
  run_setup yes2 --yes; rc=$?
  step "re-run, + ntfy and vaultwarden" yes2 "$rc"
  secrets > "$WORK/secrets1"
  sed -i "s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=$ALL/" "$S/.env"
  # A version override is how users roll back; a re-run must keep it.
  echo "SONARR_VERSION=0.0.0-check" >> "$S/.env"
  run_setup yes3 --yes; rc=$?
  step "re-run, + every other service" yes3 "$rc"
  if ! grep -qx 'SONARR_VERSION=0.0.0-check' "$S/.env"; then err "re-run dropped a version override from .env"
  elif ! grep -q 'held at a version override: SONARR_VERSION' "$WORK/yes3.log"; then err "re-run did not warn about the version override"
  else ok "re-run kept the version override and said so"; fi
  # A re-run must keep every existing secret (a database reads its
  # password once). Lines from before that are gone were changed.
  if [ ! -s "$WORK/secrets1" ]; then err "re-run test: no secrets were generated to compare"
  elif secrets | grep -qvxFf - "$WORK/secrets1"; then
    err "re-run changed an existing secret"
  else ok "re-run kept the existing secrets ($(wc -l < "$WORK/secrets1"))"; fi
  sum="$(sha256sum < "$S/.env")"
  run_setup dry2 --dry-run --yes; rc=$?
  step "re-run, --dry-run --yes" dry2 "$rc"
  [ "$(sha256sum < "$S/.env")" = "$sum" ] || err "--dry-run changed .env"
  out="$(cd "$S" && env -i "PATH=$PATH" "HOME=$HOME" ${DOCKER_HOST:+"DOCKER_HOST=$DOCKER_HOST"} docker compose config -q 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] || grep -q 'variable is not set' <<< "$out"; then
    err "compose config on the generated .env"; sort -u <<< "$out" | indent
  else ok "compose config on the generated .env: valid"; fi
else
  err "--yes wrote no .env"
fi

# ------------------------------------------------------------ picker
if [ "$TUI" -eq 1 ]; then
  h1 "Picker (pty)"
  if ! have python3; then err "--tui needs python3 on the host"
  elif ! python3 -m venv "$WORK/venv" >/dev/null 2>&1 || ! "$WORK/venv/bin/pip" install -q "pyte==$PYTE_VERSION" >/dev/null 2>&1; then
    err "--tui: could not set up a venv with pyte $PYTE_VERSION"
  else
    rm -f "$S/.env" "$S/.env.bak" "$S/ports.md"
    out="$(cd "$S" && env -i "PATH=$PATH" "HOME=$HOME" ${DOCKER_HOST:+"DOCKER_HOST=$DOCKER_HOST"} \
      STACK_PREFIX=chk- COMPOSE_PROJECT_NAME=anteiku-check DOCKER_NETWORK=anteiku-check \
      APPDATA=./appdata MEDIA_ROOT=./media PHOTOS_LOCATION=./photos \
      "$WORK/venv/bin/python" -I tests/tui_drive.py . 40 110 --dry-run \
      '[["snap","picker"],["key","DOWN SPACE"],["snap","toggled"],["key","ENTER"],["wait","4"],["snap","end"]]' 2>&1)"
    # The second row's toggle must change the count in the header.
    n1="$(sed -n '/= picker =/,/= toggled =/{s/.* \([0-9][0-9]*\) selected.*/\1/p}' <<< "$out" | head -n 1)"
    n2="$(sed -n '/= toggled =/,/= end =/{s/.* \([0-9][0-9]*\) selected.*/\1/p}' <<< "$out" | head -n 1)"
    if [ -z "$n1" ] || ! grep -q 'anteiku' <<< "$out"; then
      err "picker did not draw"; tail -n 20 <<< "$out" | indent
    elif [ -z "$n2" ] || [ "$n1" = "$n2" ]; then
      err "picker did not react to SPACE ($n1 -> ${n2:-?} selected)"
    elif ! grep -q 'EXIT=0' <<< "$out" || ! grep -q 'Selected:' <<< "$out"; then
      err "picker run did not exit 0"; tail -n 20 <<< "$out" | indent
    else ok "picker drew, toggled a row ($n1 -> $n2 selected), exited 0"; fi
  fi
fi

# ------------------------------------------------------------ result
echo
if [ "$FINDINGS_ERR" -eq 0 ]; then ok "All checks passed."; exit 0; fi
err "$FINDINGS_ERR check(s) failed."
exit 1
