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
#  Needs bash, git and Docker. shellcheck always runs from its pinned
#  image; python3 from the host when installed, else from a container.
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
  -h|--help) sed -n '2,/^# ===/s/^# \{0,2\}//p' "scripts/${0##*/}"; exit 0 ;;
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

# Always the pinned image, never a host binary: each shellcheck release
# adds rules, so a host copy (CI's runner has its own) would make local
# and CI results differ.
if ! docker image inspect "$SHELLCHECK_IMAGE" >/dev/null 2>&1 \
   && ! docker pull -q "$SHELLCHECK_IMAGE" >/dev/null; then
  err "shellcheck: could not pull $SHELLCHECK_IMAGE"
else
  how="shellcheck $(docker run --rm "$SHELLCHECK_IMAGE" --version | awk '/^version/{print $2}')"
  out="$(docker run --rm -v "$ROOT:/mnt:ro" -w /mnt "$SHELLCHECK_IMAGE" -x "${SH[@]}" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then ok "shellcheck: clean ($how)"
  else err "shellcheck: findings ($how)"; printf '%s\n' "$out" | indent; fi
fi

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
# update.sh decides from CHANGELOG.md whether a release may install by
# itself: every entry needs an Action needed, and "None." must read as none.
n_rel="$(grep -c '^## [0-9]' CHANGELOG.md)"; n_act="$(grep -c '^### Action needed' CHANGELOG.md)"
got="$(printf '%s\n' '## 9.1.1 — x' '### Action needed' 'Do this.' '### Versions' '## 9.1.0 — x' \
       '### Action needed' '' 'None.' '## 9.0.0 — x' '### Action needed' 'Old.' \
       | (. lib/release.sh; changelog_since 9.0.0 9.1.1 | action_needed) | tr '\n' '|')"
if [ "$n_rel" -eq 0 ] || [ "$n_rel" != "$n_act" ]; then err "CHANGELOG.md: $n_rel release(s), $n_act Action needed section(s)"
elif [ "$got" != "9.1.1:|Do this.|" ]; then err "lib/release.sh misreads Action needed: $got"
else ok "CHANGELOG: $n_rel release(s), each with Action needed; update.sh reads them"; fi
k_py="$(sed -n 's/^PYTHON_IMAGE="\(.*\)"$/\1/p' scripts/kuma-bootstrap.sh)"
[ "$k_py" = "$PYTHON_IMAGE" ] || err "kuma-bootstrap.sh and check.sh use different Python images (${k_py:-none} vs $PYTHON_IMAGE)"

