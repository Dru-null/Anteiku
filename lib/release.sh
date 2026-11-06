# shellcheck shell=bash
# ============================================================
#  lib/release.sh — which release this is, and the newest tested one.
#
#  A release is a set of versions brought up and tested together
#  (CHANGELOG.md). GitHub lists them; only those are ever offered,
#  never the newest commit on main.
#
#  Contacts GitHub only (the Releases API, and the raw CHANGELOG of a
#  release). Nothing is sent but the request itself: no IDs, no stats.
#  Sourced by update.sh and doctor.sh, after lib/detect.sh.
# ============================================================

# Overridable for testing against a mock; leave them alone otherwise.
# shellcheck disable=SC2034  # used by the scripts that source this
ANTEIKU_API="${ANTEIKU_API:-https://api.github.com/repos/Dru-null/Anteiku}"
ANTEIKU_RAW="${ANTEIKU_RAW:-https://raw.githubusercontent.com/Dru-null/Anteiku}"
ANTEIKU_RELEASES="https://github.com/Dru-null/Anteiku/releases"

REL_RE='^[0-9]+\.[0-9]+\.[0-9]+$'

# The release this checkout is on, or came after. Without git (a
# downloaded zip), the newest entry in CHANGELOG.md.
release_current() {
  local v
  v="$(git describe --tags --abbrev=0 --match '[0-9]*.[0-9]*.[0-9]*' 2>/dev/null)" \
    || v="$(sed -n 's/^## \([0-9][0-9.]*\) .*/\1/p' CHANGELOG.md 2>/dev/null | head -n 1)"
  [[ "$v" =~ $REL_RE ]] && echo "$v"
}

# shellcheck disable=SC2034  # REL_DATE: read by update.sh
# Sets REL_TAG and REL_DATE (ISO 8601). Returns 1 if GitHub could not
# be asked or gave no usable answer.
release_latest() {
  local json
  REL_TAG=""; REL_DATE=""
  have curl || return 1
  json="$(curl -fsS --max-time 20 -H 'Accept: application/vnd.github+json' \
          "$ANTEIKU_API/releases/latest" 2>/dev/null)" || return 1
  REL_TAG="$(grep -o '"tag_name": *"[^"]*"' <<< "$json" | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
  REL_DATE="$(grep -o '"published_at": *"[^"]*"' <<< "$json" | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
  # The tag ends up in git commands and URLs: accept only a version.
  [[ "$REL_TAG" =~ $REL_RE ]] || { REL_TAG=""; return 1; }
}

# version_gt A B -> 0 if A is newer than B. Versions sort like numbers.
version_gt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

# CHANGELOG.md as of release <tag>, on stdout.
release_changelog() {
  curl -fsS --max-time 20 "$ANTEIKU_RAW/$1/CHANGELOG.md" 2>/dev/null
}

# changelog_since <old> <new> < CHANGELOG.md -> the entries after <old>,
# up to and including <new>, newest first.
changelog_since() {
  local old="$1" new="$2" line v on=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^##\ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
      v="${BASH_REMATCH[1]}"
      on=0
      version_gt "$v" "$old" && ! version_gt "$v" "$new" && on=1
    fi
    [ "$on" -eq 1 ] && printf '%s\n' "$line"
  done
  return 0
}

# action_needed < entries -> each entry's "Action needed" text, unless it
# is "None.". Empty output means a release can be applied unattended.
action_needed() {
  awk '
    /^## /                 { ver = $2; on = 0; next }
    /^### /                { on = ($0 ~ /^### Action needed/); next }
    on && NF               { txt[ver] = txt[ver] $0 "\n"; if (!(ver in seen)) { seen[ver]; order[++n] = ver } }
    END {
      for (i = 1; i <= n; i++) {
        v = order[i]
        if (txt[v] ~ /^None\./) continue
        printf "%s:\n%s", v, txt[v]
      }
    }'
}

# retired_notice <setup.sh log> -> the body of its "No longer part of
# Anteiku" section (T-020): services that left the catalogue, still
# there, with the command to remove each. Empty when there is none.
# setup.sh prints it only on the run that drops them, and update.sh
# keeps that run's output in a log, so it has to be passed on.
retired_notice() {
  awk '
    /^(──|--) No longer part of Anteiku / { on = 1; next }
    on && /^(──|--) /                     { exit }
    on && !NF                             { blank++; next }
    on { while (blank > 0) { print ""; blank-- } print }
  ' "$1" 2>/dev/null
}

# profiles_dropped <profiles before> <profiles now> -> ",a,b": the keys
# in the first list missing from the second (T-036). update.sh compares
# COMPOSE_PROFILES from before setup.sh with after: a release that
# removed a service took it out. The way back puts these back. Keys only
# ([a-z0-9-]), so the result is safe inside the printed sed command.
profiles_dropped() {
  local k out="" old=()
  IFS=, read -ra old <<< "$1"
  for k in "${old[@]}"; do
    case "$k" in ''|*[!a-z0-9-]*) continue ;; esac
    case ",$2," in *",$k,"*) ;; *) out="$out,$k" ;; esac
  done
  printf '%s' "$out"
}

