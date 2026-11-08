# shellcheck shell=bash
# ============================================================
#  lib/offsite.sh — the encrypted off-site copy (restic).
#
#  restic encrypts everything it stores (AES-256) with a key made from
#  OFFSITE_PASSWORD, and stores each file's data once, so photos you
#  already sent are not sent again. It runs from its official image,
#  pinned here: nothing is installed on this machine.
#
#  .env:  OFFSITE_REPO      a folder (another disk, a NAS share mounted
#                           here) or cloud storage that speaks S3:
#                           s3:https://<endpoint>/<bucket>
#         OFFSITE_PASSWORD  the key. Lose it and the copy is noise.
#         OFFSITE_PHOTOS    yes (default) or no: PHOTOS_LOCATION too
#         OFFSITE_ACCESS_KEY_ID, OFFSITE_SECRET_ACCESS_KEY
#                           cloud storage only: the bucket's key pair
#
#  The password and the keys reach restic as files only this user can
#  read, never on a command line or in the container's environment,
#  where other users and `docker inspect` can read them.
#  Sourced by scripts/backup.sh and scripts/offsite-restore.sh, after
#  lib/detect.sh, from the install folder.
# ============================================================

# shellcheck disable=SC2034  # used by the scripts that source this
RESTIC_IMAGE="restic/restic:0.19.1"
OFFSITE_HOST="anteiku"         # restic's host name for our snapshots
OFFSITE_KEEP=(--keep-daily 7 --keep-weekly 5 --keep-monthly 12)
OFFSITE_CACHE="./.offsite-cache"   # restic's index cache; rebuilt if lost
OFFSITE_TRIES=3                # offsite_probe stops restic at this retry

offsite_lines() { sed 's/^/       /'; }   # restic's own lines, under a note

