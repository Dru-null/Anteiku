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
