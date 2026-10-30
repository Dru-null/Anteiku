#!/usr/bin/env bash
# ============================================================
#  backup-cron.sh — run backup.sh on a schedule and TELL YOU about it.
#
#  Install (weekly, Sunday 03:00):
#    crontab -e
#    0 3 * * 0 /full/path/to/anteiku/scripts/backup-cron.sh
#
#  SILENCE IS THE ENEMY. A backup that stopped running six weeks ago
#  looks exactly like one that ran fine — you get nothing either way.
#  So this notifies on failure loudly AND on success quietly, which
#  makes a missing Sunday message a signal in itself.
#
#  Notifications are optional: set NTFY_URL and NTFY_TOPIC in .env.
#  Without them this still runs and still logs; it just cannot tell you.
# ============================================================
set -uo pipefail     # deliberately NOT -e: we must reach the notify step
                     # even when the backup fails. That is the whole point.
cd "$(dirname "$0")/.."

ENV_FILE="${ENV_FILE:-.env}"
[ -r "$ENV_FILE" ] && { set -a; . "./$ENV_FILE"; set +a; }

# Project-relative on purpose. A shared ~/backup-logs would collide with
# any other backup job on this machine - including one whose old logs we
# would then happily rotate away.
LOG_DIR="${BACKUP_LOG_DIR:-./backup-logs}"
mkdir -p "$LOG_DIR"
LOG="${LOG_DIR}/backup-$(date +%F_%H%M).log"

notify() {   # priority, tags, title, body
  [ -n "${NTFY_URL:-}" ] || return 0
  local auth=()
  [ -n "${NTFY_USER:-}" ] && [ -n "${NTFY_PASS:-}" ] && auth=(-u "${NTFY_USER}:${NTFY_PASS}")
  curl -s -o /dev/null --max-time 20 --retry 2 "${auth[@]}" \
    -H "Title: $3" -H "Priority: $1" -H "Tags: $2" \
    -d "$4" "${NTFY_URL}/${NTFY_TOPIC:-homelab}" \
    || echo "WARN: could not send notification" >&2
}

NO_COLOR=1 ./scripts/backup.sh >"$LOG" 2>&1
RC=$?

SUMMARY="$(tail -n 14 "$LOG")"
if [ "$RC" -eq 0 ]; then
  notify default white_check_mark "Backup OK" "$SUMMARY"
else
  notify urgent rotating_light "BACKUP FAILED" "$SUMMARY"
fi

# Keep the logs readable: 90 days is plenty to spot a pattern.
find "$LOG_DIR" -maxdepth 1 -name 'backup-*.log' -mtime +90 -delete 2>/dev/null

exit "$RC"