# A folder path, or cloud storage (s3:…)?
offsite_is_dir() { case "$1" in /*|./*|../*) return 0 ;; *) return 1 ;; esac; }
offsite_is_s3()  { case "$1" in s3:?*) return 0 ;; *) return 1 ;; esac; }

# Is OFFSITE_REPO one we can use? Says why not. A URL holding an "@"
# may hold a password, so that one is never printed.
offsite_repo_ok() {
  offsite_is_dir "$OFFSITE_REPO" && return 0
  case "$OFFSITE_REPO" in *@*)
    err "OFFSITE_REPO holds an '@' (not shown here). Keys go in"
    note "OFFSITE_ACCESS_KEY_ID and OFFSITE_SECRET_ACCESS_KEY, not in the URL."
    return 1 ;;
  esac
  offsite_is_s3 "$OFFSITE_REPO" && return 0
  err "OFFSITE_REPO must be a folder path (/mnt/…) or s3:https://…: '$OFFSITE_REPO' is neither."
  note "Other restic backends (b2:, sftp:, rest:…) are not supported here: docs/backups.md."
  return 1
}

# Cloud storage: are both keys there, and plain enough for the
# credentials file (#, ;, quotes or spaces would be cut by its parser)?
# Names the key, never prints it.
offsite_keys_ok() {
  local k
  offsite_is_s3 "$OFFSITE_REPO" || return 0
  for k in OFFSITE_ACCESS_KEY_ID OFFSITE_SECRET_ACCESS_KEY; do
    if [ -z "${!k:-}" ]; then
      err "OFFSITE_REPO is cloud storage (s3:), but $k is empty (docs/backups.md)."; return 1
    fi
    case "${!k}" in *[!A-Za-z0-9/+=._-]*)
      err "$k holds a character a key doesn't (a space, #, ; or a quote?): check it."; return 1 ;;
    esac
  done
}

# What an interrupted run has to clean up. `docker run` doesn't take its
# container down when it dies: restic would keep going (retrying for up
# to 15 minutes, or uploading with the repository locked), and the key
# files would stay on disk. Globals, not locals: a trap runs inside the
# interrupted function, and it must see them however far that got.
OFFSITE_NAME=""     # this run's container
OFFSITE_CLI=""      # its docker client: it could still start the container
OFFSITE_KEYFILE=""  # the password, for restic
OFFSITE_S3FILE=""   # the cloud keys, for restic
OFFSITE_GRACE=10    # seconds restic gets to remove its lock
# shellcheck disable=SC2034  # set by the scripts that source this
OFFSITE_ABORT_NOTE=""   # what the interrupted script wants to add

offsite_clear() {
  rm -f -- "$OFFSITE_KEYFILE" "$OFFSITE_S3FILE"
  OFFSITE_KEYFILE=""; OFFSITE_S3FILE=""; OFFSITE_NAME=""; OFFSITE_CLI=""
}

# Stop restic the polite way, so it removes its lock from the repository.
# The exit code is the script's own: backup-cron.sh must see a failure.
offsite_abort() {
  trap '' INT TERM HUP   # a second Ctrl-C must not cut this short
  err "interrupted: stopping restic" >&2
  if [ -n "$OFFSITE_NAME" ]; then
    docker stop -t "$OFFSITE_GRACE" "$OFFSITE_NAME" > /dev/null 2>&1
    # A client still going could start the container after this. Killed
    # mid-create it leaves one "Created", which --rm never removes: give
    # Docker a moment to finish creating it, then remove it.
    if [ -n "$OFFSITE_CLI" ] && kill "$OFFSITE_CLI" 2> /dev/null; then sleep 0.5; fi
    docker rm -f "$OFFSITE_NAME" > /dev/null 2>&1
  fi
  offsite_clear
  if [ -n "$OFFSITE_ABORT_NOTE" ]; then note "$OFFSITE_ABORT_NOTE" >&2; fi
  exit "$1"
}

# offsite_run <docker run options...> -- <restic arguments...>
# Runs restic as this user. Output in OFFSITE_OUT, exit code returned.
# restic's codes: 0 ok, 1 failed, 3 some files unreadable (snapshot
# saved, incomplete), 10 no repository there, 11 locked, 12 wrong
# password (restic 0.19 doc/075_scripting.rst). Ours: 99 stopped by
# offsite_probe.
# shellcheck disable=SC2034  # read by the scripts that source this
OFFSITE_OUT=""
OFFSITE_STOP=0   # >0: stop restic at that many retry lines (offsite_probe)
offsite_run() {
  local rc
  trap 'offsite_abort 130' INT
  trap 'offsite_abort 143' TERM
  trap 'offsite_abort 129' HUP
  offsite_restic "$@"; rc=$?
  offsite_clear
  trap - INT TERM HUP
  return "$rc"
}

offsite_restic() {
  local opts=() repo=() repo_arg line n=0 rc=1 stopped=0
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do opts+=("$1"); shift; done
  shift
  OFFSITE_OUT=""
  if offsite_is_s3 "$OFFSITE_REPO"; then
    OFFSITE_S3FILE="$(umask 077; mktemp)" || { OFFSITE_OUT="cannot create a temporary file"; return 1; }
    printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
      "$OFFSITE_ACCESS_KEY_ID" "$OFFSITE_SECRET_ACCESS_KEY" > "$OFFSITE_S3FILE"
    repo=(-v "$OFFSITE_S3FILE:/run/offsite.s3:ro" -e AWS_SHARED_CREDENTIALS_FILE=/run/offsite.s3)
    repo_arg="$OFFSITE_REPO"
  else
    # Docker would create a missing folder itself, owned by root.
    [ -d "$OFFSITE_REPO" ] || { OFFSITE_OUT="$OFFSITE_REPO: no such folder"; return 10; }
    repo=(-v "$(realpath -- "$OFFSITE_REPO"):/repo"); repo_arg=/repo
  fi
  mkdir -p "$OFFSITE_CACHE" || { OFFSITE_OUT="cannot create $OFFSITE_CACHE"; return 1; }
  OFFSITE_KEYFILE="$(umask 077; mktemp)" || { OFFSITE_OUT="cannot create a temporary file"; return 1; }
  printf '%s' "$OFFSITE_PASSWORD" > "$OFFSITE_KEYFILE"
  OFFSITE_NAME="anteiku-offsite-$$-$RANDOM"
  # Read restic's lines as they come: a trap can run between them, and
  # at the OFFSITE_STOP-th "retrying" line restic is killed. The client
  # runs in the background to report its PID; its exit code arrives as
  # the last line, after a newline of its own in case restic ended
  # without one.
  while IFS= read -r line; do
    case "$line" in
      __offsite_cli=*) OFFSITE_CLI="${line#*=}"; continue ;;
      __offsite_rc=*) rc="${line#*=}"; continue ;;
      *" returned error, retrying after "*)
        n=$((n + 1))
        if [ "$n" -eq "$OFFSITE_STOP" ]; then
          docker kill "$OFFSITE_NAME" > /dev/null 2>&1; stopped=1
        fi ;;
    esac
    OFFSITE_OUT+="$line"$'\n'
  done < <(docker run --rm --name "$OFFSITE_NAME" --hostname "$OFFSITE_HOST" --user "$(id -u):$(id -g)" -e HOME=/tmp \
      -v "$OFFSITE_KEYFILE:/run/offsite.key:ro" -v "$(realpath -- "$OFFSITE_CACHE"):/cache" "${repo[@]}" "${opts[@]}" \
      "$RESTIC_IMAGE" --repo "$repo_arg" --password-file /run/offsite.key --cache-dir /cache "$@" 2>&1 < /dev/null &
    p=$!; echo "__offsite_cli=$p"; wait "$p"; printf '\n__offsite_rc=%s\n' "$?")
  while [ "${OFFSITE_OUT%$'\n'}" != "$OFFSITE_OUT" ]; do OFFSITE_OUT="${OFFSITE_OUT%$'\n'}"; done
  [ "$stopped" -eq 1 ] && rc=99
  return "$rc"
}

# Is there a repository, and can we open it? restic retries most cloud
# errors (a wrong key, a missing bucket, no route) for 15 minutes, so
# this stops it at its OFFSITE_TRIES-th retry and keeps its lines.
# 0 yes, 10 no repository there, 12 wrong password, 99 stopped.
offsite_probe() {
  local rc
  OFFSITE_STOP="$OFFSITE_TRIES"
  offsite_run -- cat config > /dev/null; rc=$?
  OFFSITE_STOP=0
  return "$rc"
}

# restic's own reason, for the lines under an error: the last retry's
# error when offsite_probe stopped it, else its last lines.
offsite_tail() {
  local why
  why="$(sed -n 's/.* returned error, retrying after [^:]*: //p' <<< "$OFFSITE_OUT" | tail -n 1)"
  if [ -n "$why" ]; then printf '%s\n' "$why" | offsite_lines
  else tail -n "${1:-5}" <<< "$OFFSITE_OUT" | offsite_lines; fi
}

# Why restic stopped, in words, for exit codes that have one.
offsite_why() {
  case "$1" in
    10) echo "no restic repository at $OFFSITE_REPO" ;;
    11) echo "the repository is locked by another restic run (or a stale lock)" ;;
    12) echo "wrong OFFSITE_PASSWORD for this repository" ;;
    99) echo "restic could not open $OFFSITE_REPO and kept retrying; stopped after $OFFSITE_TRIES tries. restic said:" ;;
    125|126|127) echo "Docker could not start $RESTIC_IMAGE (exit $1)" ;;
    *)  echo "restic exit $1" ;;
  esac
}