# A script's option loop, read and never run (T-085, T-086): the
# case "$a" in ... esac that holds -h|--help, one arm per line ending ;;.
# opt_loop <file> fills ARMS ("pattern<TAB>body" each); returns 1 if the
# loop is missing or can't be read. first_arm <option> sets HIT to the
# first arm the option matches (bash's own [[ == ]] on each | alternative,
# as case does), or "" if none.
opt_loop() {
  local loop line
  ARMS=()
  loop="$(awk '/case "\$a" in$/ { buf = ""; on = 1 }
    on { buf = buf $0 "\n" }
    on && /^[[:space:]]*esac/ { if (buf ~ /-h\|--help\)/) { printf "%s", buf; exit } on = 0 }' "$1")"
  [ -n "$loop" ] || return 1
  while IFS= read -r line; do
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ $line =~ ^[[:space:]]*([^[:space:]()]+)\)[[:space:]]+(.*\;\;)[[:space:]]*$ ]] \
       && [[ ${BASH_REMATCH[1]} != *[\"\'\$\\]* ]]; then
      ARMS+=("${BASH_REMATCH[1]}"$'\t'"${BASH_REMATCH[2]}")
    else return 1; fi
  done < <(sed '1d;$d' <<< "$loop")
}
first_arm() {
  local arm alt alts
  HIT=""
  for arm in "${ARMS[@]}"; do
    IFS='|' read -ra alts <<< "${arm%%$'\t'*}"
    for alt in "${alts[@]}"; do
      # shellcheck disable=SC2053  # $alt is a glob: the script's own case pattern
      if [[ $1 == $alt ]]; then HIT="$arm"; return; fi
    done
  done
}

# --help prints the script's comment header and nothing else: no code
# after it, nothing cut off, and the same from another folder (the
# scripts cd before they read themselves). Every script with --help, and
# every executable one outside lib/ must have it (T-082). One without is
# named, never run: backup-cron.sh would have run a real backup. Nor is
# one whose loop can't be read, or where an earlier arm takes --help or
# -h (T-086: `--*) ;;` above it and the script ran for real).
n=0; c=0
for f in "${SH[@]}"; do
  if ! grep -q -- '-h|--help)' "$f"; then
    case "$f" in lib/*) continue ;; esac
    [ -x "$f" ] || continue
    err "--help: $f is executable but has no -h|--help option (not run)"; n=$((n+1)); c=$((c+2))
    continue
  fi
  if ! opt_loop "$f"; then
    err "--help: $f: can't read its option loop (not run)"; n=$((n+1)); c=$((c+2)); continue
  fi
  shadow=""
  for p in --help -h; do
    first_arm "$p"
    if [ -z "$HIT" ]; then shadow="no arm matches $p"; break; fi
    if [ "${HIT%%$'\t'*}" != "-h|--help" ]; then
      shadow="$p first matches '${HIT%%$'\t'*})', not the -h|--help arm"; break
    fi
  done
  if [ -n "$shadow" ]; then
    err "--help: $f: $shadow (not run)"; n=$((n+1)); c=$((c+2)); continue
  fi
  for how in "./$f" "../$f"; do
    c=$((c+1))
    if [ "$how" = "./$f" ]; then dir="$ROOT"; from="the repo"; else dir="$ROOT/lib"; from="lib/"; fi
    out="$( cd "$dir" && bash "$how" --help 2>"$WORK/help.err" )"; rc=$?
    bad=""
    [ "$rc" -eq 0 ] || bad="$bad exit $rc;"
    [ -s "$WORK/help.err" ] && bad="$bad stderr: $(head -n 1 "$WORK/help.err");"
    grep -qF "${f##*/} —" <<< "$out" || bad="$bad no '${f##*/} —' title;"
    code="$(grep -cE '^(set |cd |\. |shellcheck )' <<< "$out")"
    [ "$code" -eq 0 ] || bad="$bad $code line(s) of code;"
    [[ "$(tail -n 1 <<< "$out")" =~ ^=+$ ]] || bad="$bad last line is not the closing ==== rule;"
    [ -z "$bad" ] || { err "--help: $how (from $from):$bad"; n=$((n+1)); }
  done
done
if [ "$c" -eq 0 ]; then err "--help: no script with --help found"
elif [ "$n" -eq 0 ]; then ok "--help: $((c / 2)) scripts print their header only, from here and from lib/"
else note "--help: $n problem(s) in $((c / 2)) scripts"; fi

# An option a script doesn't know is refused before any work (T-085): in
# the option loop that holds -h|--help, the first arm an unknown option
# matches must exit 2 with its message on stderr. Read, never run: a
# script whose refusal is missing would do its work (backup-cron.sh: a
# backup and a notification). The --help runs above show the loop comes
# before the work. One arm per line, ending ;;, or it can't be read.
n=0; c=0
for f in "${SH[@]}"; do
  grep -q -- '-h|--help)' "$f" || continue
  c=$((c+1))
  if ! opt_loop "$f"; then
    err "unknown options: $f: can't read its option loop (one arm per line, ending ;;)"; n=$((n+1)); continue
  fi
  for p in --no-such-option -Z; do
    first_arm "$p"
    if [ -z "$HIT" ]; then
      err "unknown options: $f runs on with $p: no arm matches it"; n=$((n+1))
    elif [[ ${HIT#*$'\t'} != *'>&2'*'exit 2'* ]]; then
      err "unknown options: $f runs on with $p: arm '${HIT%%$'\t'*})' doesn't exit 2 with a message on stderr"; n=$((n+1))
    fi
  done
done
if [ "$c" -eq 0 ]; then err "unknown options: no script with an option loop found"
elif [ "$n" -eq 0 ]; then ok "unknown options: $c scripts refuse --no-such-option and -Z (exit 2, stderr; read, not run)"
else note "unknown options: $n problem(s) in $c scripts"; fi

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
    */.env|*/.env.*|*/ports.md|*/__pycache__/*|*.pyc|/appdata/*|/media/*|/photos/*|/testdata/*|/backup-logs/*|/update-logs/*|*.bak|*.log)
      err "install state would be committed: $f"; n=$((n+1)) ;;
  esac
done
for p in .env .env.bak ports.md appdata/x media/x photos/x backup-logs/x update-logs/x scripts/__pycache__/x.pyc; do
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

# ------------------------------------------------------------ detection
h1 "Detection (mocked)"
# lib/detect.sh, doctor.sh and setup.sh --dry-run on fake machines
# (tests/detect): GPUs, memory, arch, distros, Docker, ports, missing
# tools. Mocked: what the scripts make of that input, not that the
# hardware works. Runs here, before setup.sh below writes a .env.
out="$(cd "$WORK/repo" && bash tests/detect/run.sh -q 2>&1)"; rc=$?
sum="$(tail -n 1 <<< "$out")"
if [ "$rc" -eq 0 ] && [[ $sum =~ ^([0-9]+)\ cases,\ ([0-9]+)\ checks,\ 0\ failed ]] && [ "${BASH_REMATCH[1]}" -gt 0 ]; then
  ok "detection: ${sum%%;*}"
  [[ $sum == *";"* ]] && note "${sum#*; }"
else
  err "detection: ${sum:-no result} (exit $rc)"; sed '$d' <<< "$out" | head -n 40 | indent
fi

# ------------------------------------------------------------ setup.sh
h1 "setup.sh"
# Its own prefix, project and network, so it can run beside a real stack.
# NTFY_PASS is a canary: secrets must never come from the environment.
CANARY="canary$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
S="$WORK/repo"
run_setup() { # log-name [VAR=value...] args...   (a VAR given here wins)
  local log="$WORK/$1.log" extra=(); shift
  while [[ "${1:-}" == [A-Z]*=* ]]; do extra+=("$1"); shift; done
  (cd "$S" && env -i "PATH=$PATH" "HOME=$HOME" ${DOCKER_HOST:+"DOCKER_HOST=$DOCKER_HOST"} \
    STACK_PREFIX=chk- COMPOSE_PROJECT_NAME=anteiku-check DOCKER_NETWORK=anteiku-check \
    APPDATA=./appdata MEDIA_ROOT=./media PHOTOS_LOCATION=./photos NTFY_PASS="$CANARY" \
    "${extra[@]}" ./setup.sh "$@" < /dev/null > "$log" 2>&1)
}
# A dry run writes nothing at all (T-041): every path in the copy, before and after.
tree_of() { (cd "$S" && find . -mindepth 1 | LC_ALL=C sort); }
wrote_nothing() { # what before-file
  local new; new="$(tree_of | LC_ALL=C comm -13 "$2" -)"
  if [ -n "$new" ]; then err "$1 created files or folders:"; printf '%s\n' "$new" | head -n 10 | indent
  else ok "$1 wrote nothing ($(wc -l < "$2") paths compared)"; fi
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
# A log's last lines, unless they would show a secret (CI logs are public).
tail_of() { # log
  if [ -n "$(leaks_in "$1")" ]; then note "(output not shown: it holds a secret)"
  else tail -n 15 "$1" | indent; fi
}
step() { # label log rc
  local l; l="$(leaks_in "$WORK/$2.log")"
  [ -f "$S/.env" ] && grep -q "$CANARY" "$S/.env" && err "$1: NTFY_PASS was taken from the environment into .env"
  if [ "$3" -ne 0 ]; then err "$1: exit $3"; tail_of "$WORK/$2.log"
  elif [ -n "$l" ]; then err "$1: printed a secret ($(echo "$l" | tr '\n' ' '))"
  else ok "$1: exit 0, no secrets printed"; fi
}
SECRET_KEYS="$(sed -n 's/^SECRET_KEYS="\(.*\)"$/\1/p' setup.sh)"
secrets() { grep -E "^(${SECRET_KEYS// /|})=" "$S/.env"; }

tree_of > "$WORK/tree-dry1"
run_setup dry1 --dry-run --yes; rc=$?
step "first run, --dry-run --yes" dry1 "$rc"
[ -e "$S/.env" ] && err "--dry-run wrote .env"
wrote_nothing "first run, --dry-run" "$WORK/tree-dry1"

run_setup yes1 --yes; rc=$?
step "first run, --yes" yes1 "$rc"
if [ -f "$S/.env" ]; then
  [ "$(stat -c %a "$S/.env")" = "600" ] || err ".env is not mode 600"
  cp "$S/.env" "$WORK/env1"
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
  sed -i 's/^UPDATE_MODE=.*/UPDATE_MODE=off/' "$S/.env"
  # The off-site keys are the user's (T-011): kept as they are, a base64
  # password's trailing "=" too, and the password never shown. Checked by
  # value: SECRET_KEYS, which the leak check reads, comes from setup.sh.
  OFF_DIR="$WORK/offsite-check"; OFF_PW="chk$(od -An -N9 -tx1 /dev/urandom | tr -d ' \n')="
  # Cloud keys (T-089): carried as they are, both hidden. The secret has
  # the characters real ones have (/ + and a trailing =).
  OFF_ID="CHKID$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  OFF_SK="chk/$(od -An -N9 -tx1 /dev/urandom | tr -d ' \n')+x="
  printf 'OFFSITE_REPO=%s\nOFFSITE_PASSWORD=%s\nOFFSITE_PHOTOS=yes\n' "$OFF_DIR" "$OFF_PW" >> "$S/.env"
  printf 'OFFSITE_ACCESS_KEY_ID=%s\nOFFSITE_SECRET_ACCESS_KEY=%s\n' "$OFF_ID" "$OFF_SK" >> "$S/.env"
  run_setup yes3 --yes; rc=$?
  step "re-run, + every other service" yes3 "$rc"
  miss=""
  for l in "OFFSITE_REPO=$OFF_DIR" "OFFSITE_PASSWORD=$OFF_PW" "OFFSITE_PHOTOS=yes" \
           "OFFSITE_ACCESS_KEY_ID=$OFF_ID" "OFFSITE_SECRET_ACCESS_KEY=$OFF_SK"; do
    grep -qxF -- "$l" "$S/.env" || miss="$miss ${l%%=*}"
  done
  if [ -n "$miss" ]; then err "re-run did not keep the off-site keys as they were:$miss"
  elif grep -qF -- "$OFF_PW" "$WORK/yes3.log"; then err "re-run printed OFFSITE_PASSWORD"
  elif grep -qF -- "$OFF_SK" "$WORK/yes3.log"; then err "re-run printed OFFSITE_SECRET_ACCESS_KEY"
  elif grep -qF -- "$OFF_ID" "$WORK/yes3.log"; then err "re-run printed OFFSITE_ACCESS_KEY_ID"
  else ok "re-run kept the off-site keys (a password ending in = too), password and cloud keys not shown"; fi
  if ! grep -qx 'SONARR_VERSION=0.0.0-check' "$S/.env"; then err "re-run dropped a version override from .env"
  elif ! grep -q 'held at a version override: SONARR_VERSION' "$WORK/yes3.log"; then err "re-run did not warn about the version override"
  else ok "re-run kept the version override and said so"; fi
  # Asked once (T-008): --yes on a fresh install writes the default,
  # a re-run keeps whatever is there.
  if ! grep -qx 'UPDATE_MODE=notify' "$WORK/env1"; then err "first --yes did not write UPDATE_MODE=notify"
  elif ! grep -qx 'UPDATE_MODE=off' "$S/.env"; then err "re-run did not keep UPDATE_MODE=off"
  else ok "UPDATE_MODE: notify by default, kept by a re-run"; fi
  # A re-run must keep every existing secret (a database reads its
  # password once). Lines from before that are gone were changed.
  if [ ! -s "$WORK/secrets1" ]; then err "re-run test: no secrets were generated to compare"
  elif secrets | grep -qvxFf - "$WORK/secrets1"; then
    err "re-run changed an existing secret"
  else ok "re-run kept the existing secrets ($(wc -l < "$WORK/secrets1"))"; fi
  # A service that left the catalogue (Diun, T-020): a re-run drops the
  # profile and must say so, with its data dir, not go silent.
  sed -i "s/^COMPOSE_PROFILES=\(.*\)/COMPOSE_PROFILES=\1,retired-check/" "$S/.env"
  mkdir -p "$S/appdata/retired-check"
  prof_before="$(sed -n 's/^COMPOSE_PROFILES=//p' "$S/.env")"
  run_setup yes4 --yes; rc=$?
  step "re-run, a profile no longer in the catalogue" yes4 "$rc"
  if grep -q 'retired-check' <<< "$(sed -n 's/^COMPOSE_PROFILES=//p' "$S/.env")"; then err "re-run kept a profile that is not in the catalogue"
  elif ! grep -q 'No longer part of Anteiku' "$WORK/yes4.log" \
    || ! grep -qE 'retired-check \(no longer part of Anteiku' "$WORK/yes4.log" \
    || ! grep -qE 'its data, kept: +.*/appdata/retired-check' "$WORK/yes4.log"; then
    err "re-run did not explain the service that left the catalogue"; grep -A6 'No longer part' "$WORK/yes4.log" | indent
  else ok "re-run named the retired service and its data"; fi
  # update.sh keeps setup.sh's output in a log and passes this section
  # on (T-034): it must find it, and only it, even with a section after.
  { cat "$WORK/yes4.log"; printf '\n── After ──────\n  not this\n'; } > "$WORK/yes4-more.log"
  got="$(. lib/release.sh; retired_notice "$WORK/yes4-more.log")"
  if ! grep -qx '  retired-check' <<< "$got" || grep -q 'No longer part of Anteiku\|^\(──\|--\) ' <<< "$got" \
     || [ "$(tail -n 1 <<< "$got")" != "$(grep -m1 'service that is gone' "$WORK/yes4.log")" ]; then
    err "lib/release.sh misreads the retired-service section of setup.sh's output"; printf '%s\n' "$got" | indent
  else ok "update.sh finds the retired-service section ($(wc -l <<< "$got") lines)"; fi
  # The way back after such an update selects the service again (T-036):
  # update.sh compares COMPOSE_PROFILES from before setup.sh with after.
  # This run's real before/after, then the edge cases.
  n=0; bad=""
  while IFS='|' read -r before now want; do
    n=$((n+1))
    got="$(. lib/release.sh; profiles_dropped "$before" "$now")"
    [ "$got" = "$want" ] || bad="$bad [$before] vs [$now]: got [$got], want [$want];"
  done <<CASES
$prof_before|$(sed -n 's/^COMPOSE_PROFILES=//p' "$S/.env")|,retired-check
a,b,c|a,c|,b
a,b|a,b|
a,b||,a,b
|a|
a,,b|b|,a
a,Bad key,b|a|,b
CASES
  if [ -n "$bad" ]; then err "lib/release.sh profiles_dropped:$bad"
  else ok "update.sh's way back finds the dropped profiles ($n cases)"; fi
  sum="$(sha256sum < "$S/.env")"
  tree_of > "$WORK/tree-dry2"
  run_setup dry2 --dry-run --yes; rc=$?
  step "re-run, --dry-run --yes" dry2 "$rc"
  [ "$(sha256sum < "$S/.env")" = "$sum" ] || err "--dry-run changed .env"
  wrote_nothing "re-run, --dry-run" "$WORK/tree-dry2"
  # Every service selected (Immich too), all three paths in folders that
  # don't exist yet: nothing created, and still shown as absolute paths.
  run_setup dry3 APPDATA=./new/appdata MEDIA_ROOT=./new/media PHOTOS_LOCATION=./new/photos --dry-run --yes; rc=$?
  step "re-run, --dry-run, paths not created yet" dry3 "$rc"
  [ "$(sha256sum < "$S/.env")" = "$sum" ] || err "--dry-run changed .env"
  wrote_nothing "re-run, --dry-run, new paths" "$WORK/tree-dry2"
  n=0; for d in appdata media photos; do grep -qF "$S/new/$d" "$WORK/dry3.log" && n=$((n+1)); done
  if [ "$n" -ne 3 ]; then err "--dry-run with new paths showed $n of 3 as absolute paths"
  else ok "--dry-run resolved 3 of 3 paths that don't exist yet"; fi
  out="$(cd "$S" && env -i "PATH=$PATH" "HOME=$HOME" ${DOCKER_HOST:+"DOCKER_HOST=$DOCKER_HOST"} docker compose config -q 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] || grep -q 'variable is not set' <<< "$out"; then
    err "compose config on the generated .env"; sort -u <<< "$out" | indent
  else ok "compose config on the generated .env: valid"; fi
  # Same port inside and out (T-062): qBittorrent refuses (401) a Host
  # header whose port isn't the one it listens on. Catalogue port "=":
  # published = target = PORT_<KEY>, WEBUI_PORTS (hotio) the same, and
  # ports.md's "Inside Docker" names it. Also with the port moved.
  SAME="$(awk -F'|' '$5 == "=" {print $1}' <<< "$CATALOGUE")"
  n=0; bad=""
  for k in $SAME; do
    var="PORT_$(tr '[:lower:]-' '[:upper:]_' <<< "$k")"
    for moved in "" 8190; do
      want="${moved:-$(sed -n "s/^$var=//p" "$S/.env")}"
      got="$(cd "$S" && env -i "PATH=$PATH" "HOME=$HOME" ${DOCKER_HOST:+"DOCKER_HOST=$DOCKER_HOST"} \
        ${moved:+"$var=$moved"} docker compose config --format json 2>/dev/null | py -c '
import json, sys
svc = json.load(sys.stdin)["services"][sys.argv[1]]
ports = ["%s:%s" % (p.get("published"), p.get("target")) for p in svc.get("ports", [])]
print(" ".join(ports), svc.get("environment", {}).get("WEBUI_PORTS", "-"))
' "$k" 2>&1)"
      n=$((n+1))
      [ "$got" = "$want:$want $want/tcp" ] || bad="$bad $k${moved:+ (moved)}: [$got], want [$want:$want $want/tcp];"
    done
    grep -qF "| \`$k:$(sed -n "s/^$var=//p" "$S/.env")\` |" "$S/ports.md" || bad="$bad ports.md has no \`$k:<host port>\` row;"
  done
  if [ -z "$SAME" ]; then err "same-port services: none in the catalogue (expected qbittorrent)"
  elif [ -n "$bad" ]; then err "same port inside and out:$bad"
  else ok "same port inside and out: $SAME ($n configs, ports.md)"; fi
else
  err "--yes wrote no .env"
fi

# ------------------------------------------------------------ helper scripts
h1 "Helper scripts"
# The scripts users run later (T-018), on the .env setup.sh just wrote:
# every service, absolute paths. A renamed variable or a broken .env read
# would otherwise show only when someone's backup fails. No containers:
# dry runs, then real backups with no database to dump. The NTFY_PASS
# canary is in their environment too; no secret may reach their output.
run_helper() { # log-name [VAR=value...] command...   (a VAR given here wins)
  local log="$WORK/$1.log" extra=(); shift
  while [[ "${1:-}" == [A-Z]*=* ]]; do extra+=("$1"); shift; done
  (cd "$S" && env -i "PATH=$PATH" "HOME=$HOME" ${DOCKER_HOST:+"DOCKER_HOST=$DOCKER_HOST"} \
    NTFY_PASS="$CANARY" "${extra[@]}" "$@" < /dev/null > "$log" 2>&1)
}
has_line() { # log grep-pattern what
  grep -q -- "$2" "$WORK/$1.log" || { err "$3"; tail_of "$WORK/$1.log"; return 1; }
}
if [ ! -f "$S/.env" ]; then err "helper scripts: not run, setup.sh wrote no .env"
else
  PROF="$(sed -n 's/^COMPOSE_PROFILES=//p' "$S/.env")"
  # The monitors kuma-bootstrap.sh must plan: every installed service but
  # Kuma itself (as in the drift check above), plus the internet ping.
  WANT_MON="$(tr ',' '\n' <<< "$PROF" | grep -vx -e '' -e uptime-kuma | LC_ALL=C sort -u)"
  n_mon=$(( $(grep -c . <<< "$WANT_MON") + 1 ))
  BK_DEST="$WORK/backup-dest"   # outside the copy, not there yet
  tree_of > "$WORK/tree-helpers"

  run_helper bk-dry ./scripts/backup.sh --dry-run "$BK_DEST"; rc=$?
  step "backup.sh --dry-run" bk-dry "$rc"
  # A renamed variable inside $(...) only empties a value: check what was read.
  n_prof="$(tr ',' '\n' <<< "$PROF" | grep -c .)"
  [ "$rc" -eq 0 ] && has_line bk-dry 'DRY RUN' "backup.sh --dry-run: no DRY RUN line" \
    && has_line bk-dry " of $n_prof installed services$" "backup.sh --dry-run: plan does not count $n_prof installed services" \
    && has_line bk-dry 'left out of the stack archive (inside this folder): ./media ./photos$' \
       "backup.sh --dry-run: media and photos not named as left out of the stack archive" \
    && ok "backup.sh --dry-run: plan counts $n_prof services, leaves out ./media and ./photos"
  [ -e "$BK_DEST" ] && err "backup.sh --dry-run created its destination"
  # The off-site copy (T-011), planned from the keys the setup.sh section
  # left in .env; nothing runs restic here.
  [ "$rc" -eq 0 ] && has_line bk-dry "^  off-site:       $OFF_DIR, encrypted (restic/restic:" \
       "backup.sh --dry-run: no off-site line for OFFSITE_REPO" \
    && has_line bk-dry '^  off-site only:  .*/photos (your photo files)$' \
       "backup.sh --dry-run: photos not planned for the off-site copy" \
    && ok "backup.sh --dry-run: plans the off-site copy, photos in it"
  [ -e "$OFF_DIR" ] && err "backup.sh --dry-run created the off-site folder"
  run_helper bk-local ./scripts/backup.sh --dry-run --local-only "$BK_DEST"; rc=$?
  step "backup.sh --dry-run --local-only" bk-local "$rc"
  [ "$rc" -eq 0 ] && has_line bk-local '^  off-site:       skipped (--local-only)$' \
       "backup.sh --local-only: the plan does not say the off-site copy is skipped" \
    && ok "backup.sh --local-only: off-site copy skipped"
  # Cloud storage (T-089): an s3: URL is planned with its keys from .env
  # (never printed: step's leak check reads SECRET_KEYS' values); other
  # backends, a URL with an "@" (not echoed), a missing or odd key refused.
  S3_URL="s3:https://s3.example.com/check-bucket"
  sed -i "s#^OFFSITE_REPO=.*#OFFSITE_REPO=$S3_URL#" "$S/.env"
  run_helper bk-s3 ./scripts/backup.sh --dry-run "$BK_DEST"; rc=$?
  step "backup.sh --dry-run, s3: repository" bk-s3 "$rc"
  [ "$rc" -eq 0 ] && has_line bk-s3 "^  off-site:       $S3_URL, encrypted (restic/restic:" \
       "backup.sh --dry-run: no off-site line for an s3: OFFSITE_REPO" \
    && ok "backup.sh --dry-run: plans the off-site copy to cloud storage (s3:)"
  grep -q 'off-site repository is on the SAME' "$WORK/bk-s3.log" && err "backup.sh --dry-run: an s3: repository called on the SAME filesystem"
  refused() { # log rc text what   (exit 1 and the text, else a failure)
    if [ "$2" -ne 1 ] || ! grep -qF -- "$3" "$WORK/$1.log"; then
      err "$4 (exit $2)"; tail_of "$WORK/$1.log"; return 1
    fi
  }
  sed -i 's#^OFFSITE_REPO=.*#OFFSITE_REPO=b2:check-bucket:anteiku#' "$S/.env"
  run_helper bk-url ./scripts/backup.sh --dry-run "$BK_DEST"; rc=$?
  refused bk-url "$rc" 'OFFSITE_REPO must be a folder path (/mnt/…) or s3:https://…' \
    "backup.sh: a b2: OFFSITE_REPO was not refused" \
    && ok "backup.sh: refuses an OFFSITE_REPO that is neither a folder nor s3:"
  sed -i 's#^OFFSITE_REPO=.*#OFFSITE_REPO=s3:https://chkuser:chkpw-in-url@s3.example.com/b#' "$S/.env"
  run_helper bk-at ./scripts/backup.sh --dry-run "$BK_DEST"; rc=$?
  if refused bk-at "$rc" "OFFSITE_REPO holds an '@' (not shown here)" "backup.sh: an OFFSITE_REPO with an @ was not refused"; then
    if grep -q 'chkpw-in-url' "$WORK/bk-at.log"; then err "backup.sh: printed an OFFSITE_REPO that holds an @"
    else ok "backup.sh: refuses an OFFSITE_REPO with an @, without printing it"; fi
  fi
  sed -i "s#^OFFSITE_REPO=.*#OFFSITE_REPO=$S3_URL#" "$S/.env"
  cp "$S/.env" "$WORK/env-s3"
  sed -i '/^OFFSITE_SECRET_ACCESS_KEY=/d' "$S/.env"
  run_helper bk-nokey ./scripts/backup.sh --dry-run "$BK_DEST"; rc=$?
  refused bk-nokey "$rc" 'OFFSITE_SECRET_ACCESS_KEY is empty' "backup.sh: an s3: OFFSITE_REPO without its secret key was not refused" \
    && ok "backup.sh: refuses an s3: OFFSITE_REPO without its keys"
  cp "$WORK/env-s3" "$S/.env"
  sed -i 's#^OFFSITE_ACCESS_KEY_ID=.*#OFFSITE_ACCESS_KEY_ID=CHK\#cut#' "$S/.env"
  run_helper bk-oddkey ./scripts/backup.sh --dry-run "$BK_DEST"; rc=$?
  refused bk-oddkey "$rc" 'OFFSITE_ACCESS_KEY_ID holds a character a key' "backup.sh: a key holding # was not refused" \
    && ok "backup.sh: refuses a key its credentials file would cut (#)"
  # offsite-restore.sh, no terminal, keys missing: refused before restic.
  # A docker stand-in first on the PATH logs any call (LESSONS 24): a
  # broken refusal must fail here, never start restic on this machine.
  mkdir -p "$WORK/stub-docker"
  printf '#!/bin/sh
echo "$*" >> "%s"
exit 97
' "$WORK/stub-docker.calls" > "$WORK/stub-docker/docker"
  chmod +x "$WORK/stub-docker/docker"; : > "$WORK/stub-docker.calls"
  cp "$WORK/env-s3" "$S/.env"; sed -i '/^OFFSITE_ACCESS_KEY_ID=/d' "$S/.env"
  run_helper rs-nokey "PATH=$WORK/stub-docker:$PATH" ./scripts/offsite-restore.sh --list; rc=$?
  refused rs-nokey "$rc" 'No OFFSITE_ACCESS_KEY_ID in .env, and no terminal to ask for it.' \
    "offsite-restore.sh: an s3: repository without its key ID, no terminal: not refused" \
    && ok "offsite-restore.sh: no key and no terminal to ask: refused"
  sed -i 's#^OFFSITE_REPO=.*#OFFSITE_REPO=sftp:check-host:/srv/anteiku#' "$S/.env"
  run_helper rs-url "PATH=$WORK/stub-docker:$PATH" ./scripts/offsite-restore.sh --list; rc=$?
  refused rs-url "$rc" 'OFFSITE_REPO must be a folder path (/mnt/…) or s3:https://…' \
    "offsite-restore.sh: an sftp: OFFSITE_REPO was not refused" \
    && ok "offsite-restore.sh: refuses an OFFSITE_REPO that is neither a folder nor s3:"
  [ -s "$WORK/stub-docker.calls" ] && err "offsite-restore.sh: called docker before refusing ($(wc -l < "$WORK/stub-docker.calls") call(s))"
  cp "$WORK/env-s3" "$S/.env"
  sed -i "s#^OFFSITE_REPO=.*#OFFSITE_REPO=$OFF_DIR#" "$S/.env"

  if ! have python3; then
    note "kuma-bootstrap.sh and kuma-monitors.py need python3 on the host: not run"
  else
    run_helper kuma-dry ./scripts/kuma-bootstrap.sh --dry-run; rc=$?
    step "kuma-bootstrap.sh --dry-run" kuma-dry "$rc"
    [ "$rc" -eq 0 ] && has_line kuma-dry 'DRY RUN' "kuma-bootstrap.sh --dry-run: no DRY RUN line" \
      && has_line kuma-dry "^  $n_mon monitors across" "kuma-bootstrap.sh --dry-run: did not render $n_mon monitors" \
      && ok "kuma-bootstrap.sh --dry-run: rendered $n_mon monitors"
    # The plan as kuma-apply.py receives it: JSON, one row per service.
    run_helper kuma-plan COMPOSE_PROFILES="$PROF" STACK_PREFIX=chk- \
      PORT_QBITTORRENT="$(sed -n 's/^PORT_QBITTORRENT=//p' "$S/.env")" python3 -I scripts/kuma-monitors.py plan; rc=$?
    got="$(python3 -I -c '
import json, sys
want = set(sys.argv[2].split()) | {"__internet__"}
try:
    rows = json.load(open(sys.argv[1]))
except ValueError as e:
    sys.exit("not JSON: %s" % e)
if not isinstance(rows, list) or not all(isinstance(r, dict) for r in rows):
    sys.exit("not a list of monitors")
names = [r.get("service") for r in rows]
if len(names) != len(set(names)): sys.exit("a service twice: %s" % sorted({n for n in names if names.count(n) > 1}))
if set(names) != want: sys.exit("missing %s, extra %s" % (sorted(want - set(names)), sorted(set(names) - want)))
bad = [r["service"] for r in rows if r["service"] != "__internet__" and r.get("container") != "chk-" + r["service"]]
if bad: sys.exit("wrong container name: %s" % bad)
qb = [r.get("target") for r in rows if r["service"] == "qbittorrent"]
if qb != ["qbittorrent:" + sys.argv[3]]: sys.exit("qbittorrent target %s, want qbittorrent:%s (its host port, T-062)" % (qb, sys.argv[3]))
print(len(rows))
' "$WORK/kuma-plan.log" "$WANT_MON" "$(sed -n 's/^PORT_QBITTORRENT=//p' "$S/.env")" 2>&1)"
    if [ "$rc" -ne 0 ]; then err "kuma-monitors.py plan: exit $rc"; tail -n 5 "$WORK/kuma-plan.log" | indent
    elif [ "$got" != "$n_mon" ]; then err "kuma-monitors.py plan: $got"
    else ok "kuma-monitors.py plan: JSON, $got monitors (every installed service but Kuma, + internet)"; fi
  fi

  run_helper ntfy-dry ./scripts/ntfy-setup.sh --dry-run; rc=$?
  step "ntfy-setup.sh --dry-run" ntfy-dry "$rc"
  [ "$rc" -eq 0 ] && has_line ntfy-dry 'DRY RUN' "ntfy-setup.sh --dry-run: no DRY RUN line" \
    && has_line ntfy-dry "user  *$(sed -n 's/^NTFY_USER=//p' "$S/.env")$" "ntfy-setup.sh --dry-run: did not show the ntfy user from .env" \
    && ok "ntfy-setup.sh --dry-run: read the ntfy user from .env"
  wrote_nothing "helper dry runs" "$WORK/tree-helpers"

  # One real backup on the default layout (T-055): ./media and ./photos
  # inside the folder, a file in each, kept out of stack.tar.gz. Nothing
  # runs here, so Immich (the one database) is left out of this .env.
  cp "$S/.env" "$WORK/env-helpers"
  # A real off-site run needs Docker and restic's image: not here.
  sed -i '/^OFFSITE_/d' "$S/.env"
  sed -i "s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=$(tr ',' '\n' <<< "$PROF" | grep -vx -e immich -e immich-ml | paste -sd,)/" "$S/.env"
  med="$(sed -n 's/^MEDIA_ROOT=//p' "$S/.env")"; pho="$(sed -n 's/^PHOTOS_LOCATION=//p' "$S/.env")"
  if [ "$med" != "$S/media" ] || [ "$pho" != "$S/photos" ]; then
    err "backup.sh: .env does not hold the default layout (MEDIA_ROOT, PHOTOS_LOCATION = ./media, ./photos as absolute paths)"
  else
    mkdir -p "$med/tv" "$pho" && echo check > "$med/tv/check.mkv" && echo check > "$pho/check.jpg"
    tree_of > "$WORK/tree-backup"
    run_helper bk-real ./scripts/backup.sh "$BK_DEST"; rc=$?
    step "backup.sh, a real run" bk-real "$rc"
    wrote_nothing "backup.sh, into the install folder" "$WORK/tree-backup"
    arc="$(find "$BK_DEST" -mindepth 2 -maxdepth 2 -name stack.tar.gz)"
    if [ "$(grep -c . <<< "$arc")" -ne 1 ]; then err "backup.sh: expected one stack.tar.gz in the destination, found $(grep -c . <<< "$arc")"
    else
      list="$(LC_ALL=C tar tzf "$arc" 2>&1)"; rc=$?
      miss=""; for f in ./.env ./compose.yaml ./setup.sh ./scripts/backup.sh; do grep -qxF "$f" <<< "$list" || miss="$miss $f"; done
      # Fixed-string prefixes, not regexes.
      in="$(awk 'index($0, "./media/") == 1 || index($0, "./photos/") == 1' <<< "$list" | head -n 5)"
      if [ "$rc" -ne 0 ]; then err "backup.sh: tar cannot list stack.tar.gz (exit $rc)"
      elif [ -n "$miss" ]; then err "backup.sh: stack.tar.gz lacks$miss"
      elif [ -n "$in" ]; then err "backup.sh: stack.tar.gz holds media or photos:"; printf '%s\n' "$in" | indent
      elif [ "$(stat -c %a "$arc")" != 600 ]; then err "backup.sh: stack.tar.gz is not mode 600"
      else ok "backup.sh: stack.tar.gz has .env and compose.yaml, no media or photos, mode 600 ($(grep -c . <<< "$list") entries)"; fi
    fi

    # backup-cron.sh as cron starts it: from another folder, a HOME of its
    # own, curl a stand-in. It once logged to ~/backup-logs (LESSONS 2):
    # nothing may appear outside the copy. Its destination is inside.
    mkdir -p "$WORK/cron-home" "$WORK/stub"
    # Records the title and the URL, never -u; anything else is an unknown call.
    cat > "$WORK/stub/curl" <<'STUB'
#!/bin/sh
t=""; u=""
for a in "$@"; do case "$a" in "Title: "*) t="$a" ;; http://*|https://*) u="$a" ;; esac; done
[ -n "$t" ] && [ -n "$u" ] || t="unknown call"
printf '%s|%s\n' "$t" "$u" >> "${0%/*}/../curl.calls"
STUB
    chmod 755 "$WORK/stub/curl"
    echo "BACKUP_DEST=./backups" >> "$S/.env"
    outside() { find "$WORK" -mindepth 1 \( -path "$S" -o -path "$WORK/cron.log" -o -path "$WORK/curl.calls" \) -prune -o -print | LC_ALL=C sort; }
    outside > "$WORK/tree-outside"
    (cd "$WORK/cron-home" && env -i "PATH=$WORK/stub:$PATH" "HOME=$WORK/cron-home" NTFY_PASS="$CANARY" \
      "$S/scripts/backup-cron.sh" < /dev/null > "$WORK/cron.log" 2>&1); rc=$?
    clog="$(find "$S/backup-logs" -maxdepth 1 -name 'backup-*.log' 2>/dev/null)"
    new="$(outside | LC_ALL=C comm -13 "$WORK/tree-outside" -)"
    want="Title: Backup OK|$(sed -n 's/^NTFY_URL=//p' "$S/.env")/$(sed -n 's/^NTFY_TOPIC=//p' "$S/.env")"
    l="$( { leaks_in "$WORK/cron.log"; [ -n "$clog" ] && leaks_in "$clog"; [ -f "$WORK/curl.calls" ] && leaks_in "$WORK/curl.calls"; } | sort -u)"
    if [ -n "$new" ]; then err "backup-cron.sh wrote outside the install folder:"; printf '%s\n' "${new//$WORK/<tmp>}" | head -n 10 | indent
    elif [ -n "$l" ]; then err "backup-cron.sh: printed a secret ($(echo "$l" | tr '\n' ' '))"
    elif [ "$rc" -ne 0 ]; then err "backup-cron.sh: exit $rc"; tail_of "$(head -n 1 <<< "${clog:-$WORK/cron.log}")"
    elif [ "$(grep -c . <<< "$clog")" -ne 1 ] || ! grep -q 'Backup complete' "$clog"; then err "backup-cron.sh: no backup-logs/backup-*.log saying Backup complete"
    elif [ "$(cat "$WORK/curl.calls" 2>/dev/null)" != "$want" ]; then err "backup-cron.sh: expected one \"Backup OK\" to NTFY_URL/NTFY_TOPIC, got:"; { indent < "$WORK/curl.calls"; } 2>/dev/null
    elif [ -z "$(find "$S/backups" -mindepth 2 -maxdepth 2 -name stack.tar.gz 2>/dev/null)" ]; then err "backup-cron.sh: no stack.tar.gz in BACKUP_DEST"
    else ok "backup-cron.sh: exit 0, log in backup-logs/, one Backup OK sent, nothing new outside the copy (temp dir and its HOME, $(wc -l < "$WORK/tree-outside") paths)"; fi
  fi
  cp "$WORK/env-helpers" "$S/.env"
fi

# ------------------------------------------------------------ old images
h1 "update.sh: old images"
# Which images update.sh lists for removal (T-070): a git repo with three
# fake releases and a docker stand-in. It never calls the real docker.
if oi="$(cd "$S" && env -i "PATH=$PATH" "HOME=$WORK" bash tests/old-images.sh 2>&1)"; then ok "$(tail -n 1 <<< "$oi")"
else err "tests/old-images.sh failed:"; indent <<< "$oi"; fi

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
