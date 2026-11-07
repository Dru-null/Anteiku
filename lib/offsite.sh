# shellcheck shell=bash
# ============================================================
#  lib/offsite.sh — the encrypted off-site copy (restic).
#
#  restic encrypts everything it stores (AES-256) with a key made from
#  OFFSITE_PASSWORD, and stores each file's data once, so photos you
#  already sent are not sent again. It runs from its official image,
#  pinned here: nothing is installed on this machine.
#
#  .env:  OFFSITE_REPO      a folder: another disk, a NAS share mounted
#                           here. Cloud storage directly: not yet.
#         OFFSITE_PASSWORD  the key. Lose it and the copy is noise.
#         OFFSITE_PHOTOS    yes (default) or no: PHOTOS_LOCATION too
#
#  The password reaches restic as a file only this user can read,
#  never on a command line, where any user on the machine can read it.
#  Sourced by scripts/backup.sh and scripts/offsite-restore.sh, after
#  lib/detect.sh, from the install folder.
# ============================================================

# shellcheck disable=SC2034  # used by the scripts that source this
RESTIC_IMAGE="restic/restic:0.19.1"
OFFSITE_HOST="anteiku"         # restic's host name for our snapshots
OFFSITE_KEEP=(--keep-daily 7 --keep-weekly 5 --keep-monthly 12)
OFFSITE_CACHE="./.offsite-cache"   # restic's index cache; rebuilt if lost

offsite_lines() { sed 's/^/       /'; }   # restic's own lines, under a note

# A folder path? (restic URLs such as s3:… are not supported yet.)
offsite_is_dir() { case "$1" in /*|./*|../*) return 0 ;; *) return 1 ;; esac; }
offsite_not_dir() {
  err "OFFSITE_REPO must be a folder path (/mnt/…): '$OFFSITE_REPO' isn't one."
  note "Cloud storage directly (s3:, b2:, sftp:) is not supported yet."
}

# offsite_run <docker run options...> -- <restic arguments...>
# Runs restic as this user. Output in OFFSITE_OUT, exit code returned.
# restic's codes: 0 ok, 1 failed, 3 some files unreadable (snapshot
# saved, incomplete), 10 no repository there, 11 locked, 12 wrong
# password (restic 0.19 doc/075_scripting.rst).
# shellcheck disable=SC2034  # read by the scripts that source this
OFFSITE_OUT=""
offsite_run() {
  local opts=() key rc
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do opts+=("$1"); shift; done
  shift
  # Docker would create a missing folder itself, owned by root.
  [ -d "$OFFSITE_REPO" ] || { OFFSITE_OUT="$OFFSITE_REPO: no such folder"; return 10; }
  mkdir -p "$OFFSITE_CACHE" || { OFFSITE_OUT="cannot create $OFFSITE_CACHE"; return 1; }
  key="$(umask 077; mktemp)" || { OFFSITE_OUT="cannot create a temporary file"; return 1; }
  printf '%s' "$OFFSITE_PASSWORD" > "$key"
  OFFSITE_OUT="$(docker run --rm --hostname "$OFFSITE_HOST" --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$key:/run/offsite.key:ro" -v "$(realpath -- "$OFFSITE_CACHE"):/cache" \
    -v "$(realpath -- "$OFFSITE_REPO"):/repo" "${opts[@]}" "$RESTIC_IMAGE" \
    --repo /repo --password-file /run/offsite.key --cache-dir /cache "$@" 2>&1 < /dev/null)"; rc=$?
  rm -f "$key"
  return "$rc"
}

# Why restic stopped, in words, for exit codes that have one.
offsite_why() {
  case "$1" in
    10) echo "no restic repository at $OFFSITE_REPO" ;;
    11) echo "the repository is locked by another restic run (or a stale lock)" ;;
    12) echo "wrong OFFSITE_PASSWORD for this repository" ;;
    125|126|127) echo "Docker could not start $RESTIC_IMAGE (exit $1)" ;;
    *)  echo "restic exit $1" ;;
  esac
}
