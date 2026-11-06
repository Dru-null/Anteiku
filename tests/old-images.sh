#!/usr/bin/env bash
# ============================================================
#  tests/old-images.sh — which images update.sh offers to remove (T-070).
#
#  A git repo with three fake releases and a docker stand-in (a bash
#  function): old_images and size_total from lib/release.sh run against
#  them. Nothing is pulled, started or removed; the real docker is never
#  called. Prints one summary line; exit 1 on any failure.
# ============================================================
# The stand-in's format strings are Go templates: single quotes on purpose.
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0; checks=0
check() { # label expected got
  checks=$((checks+1))
  [ "$2" = "$3" ] || { fails=$((fails+1)); printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$2" "$3"; }
}

# Three releases. ex/gone leaves after 1.0.0; ex/override is selected by
# an override in .env (compose config); ex/used is pinned by 1.0.0 and a
# container of another project still uses it.
g() { git -C "$T/repo" -c user.name=t -c user.email=t@example.invalid "$@"; }
mkdir -p "$T/repo/stacks" && git init -q "$T/repo" || exit 1
release() { # tag sonarr valkey quoted [extra lines]
  {
    echo "services:"
    echo "  sonarr:"
    echo "    image: lscr.io/x/sonarr:\${SONARR_VERSION:-$2}"
    echo "  valkey:"
    echo "    image: docker.io/valkey/valkey:$3"
    echo "  kept:"
    echo "    image: ex/kept:1"
    echo "  quoted:"
    echo "    image: \"ex/quoted:$4\"   # a comment"
    [ -n "${5:-}" ] && printf '%s\n' "$5"
  } > "$T/repo/stacks/a.yaml"
  g add -A && g commit -q -m "$1" && g tag "$1"
}
release 1.0.0 1 9.0 1 "  gone:
    image: ex/gone:1
  used:
    image: docker.io/ex/used:1
  over:
    image: ex/override:\${OVER_VERSION:-1}"
# A commit between releases, tagged but not a release: its pins never count.
echo "    image: ex/devonly:1" >> "$T/repo/stacks/a.yaml"
g add -A && g commit -q -m "between releases" && g tag not-a-release
release 1.1.0 2 9.1 2
release 1.2.0 3 9.1 2

# What the machine has. ex/foreign and sonarr:mine were never pinned.
cat > "$T/images" <<'EOF'
lscr.io/x/sonarr:1	302MB
lscr.io/x/sonarr:2	302MB
lscr.io/x/sonarr:3	303MB
lscr.io/x/sonarr:mine	302MB
valkey/valkey:9.0	150MB
valkey/valkey:9.1	151MB
ex/kept:1	10MB
ex/quoted:1	1.2GB
ex/quoted:2	1.2GB
ex/gone:1	5.6kB
ex/used:1	20MB
ex/override:1	30MB
ex/foreign:1	40MB
ex/devonly:1	40MB
EOF
printf '%s\n' "lscr.io/x/sonarr:3" "docker.io/ex/used:1" "valkey/valkey:9.1" > "$T/ps"
docker() {
  case "$*" in
    'image ls --format {{.Repository}}:{{.Tag}}	{{.Size}}') [ -f "$T/images.fail" ] && return 1; cat "$T/images" ;;
    'ps -a --format {{.Image}}') [ -f "$T/ps.fail" ] && return 1; cat "$T/ps" ;;
    'compose config --images') echo "ex/override:1" ;;
    *) echo "docker stand-in: unknown call: $*" >> "$T/odd"; return 1 ;;
  esac
}
export -f docker 2>/dev/null
REL_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
# shellcheck source=lib/release.sh
. "$LIB/release.sh"

got="$(cd "$T/repo" && old_images 1.1.0 | cut -f1 | paste -sd' ')"
check "way back 1.1.0: earlier pins only, none in use, none an override" \
  "ex/gone:1 ex/quoted:1 lscr.io/x/sonarr:1 valkey/valkey:9.0" "$got"
got="$(cd "$T/repo" && old_images 1.1.0 | grep '^ex/gone:1	' )"
check "the size comes with the name" "ex/gone:1	5.6kB" "$got"
got="$(cd "$T/repo" && old_images "" | cut -f1 | paste -sd' ')"
check "no way back: the previous release's images are listed too" \
  "ex/gone:1 ex/quoted:1 lscr.io/x/sonarr:1 lscr.io/x/sonarr:2 valkey/valkey:9.0" "$got"
got="$(cd "$T/repo" && g checkout -q 1.0.0 && old_images "" | cut -f1 | paste -sd' '; g checkout -q -)"
check "at the oldest release: nothing is older" "" "$got"
# Each docker call failing on its own: without the container list every
# image would look unused; without the image list there is nothing to name.
for f in images ps; do
  : > "$T/$f.fail"
  got="$(cd "$T/repo" && old_images 1.1.0; echo "rc=$?")"
  check "docker $f fails: nothing listed, not a guess" "rc=1" "$got"
  rm -f "$T/$f.fail"
done
got="$(cd "$T" && old_images 1.1.0; echo "rc=$?")"
check "not a git checkout: nothing listed" "rc=1" "$got"
got="$(cd "$T/repo" && release_images 1.0.0 | paste -sd' ')"
check "release_images reads pins, quotes, comments, docker.io/" \
  "ex/gone:1 ex/kept:1 ex/override:1 ex/quoted:1 ex/used:1 lscr.io/x/sonarr:1 valkey/valkey:9.0" "$got"
got="$(printf 'a\t302MB\nb\t1.34GB\nc\t5.6kB\n' | size_total)"
check "size_total, GB" "1.6 GB" "$got"
got="$(printf 'a\t302MB\nb\t313MB\n' | size_total)"
check "size_total, MB" "615 MB" "$got"
got="$(printf 'a\t600kB\nb\t700kB\n' | size_total)"
check "size_total, kB" "1 MB" "$got"
[ -f "$T/odd" ] && { fails=$((fails+1)); sed 's/^/FAIL /' "$T/odd"; }

echo "old images: $checks checks, $fails failed"
[ "$fails" -eq 0 ]