# ---- images an update left behind (T-070) ------------------------------
# Nothing here removes anything: update.sh lists them with the command.

# image_name < refs -> as Docker shows them in `image ls` and `ps`:
# docker.io/ and docker.io/library/ dropped.
image_name() { sed 's#^docker\.io/library/##; s#^docker\.io/##'; }

# release_images <ref> -> every image pinned at <ref> (a tag or commit):
# the image: lines of its compose files, ${X_VERSION:-pin} read as the pin.
release_images() {
  local f
  git ls-tree -r --name-only "$1" -- stacks hw compose.yaml 2>/dev/null | grep -E '\.ya?ml$' \
    | while IFS= read -r f; do git show "$1:$f" 2>/dev/null; done \
    | sed -n 's/^[[:space:]]*image:[[:space:]]*//p' \
    | sed -E -e 's/[[:space:]]+#.*$//' -e 's/^["'\'']//' -e 's/["'\''][[:space:]]*$//' \
             -e 's/\$\{[A-Za-z0-9_]+:-([^}]*)\}/\1/g' \
    | image_name | LC_ALL=C sort -u
}

# old_images <way-back ref> -> "image<TAB>size" for each image an earlier
# release pinned that is still on this machine, used by no container (any
# project, running or not), and pinned neither here nor at the way back,
# nor selected by an override in .env. Nothing when Docker or git can't
# be read: never a guess.
old_images() {
  local keep all imgs ps t
  imgs="$(docker image ls --format '{{.Repository}}:{{.Tag}}	{{.Size}}' 2>/dev/null)" || return 1
  ps="$(docker ps -a --format '{{.Image}}' 2>/dev/null)" || return 1
  git rev-parse --verify -q HEAD >/dev/null 2>&1 || return 1
  keep="$( { release_images HEAD; [ -z "${1:-}" ] || release_images "$1"
             docker compose config --images 2>/dev/null | image_name; } | LC_ALL=C sort -u)"
  all="$(git tag --merged HEAD 2>/dev/null | grep -E "$REL_RE" \
         | while IFS= read -r t; do release_images "$t"; done | LC_ALL=C sort -u)"
  LC_ALL=C comm -23 <(printf '%s\n' "$all") <(printf '%s\n' "$keep") \
    | LC_ALL=C comm -23 - <(printf '%s\n' "$ps" | image_name | LC_ALL=C sort -u) \
    | awk -F'\t' 'NR == FNR { if (NF) want[$0] = 1; next } ($1 in want) && !seen[$1]++' - <(printf '%s\n' "$imgs") \
    | LC_ALL=C sort
}

# size_total < "image<TAB>size" lines -> their sizes added up, as Docker
# writes them (decimal: kB, MB, GB). An upper bound: images share layers.
size_total() {
  awk -F'\t' '
    { n = $2 + 0; u = $2; sub(/^[0-9.]+/, "", u)
      m = (u == "kB") ? 1e3 : (u == "MB") ? 1e6 : (u == "GB") ? 1e9 : (u == "TB") ? 1e12 : 1
      t += n * m }
    END { if (t >= 1e9) printf "%.1f GB\n", t / 1e9; else printf "%d MB\n", t / 1e6 }'
}
