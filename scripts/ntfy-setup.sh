#!/usr/bin/env bash
# ============================================================
#  ntfy-setup.sh — create the ntfy user your scripts publish as.
#
#  ntfy ships here with deny-all access, so nothing can publish or
#  subscribe until a user exists. Without that, anyone who can reach
#  the port reads every notification you send — and those say things
#  like "backup failed on <host>".
#
#    ./scripts/ntfy-setup.sh --dry-run
#    ./scripts/ntfy-setup.sh
#
#  Re-runnable: an existing user keeps its password from .env.
# ============================================================
set -uo pipefail
cd "$(dirname "$0")/.."
. lib/detect.sh

DRY_RUN=0
for a in "$@"; do case "$a" in
  --dry-run) DRY_RUN=1 ;;
  -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
  *) echo "unknown option: $a" >&2; exit 2 ;;
esac; done

ENV_FILE="${ENV_FILE:-.env}"
[ -r "$ENV_FILE" ] || { echo "No $ENV_FILE — run ./setup.sh first." >&2; exit 1; }
set -a; . "./$ENV_FILE"; set +a

case ",${COMPOSE_PROFILES:-}," in
  *,ntfy,*) ;;
  *) err "ntfy is not installed. Re-run ./setup.sh and select it."; exit 1 ;;
esac
: "${NTFY_USER:?NTFY_USER missing from .env}"
: "${NTFY_PASS:?NTFY_PASS missing from .env}"
TOPIC="${NTFY_TOPIC:-homelab}"
C="${STACK_PREFIX}ntfy"

h1 "Plan"
kv "container" "$C"
kv "user"      "$NTFY_USER"
kv "topic"     "$TOPIC"
note "The user gets read-write on '$TOPIC' only, not on everything."

if [ "$DRY_RUN" -eq 1 ]; then
  echo; printf '%s  DRY RUN — nothing changed.%s\n' "$C_WARN" "$C_RST"; exit 0
fi

docker ps --format '{{.Names}}' | grep -qx "$C" || {
  err "$C is not running. Start it first: docker compose up -d"; exit 1; }

h1 "Creating"
if docker exec "$C" ntfy user list 2>/dev/null | grep -q "^user ${NTFY_USER}"; then
  ok "user '$NTFY_USER' already exists"
else
  if NTFY_PASSWORD="$NTFY_PASS" docker exec -e NTFY_PASSWORD -i "$C" \
       ntfy user add "$NTFY_USER" >/dev/null 2>&1; then
    ok "created user '$NTFY_USER'"
  else
    err "could not create the user"; exit 1
  fi
fi

if docker exec "$C" ntfy access "$NTFY_USER" "$TOPIC" rw >/dev/null 2>&1; then
  ok "granted read-write on '$TOPIC'"
else
  err "could not grant access"; exit 1
fi

h1 "Testing"
URL="${NTFY_URL:-http://localhost:8095}"
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        -u "${NTFY_USER}:${NTFY_PASS}" \
        -H "Title: Homelab is wired up" -H "Tags: white_check_mark" \
        -d "If you can see this on your phone, alerting works." \
        "${URL}/${TOPIC}")"
if [ "$CODE" = "200" ]; then
  ok "published a test message (HTTP 200)"
else
  err "publish returned HTTP $CODE — check NTFY_URL in .env"
fi

h1 "Next"
echo "  1. Install the ntfy app (iOS / Android / web)."
echo "  2. Add your server, log in as '${NTFY_USER}', subscribe to '${TOPIC}'."
echo "  3. Point Uptime Kuma at it:"
echo "       Settings > Notifications > ntfy"
echo "       Server  http://${STACK_PREFIX}ntfy       (container name)"
echo "       Topic   ${TOPIC}"
echo "       Auth    username ${NTFY_USER}"
echo
echo "  Backups already use it: NTFY_URL and NTFY_TOPIC are in .env, so"
echo "  scripts/backup-cron.sh will push without further setup."
echo
