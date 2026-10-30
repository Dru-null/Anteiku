#!/usr/bin/env bash
# ============================================================
#  setup.sh — choose your services, then write the config for them.
#
#  Nothing is started here. This writes .env and picks which stacks
#  compose includes; you review it, then run docker compose yourself.
#
#    ./setup.sh --dry-run      show every decision, write NOTHING
#    ./setup.sh                interactive, writes .env after confirming
#    ./setup.sh --reconfigure  re-run that may CHANGE installed services
#    ./setup.sh --plain        numbered menu instead of the full-screen one
#
#  Re-running is safe: services you already installed are locked, and
#  you can only add new ones. --reconfigure unlocks them, deliberately.
# ============================================================
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/detect.sh
. lib/detect.sh

DRY_RUN=0
ENV_FILE=".env"
ASSUME_YES=0
RECONFIGURE=0
PLAIN=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --env-file=*) ENV_FILE="${a#*=}" ;;
    --reconfigure) RECONFIGURE=1 ;;
    --plain)       PLAIN=1 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
    *) echo "unknown option: $a (try --help)" >&2; exit 2 ;;
  esac
done

banner "anteiku $S_DOT setup" "pick your services, write your config"
[ "$DRY_RUN" -eq 1 ] && printf '\n  %s%s DRY RUN %s nothing will be written%s\n' "$C_B$C_WARN" "$S_WARN" "$S_DOT" "$C_RST"

# ============================================================
#  Re-running: the existing .env IS the defaults.
#
#  People re-run this to add a service, and the guides tell them to edit
#  .env by hand. A re-run must not undo either. Rebuilding .env from
#  scratch would, silently:
#    - change generated passwords, locking services out of data that is
#      perfectly fine (a database only reads its password once)
#    - flip VAULTWARDEN_SIGNUPS back to true on a password manager
#    - reset a hand-set MEDIA_ROOT, so the library "disappears"
#
#  So every value in an existing .env is kept, unless you override it in
#  the environment for this run. Only values derived from your hardware
#  or from this run's selection are recomputed.
# ============================================================
# Secrets this script generates. They come from an existing .env or are
# generated fresh - NEVER from your shell environment. A password exported
# in ~/.bashrc for some other tool (NTFY_PASS is a common one) would
# otherwise be silently reused here, and printed in the preview below.
SECRET_KEYS="PIHOLE_PASSWORD NTFY_PASS KUMA_PASSWORD IMMICH_DB_PASSWORD VAULTWARDEN_ADMIN_TOKEN"
for k in $SECRET_KEYS; do unset "$k"; done

PREV_PROFILES=""
if [ -r "$ENV_FILE" ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      ''|'#'*|*' '*) continue ;;
      PORT_*)            PREV_PORTS="${PREV_PORTS:-} $k=$v" ;;
      COMPOSE_PROFILES)  PREV_PROFILES="$v" ;;
      # recomputed every run
      COMPOSE_FILE|IMMICH_ML_URL|RENDER_GID|INTEL_RENDER_PATH|AMD_RENDER_PATH|NTFY_URL|PUID|PGID) ;;
      *) [ -n "${!k+x}" ] || export "$k=$v" ;;
    esac
  done < "$ENV_FILE"
fi
prev_port() { local e; for e in ${PREV_PORTS:-}; do [ "${e%%=*}" = "$1" ] && { echo "${e#*=}"; return; }; done; }

detect_os; detect_cpu; detect_mem; detect_gpu; detect_render; detect_docker

# ============================================================
#  Service catalogue.  key|stack|default|hostport|internalport|description
#  hostport is only a PREFERENCE — setup.sh moves it if it is taken.
#  internalport is fixed by the image and is what other containers use.
#  Add a row here when a stack gains a service.
# ============================================================
CATALOGUE="
prowlarr|arr|on|9696|9696|Indexer manager: the hub the *arrs ask
qbittorrent|arr|on|8181|8080|Download client
sonarr|arr|on|8989|8989|TV library management
radarr|arr|on|7878|7878|Movie library management
lidarr|arr|off|8686|8686|Music library management
lazylibrarian|arr|off|5299|5299|Books and audiobooks
bazarr|arr|off|6767|6767|Subtitles for Sonarr/Radarr libraries
seerr|arr|on|5055|5055|Request UI for your household
jellyfin|media|on|8096|8096|Film and TV streaming: the main event
navidrome|media|off|4533|4533|Music streaming (Subsonic-compatible apps)
kavita|media|off|5000|5000|Ebooks and comics reader
nginx-proxy-manager|infra|off|80|80|Reverse proxy: nice hostnames, not ports
pihole|infra|off|53|53|Network-wide DNS and ad blocking
uptime-kuma|monitoring|off|3001|3001|Uptime checks and phone alerts
dozzle|monitoring|off|8888|8080|Container logs in a browser
immich|photos|off|2283|2283|Photo and video backup for your phone
immich-ml|photos|off|-|-|Face recognition and smart search for Immich
ntfy|extras|off|8095|80|Push notifications to your phone
vaultwarden|extras|off|8222|80|Password manager, Bitwarden-compatible
calibre-web|books|off|8083|8083|Ebook library manager, auto-import, Send-to-Kindle
"

CAT_KEYS=(); CAT_STACK=(); CAT_DEF=(); CAT_PORT=(); CAT_INTERNAL=(); CAT_DESC=()
while IFS='|' read -r _k _s _d _p _ip _desc; do
  [ -z "${_k:-}" ] && continue
  CAT_KEYS+=("$_k"); CAT_STACK+=("$_s"); CAT_DEF+=("$_d")
  CAT_PORT+=("$_p"); CAT_INTERNAL+=("$_ip"); CAT_DESC+=("$_desc")
done <<< "$(echo "$CATALOGUE" | sed '/^[[:space:]]*$/d')"

N=${#CAT_KEYS[@]}
SEL=()
for ((i=0;i<N;i++)); do [ "${CAT_DEF[$i]}" = "on" ] && SEL+=(1) || SEL+=(0); done
# Re-running? Start from what you already have, not the catalogue defaults
# - otherwise pressing Enter quietly drops services you added earlier.
if [ -n "$PREV_PROFILES" ]; then
  for ((i=0;i<N;i++)); do
    case ",$PREV_PROFILES," in *",${CAT_KEYS[$i]},"*) SEL[i]=1 ;; *) SEL[i]=0 ;; esac
  done
fi
# Installed earlier, since removed from Anteiku (Diun, for one). This run
# drops them from COMPOSE_PROFILES, so compose stops managing them, but
# their containers keep running. The end of the run says how to finish.
GONE=()
IFS=, read -ra _prev <<< "$PREV_PROFILES"
for x in "${_prev[@]}"; do
  [ -n "$x" ] || continue
  case " ${CAT_KEYS[*]} " in *" $x "*) ;; *) GONE+=("$x") ;; esac
done

# ============================================================
#  Re-run detection.
#
#  An existing .env means services are already installed and holding
#  data. Changing them from here can strand that data or break other
#  services that point at them, so by default they are LOCKED: shown,
#  greyed out, not toggleable. You can only add what you do not have.
#  --reconfigure unlocks them, after saying plainly what can break.
# ============================================================
RERUN=0; INST=()
for ((i=0;i<N;i++)); do INST+=(0); done
if [ -n "$PREV_PROFILES" ]; then
  RERUN=1
  for ((i=0;i<N;i++)); do
    case ",$PREV_PROFILES," in *",${CAT_KEYS[$i]},"*) INST[i]=1 ;; esac
  done
fi
N_INST=0; for ((i=0;i<N;i++)); do N_INST=$((N_INST + INST[i])); done
LOCKED=0; [ "$RERUN" -eq 1 ] && [ "$RECONFIGURE" -eq 0 ] && LOCKED=1

if [ "$RERUN" -eq 1 ]; then
  h1 "Existing install found"
  RUNNING=0
  [ "$DET_DOCKER_OK" -eq 1 ] && RUNNING="$(docker ps -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-anteiku}" 2>/dev/null | wc -l)"
  info "$N_INST service(s) installed by an earlier run ${C_GREY}($ENV_FILE, $RUNNING container(s) running)${C_RST}"
  if [ "$LOCKED" -eq 1 ]; then
    note "Installed services are locked — you can only ADD new ones."
    note "Their ports, paths and passwords are kept exactly as they are."
    note "To change or remove installed services:  ./setup.sh --reconfigure"
  else
    echo
    warn "--reconfigure: installed services are UNLOCKED."
    note "Changing a running install can break it. Specifically:"
    note "$S_DOT Deselecting a service stops managing it. Its container keeps"
    note "  running and its data stays in appdata until you remove them."
    note "$S_DOT Anything pointing at a removed service breaks: Kuma monitors,"
    note "  proxy hosts, Seerr -> Sonarr/Radarr, backups of its database."
    note "$S_DOT Paths and passwords are never changed here. Moving MEDIA_ROOT"
    note "  or APPDATA means moving the data yourself, first."
    if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ] && [ "$DRY_RUN" -eq 0 ]; then
      printf '\n  Type %sreconfigure%s to continue, anything else to stop: ' "$C_B$C_WARN" "$C_RST"
      read -r ans || ans=""
      [ "$ans" = "reconfigure" ] || { echo; info "Stopped. Nothing was changed."; exit 0; }
    fi
  fi
elif [ "$RECONFIGURE" -eq 1 ]; then
  info "--reconfigure has nothing to unlock: no existing install found."
fi

STACK_ORDER="arr media infra monitoring photos extras books"
stack_label() {
  case "$1" in
    arr)        echo "find, fetch and organise" ;;
    media)      echo "watch, listen, read" ;;
    infra)      echo "proxy, network-wide DNS, update alerts" ;;
    monitoring) echo "know when something breaks" ;;
    photos)     echo "phone photo backup" ;;
    extras)     echo "alerts and passwords" ;;
    books)      echo "ebook library" ;;
  esac
}
svc_tag() {
  case "$1" in
    immich-ml)   printf '%s' "${C_WARN}CPU-heavy${C_RST}" ;;
    vaultwarden) printf '%s' "${C_WARN}needs HTTPS${C_RST}" ;;
  esac
}
COLS="$( (tput cols) 2>/dev/null || echo 100)"; [ "${COLS:-0}" -gt 20 ] 2>/dev/null || COLS=100
DESC_W=$(( COLS - 50 )); [ "$DESC_W" -lt 20 ] && DESC_W=20; [ "$DESC_W" -gt 56 ] && DESC_W=56
MENU_MSG=""
# Fresh installs start with a starter set ticked. Say so, or the ticks
# read as "already installed".
FRESH_HINT="A starter set is ticked for you. Untick anything you don't want."

render_menu() {
  local st i box name desc tag numc namec descc n_sel=0 n_new=0
  h1 "Choose what to install"
  [ "$RERUN" -eq 0 ] && printf '  %s\n' "$FRESH_HINT"
  printf '  %sShips NO indexers and no sources %s Prowlarr starts empty.%s\n' "$C_GREY" "$S_DOT" "$C_RST"
  for st in $STACK_ORDER; do
    printf '\n  %s%s%s %s%s %s%s\n' "$C_B" "$st" "$C_RST" "$C_GREY" "$S_DOT" "$(stack_label "$st")" "$C_RST"
    for ((i=0;i<N;i++)); do
      [ "${CAT_STACK[$i]}" = "$st" ] || continue
      desc="${CAT_DESC[$i]}"
      [ "${#desc}" -gt "$DESC_W" ] && desc="${desc:0:$((DESC_W-3))}..."
      tag="$(svc_tag "${CAT_KEYS[$i]}")"
      numc="$C_INF"; namec=""; descc="$C_DIM"
      if [ "$LOCKED" -eq 1 ] && [ "${INST[$i]}" -eq 1 ]; then
        box="${C_GREY}[${S_LOCK}]${C_RST}"; numc="$C_GREY"; namec="$C_GREY"; descc="$C_GREY"
        tag="${C_GREY}installed${C_RST}"
      elif [ "${SEL[$i]}" -eq 1 ]; then
        box="${C_OK}${C_B}[${S_ON}]${C_RST}"; namec="$C_B"
        if [ "$RERUN" -eq 1 ] && [ "${INST[$i]}" -eq 0 ]; then tag="${C_ACC}${C_B}new${C_RST}${tag:+ $tag}"; n_new=$((n_new+1)); fi
      elif [ "${INST[$i]}" -eq 1 ]; then
        box="${C_ERR}${C_B}[ ]${C_RST}"; namec="$C_ERR"; tag="${C_ERR}${C_B}remove${C_RST}"
      else
        box="${C_DIM}[ ]${C_RST}"
      fi
      [ "${SEL[$i]}" -eq 1 ] && n_sel=$((n_sel+1))
      printf '   %s%3d%s  %s  %s%s%s %s%s%s %s\n' \
        "$numc" $((i+1)) "$C_RST" "$box" "$namec" "$(_pad "${CAT_KEYS[$i]}" 20)" "$C_RST" \
        "$descc" "$(_pad "$desc" "$DESC_W")" "$C_RST" "$tag"
    done
  done
  echo
  if [ "$RERUN" -eq 1 ]; then
    printf '  %s%d selected%s %s %s%d new%s %s %s%d installed%s\n' "$C_OK" "$n_sel" "$C_RST" "$S_DOT" "$C_ACC" "$n_new" "$C_RST" "$S_DOT" "$C_GREY" "$N_INST" "$C_RST"
  else
    printf '  %s%d selected%s\n' "$C_OK" "$n_sel" "$C_RST"
  fi
  printf '  %s2 5 7%s toggle %s %sa%s all %s %sn%s none %s %sEnter%s done\n' \
    "$C_B$C_INF" "$C_RST" "$S_DOT" "$C_B$C_INF" "$C_RST" "$S_DOT" "$C_B$C_INF" "$C_RST" "$S_DOT" "$C_B$C_INF" "$C_RST"
  [ -n "$MENU_MSG" ] && printf '  %s\n' "$MENU_MSG"
  return 0
}

is_locked() { [ "$LOCKED" -eq 1 ] && [ "${INST[$1]}" -eq 1 ]; }

# Physical lines a block occupies on screen: a line longer than the
# terminal wraps, and the redraw must move up past every wrapped piece
# or it erases what is above the menu. Counts characters, not bytes, so
# the box-drawing symbols count as one column each.
_screen_lines() {
  local total=0 line len
  while IFS= read -r line; do
    line="$(printf '%s' "$line" | sed 's/\x1b\[[0-9;]*m//g')"
    len=${#line}
    total=$(( total + (len == 0 ? 1 : (len - 1) / COLS + 1) ))
  done <<< "$1"
  echo "$total"
}

# ============================================================
#  The full-screen picker.
#    up/down (or j/k) move   space toggle   a all   n none
#    PgUp/PgDn/Home/End      enter continue  q quit, nothing written
#
#  Pure bash on purpose: no dialog/whiptail/python dependency, and it
#  can grey out locked services and show tags, which whiptail cannot.
#  Runs on the terminal's alternate screen, so your scrollback is left
#  exactly as it was, and the terminal is restored however it exits -
#  including Ctrl-C.
# ============================================================
case "$S_OK" in
  '✔') S_UP='↑'; S_DN='↓'; S_PTR='❯' ;;
  *)   S_UP='up'; S_DN='/down'; S_PTR='>' ;;
esac
C_REV=''; [ -n "$C_RST" ] && C_REV=$'\033[7m'

# Can we draw a full screen? Needs a real terminal both ways, a TERM
# that understands cursor control, and room for the list to be useful.
_tui_ok() {
  [ "$PLAIN" -eq 0 ] && [ -t 0 ] && [ -t 1 ] || return 1
  case "${TERM:-dumb}" in dumb|unknown) return 1 ;; esac
  local r c; read -r r c < <(stty size 2>/dev/null) || return 1
  [ "${r:-0}" -ge 16 ] && [ "${c:-0}" -ge 60 ]
}

# Longer explanation for the highlighted row.
_tui_detail() {
  local i="$1"
  if is_locked "$i"; then
    printf '%sInstalled - locked so a re-run cannot break it. To change it: ./setup.sh --reconfigure%s' "$C_GREY" "$C_RST"; return
  fi
  case "${CAT_KEYS[$i]}" in
    immich-ml)   printf '%sCPU-heavy:%s the first scan uses every core for hours. Immich works fully without it.' "$C_WARN$C_B" "$C_RST" ;;
    vaultwarden) printf '%sNeeds HTTPS:%s browser extensions and phone apps refuse plain http. See stacks/extras.md.' "$C_WARN$C_B" "$C_RST" ;;
    *)           printf '%s' "${CAT_DESC[$i]}"
                 [ "${CAT_PORT[$i]}" != "-" ] && printf '  %s%s default port %s%s' "$C_GREY" "$S_DOT" "${CAT_PORT[$i]}" "$C_RST" ;;
  esac
}

_tui_key() {   # sets KEY
  local k k2
  KEY=""
  IFS= read -rsn1 k || { KEY=quit; return; }
  case "$k" in
    $'\033')
      IFS= read -rsn2 -t 0.05 k2 || true
      case "$k2" in
        '[A'|'OA') KEY=up ;;   '[B'|'OB') KEY=down ;;
        '[H'|'OH') KEY=home ;; '[F'|'OF') KEY=end ;;
        '[5') IFS= read -rsn1 -t 0.05 _ || true; KEY=pgup ;;
        '[6') IFS= read -rsn1 -t 0.05 _ || true; KEY=pgdn ;;
        '')   KEY=quit ;;   # a bare Esc
      esac ;;
    ' ')   KEY=space ;;
    '')    KEY=enter ;;
    k|K)   KEY=up ;;  j|J) KEY=down ;;
    a|A)   KEY=all ;; n|N) KEY=none ;;
    q|Q)   KEY=quit ;;
  esac
}

_tui_draw() {
  local rows cols body total=0 line pos i st desc dw tag box namec descc ptr n_sel=0 n_new=0
  read -r rows cols < <(stty size 2>/dev/null) || { rows=24; cols=80; }
  body=$(( rows - 7 - (1 - RERUN) ))   # fresh installs: one more line for the hint
  dw=$(( cols - 50 )); [ "$dw" -lt 16 ] && dw=16; [ "$dw" -gt 60 ] && dw=60

  # Build every line of the list, remembering where each item sits.
  local DL=() ITEMLINE=() GRPHDR=() hdr
  pos=0
  for st in $STACK_ORDER; do
    [ "${#DL[@]}" -gt 0 ] && DL+=("")
    hdr=${#DL[@]}
    DL+=("  ${C_B}${st}${C_RST} ${C_GREY}${S_DOT} $(stack_label "$st")${C_RST}")
    for i in "${ORDER[@]}"; do
      [ "${CAT_STACK[$i]}" = "$st" ] || continue
      desc="${CAT_DESC[$i]}"
      [ "${#desc}" -gt "$dw" ] && desc="${desc:0:$((dw-3))}..."
      tag="$(svc_tag "${CAT_KEYS[$i]}")"; namec=""; descc="$C_DIM"
      if is_locked "$i"; then
        box="${C_GREY}[${S_LOCK}]${C_RST}"; namec="$C_GREY"; descc="$C_GREY"; tag="${C_GREY}installed${C_RST}"
      elif [ "${SEL[$i]}" -eq 1 ]; then
        box="${C_OK}${C_B}[${S_ON}]${C_RST}"; namec="$C_B"
        if [ "$RERUN" -eq 1 ] && [ "${INST[$i]}" -eq 0 ]; then tag="${C_ACC}${C_B}new${C_RST}${tag:+ $tag}"; fi
      elif [ "${INST[$i]}" -eq 1 ]; then
        box="${C_ERR}${C_B}[ ]${C_RST}"; namec="$C_ERR"; tag="${C_ERR}${C_B}remove${C_RST}"
      else
        box="${C_DIM}[ ]${C_RST}"
      fi
      if [ "$pos" -eq "$CUR" ]; then
        ptr="${C_ACC}${C_B}${S_PTR}${C_RST}"; namec="${namec}${C_B}${C_REV}"
      else
        ptr=" "
      fi
      ITEMLINE+=("${#DL[@]}"); GRPHDR+=("$hdr")
      DL+=("  ${ptr} ${box}  ${namec}$(_pad "${CAT_KEYS[$i]}" 20)${C_RST} ${descc}$(_pad "$desc" "$dw")${C_RST} ${tag}")
      pos=$((pos+1))
    done
  done
  total=${#DL[@]}
  for i in "${ORDER[@]}"; do [ "${SEL[$i]}" -eq 1 ] && { n_sel=$((n_sel+1)); [ "${INST[$i]}" -eq 0 ] && [ "$RERUN" -eq 1 ] && n_new=$((n_new+1)); }; done

  # Scroll so the highlighted row is visible - and its group header too,
  # when that fits, so you always know which stack you are in.
  line=${ITEMLINE[$CUR]}
  if [ "$line" -lt "$TOP" ]; then
    TOP=$line
    # first item of its group: show the group's header with it
    [ $(( line - ${GRPHDR[$CUR]} )) -eq 1 ] && TOP=${GRPHDR[$CUR]}
  fi
  [ "$line" -ge $(( TOP + body )) ] && TOP=$(( line - body + 1 ))
  [ "$TOP" -gt $(( total - body )) ] && TOP=$(( total - body ))
  [ "$TOP" -lt 0 ] && TOP=0

  # One write per frame: cursor home, each line cleared to its end.
  local F=$'\033[H' counts
  counts="${C_OK}${n_sel} selected${C_RST}"
  [ "$RERUN" -eq 1 ] && counts="$counts ${C_GREY}${S_DOT}${C_RST} ${C_ACC}${n_new} new${C_RST} ${C_GREY}${S_DOT} ${N_INST} installed${C_RST}"
  F+="  ${C_B}${C_INF}anteiku${C_RST} ${C_GREY}${S_DOT}${C_RST} ${C_B}choose what to install${C_RST}    ${counts}"$'\033[K\n'
  [ "$RERUN" -eq 0 ] && F+="  ${FRESH_HINT}"$'\033[K\n'
  F+="  ${C_GREY}Ships NO indexers and no sources ${S_DOT} Prowlarr starts empty.${C_RST}"$'\033[K\n\033[K\n'
  for (( i=TOP; i<TOP+body; i++ )); do
    [ "$i" -lt "$total" ] && F+="${DL[$i]}"
    F+=$'\033[K\n'
  done
  local more=""
  [ "$TOP" -gt 0 ] && more="${S_UP} more above"
  [ $(( TOP + body )) -lt "$total" ] && more="${more:+$more  }${S_DN#/} more below"
  F+="  ${C_GREY}${more}${C_RST}"$'\033[K\n'
  F+="  $(_tui_detail "${ORDER[$CUR]}")"$'\033[K\n'
  F+="  ${MSG}"$'\033[K\n'
  F+="  ${C_B}${C_INF}${S_UP}${S_DN}${C_RST} move  ${C_B}${C_INF}space${C_RST} select  ${C_B}${C_INF}a${C_RST} all  ${C_B}${C_INF}n${C_RST} none  ${C_B}${C_INF}enter${C_RST} continue  ${C_B}${C_INF}q${C_RST} quit"$'\033[K\033[J'
  printf '%s' "$F"
}

# Returns 0 on enter, 1 on quit.
tui_select() {
  local saved i st
  ORDER=()
  for st in $STACK_ORDER; do
    for ((i=0;i<N;i++)); do [ "${CAT_STACK[$i]}" = "$st" ] && ORDER+=("$i"); done
  done
  CUR=0; TOP=0; MSG=""
  saved="$(stty -g 2>/dev/null)"
  _tui_restore() { printf '\033[?25h\033[?1049l'; [ -n "$saved" ] && stty "$saved" 2>/dev/null; return 0; }
  trap '_tui_restore; echo; info "Cancelled. Nothing was written."; exit 130' INT TERM
  trap '_tui_restore' EXIT
  trap '_tui_draw' WINCH
  printf '\033[?1049h\033[?25l\033[H\033[J'
  stty -echo 2>/dev/null

  local n=${#ORDER[@]} idx
  while :; do
    _tui_draw
    MSG=""
    _tui_key
    idx="${ORDER[$CUR]}"
    case "$KEY" in
      up)    [ "$CUR" -gt 0 ] && CUR=$((CUR-1)) ;;
      down)  [ "$CUR" -lt $((n-1)) ] && CUR=$((CUR+1)) ;;
      pgup)  CUR=$((CUR-10)); [ "$CUR" -lt 0 ] && CUR=0 ;;
      pgdn)  CUR=$((CUR+10)); [ "$CUR" -gt $((n-1)) ] && CUR=$((n-1)) ;;
      home)  CUR=0 ;;
      end)   CUR=$((n-1)) ;;
      space) if is_locked "$idx"; then
               MSG="${C_WARN}${S_WARN} ${CAT_KEYS[$idx]} is installed (locked).${C_RST} ${C_GREY}--reconfigure unlocks it.${C_RST}"
             else
               SEL[idx]=$(( 1 - SEL[idx] ))
             fi ;;
      all)   for i in "${ORDER[@]}"; do is_locked "$i" || SEL[i]=1; done ;;
      none)  for i in "${ORDER[@]}"; do is_locked "$i" || SEL[i]=0; done ;;
      enter) break ;;
      quit)  _tui_restore; trap - INT TERM EXIT WINCH; return 1 ;;
    esac
  done
  _tui_restore; trap - INT TERM EXIT WINCH
  return 0
}

# After the full-screen picker closes, leave a record of the choice in
# the normal scrollback - otherwise it vanishes with the alternate screen.
print_selection() {
  local st i names
  h1 "Selected"
  for st in $STACK_ORDER; do
    names=""
    for i in "${ORDER[@]}"; do
      [ "${CAT_STACK[$i]}" = "$st" ] && [ "${SEL[$i]}" -eq 1 ] && names="${names:+$names, }${CAT_KEYS[$i]}"
    done
    [ -n "$names" ] && printf '  %s%s%s %s\n' "$C_GREY" "$(_pad "$st" 12)" "$C_RST" "$names"
  done
  return 0
}

if [ "$ASSUME_YES" -eq 0 ] && _tui_ok; then
  if ! tui_select; then
    echo; info "Stopped. Nothing was written."; exit 1
  fi
  [ "$RERUN" -eq 0 ] && print_selection
elif [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
  MENU_LINES=0
  while :; do
    # Redraw in place on a colour terminal instead of scrolling a fresh
    # copy of the menu up the screen on every keypress.
    if [ -n "$C_RST" ] && [ "$MENU_LINES" -gt 0 ]; then
      printf '\033[%dA\033[J' $(( MENU_LINES + 1 ))
    fi
    MENU_TXT="$(render_menu)"
    printf '%s\n' "$MENU_TXT"
    MENU_LINES="$(_screen_lines "$MENU_TXT")"
    MENU_MSG=""
    printf '  %s%s%s ' "$C_B$C_INF" "$S_PROMPT" "$C_RST"; read -r reply || break
    [ -z "$reply" ] && break
    case "$reply" in
      a|A) for ((i=0;i<N;i++)); do is_locked "$i" || SEL[i]=1; done ;;
      n|N) for ((i=0;i<N;i++)); do is_locked "$i" || SEL[i]=0; done ;;
      *) for tok in $reply; do
           case "$tok" in
             ''|*[!0-9]*) MENU_MSG="${C_WARN}${S_WARN} ignored '${tok}' — type numbers, like 2 5 7${C_RST}" ;;
             *) idx=$((tok-1))
                if [ "$idx" -lt 0 ] || [ "$idx" -ge "$N" ]; then
                  MENU_MSG="${C_WARN}${S_WARN} there is no number ${tok}${C_RST}"
                elif is_locked "$idx"; then
                  MENU_MSG="${C_WARN}${S_WARN} ${CAT_KEYS[$idx]} is installed (locked).${C_RST} ${C_GREY}--reconfigure unlocks it.${C_RST}"
                else
                  SEL[idx]=$(( 1 - SEL[idx] ))
                fi ;;
           esac
         done ;;
    esac
  done
else
  render_menu
  info "non-interactive: $( [ "$RERUN" -eq 1 ] && echo 'keeping what is installed' || echo 'using defaults')"
fi

# Immich ML is an add-on to Immich, never on its own.
for ((i=0;i<N;i++)); do [ "${CAT_KEYS[$i]}" = immich-ml ] && IML=$i; [ "${CAT_KEYS[$i]}" = immich ] && IMM=$i; done
if [ "${SEL[$IML]}" -eq 1 ] && [ "${SEL[$IMM]}" -eq 0 ]; then
  SEL[IMM]=1
  info "immich-ml needs immich — added it."
fi

# What actually changes this run.
ADDED=(); REMOVED=()
for ((i=0;i<N;i++)); do
  [ "${SEL[$i]}" -eq 1 ] && [ "${INST[$i]}" -eq 0 ] && ADDED+=("${CAT_KEYS[$i]}")
  [ "${SEL[$i]}" -eq 0 ] && [ "${INST[$i]}" -eq 1 ] && REMOVED+=("${CAT_KEYS[$i]}")
done
if [ "$RERUN" -eq 1 ]; then
  h1 "Changes"
  if [ "${#ADDED[@]}" -eq 0 ] && [ "${#REMOVED[@]}" -eq 0 ] && [ "${#GONE[@]}" -eq 0 ]; then
    info "No change to your services ${S_DOT} refreshing config only (.env, ports.md)."
  fi
  for x in "${ADDED[@]}";   do printf '  %s+%s  %s%s%s\n' "$C_OK$C_B" "$C_RST" "$C_B" "$x" "$C_RST"; done
  for x in "${REMOVED[@]}"; do printf '  %s−%s  %s%s%s %s(container and data are NOT deleted — see the end)%s\n' "$C_ERR$C_B" "$C_RST" "$C_ERR" "$x" "$C_RST" "$C_GREY" "$C_RST"; done
  for x in "${GONE[@]}";    do printf '  %s−%s  %s%s%s %s(no longer part of Anteiku; container and data are NOT deleted — see the end)%s\n' "$C_ERR$C_B" "$C_RST" "$C_ERR" "$x" "$C_RST" "$C_GREY" "$C_RST"; done
fi

CHOSEN=()
for ((i=0;i<N;i++)); do [ "${SEL[$i]}" -eq 1 ] && CHOSEN+=("${CAT_KEYS[$i]}"); done

# A random password. Note the subshell disables pipefail: tr gets
# SIGPIPE when head stops reading, which would otherwise fail the
# pipeline and append the fallback to a perfectly good password.
_genpw() {
  ( set +o pipefail
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 20 ) \
  || date +%s%N | sha256sum | head -c 20
}

# _sel_has <service> -> 0 if the user chose it
_sel_has() {
  local want="$1" c
  for c in "${CHOSEN[@]}"; do [ "$c" = "$want" ] && return 0; done
  return 1
}
if [ "${#CHOSEN[@]}" -eq 0 ]; then echo; echo "Nothing selected. Exiting."; exit 0; fi

# ============================================================
#  Guard: never collide with a stack that is already running.
# ============================================================
h1 "Safety check"
STACK_PREFIX="${STACK_PREFIX:-}"
COLLIDE=(); OURS=0
MY_PROJECT="${COMPOSE_PROJECT_NAME:-anteiku}"
if [ "$DET_DOCKER_OK" -eq 1 ]; then
  # name -> compose project label. A container that already belongs to
  # THIS project is not a collision: that is you re-running setup.sh to
  # add or remove a service, which every guide here tells you to do.
  EXISTING="$(docker ps -a --format '{{.Names}}|{{.Label "com.docker.compose.project"}}' 2>/dev/null)"
  for ((i=0;i<N;i++)); do
    [ "${SEL[$i]}" -eq 1 ] || continue
    name="${STACK_PREFIX}${CAT_KEYS[$i]}"
    owner="$(echo "$EXISTING" | awk -F'|' -v n="$name" '$1==n{print $2; exit}')"
    [ -z "$(echo "$EXISTING" | awk -F'|' -v n="$name" '$1==n')" ] && continue
    if [ "$owner" = "$MY_PROJECT" ]; then
      OURS=$((OURS+1))
    else
      COLLIDE+=("$name (belongs to '${owner:-no compose project}')")
    fi
  done
fi

if [ "${#COLLIDE[@]}" -gt 0 ]; then
  err "${#COLLIDE[@]} container name(s) already exist on this machine:"
  for c in "${COLLIDE[@]}"; do note "$c"; done
  note ""
  note "Continuing would let compose adopt or replace containers that are"
  note "not part of this project. Refusing."
  note ""
  if [ -n "$STACK_PREFIX" ]; then
    note "You already have STACK_PREFIX='$STACK_PREFIX'. Either those are"
    note "your own containers from a previous run — bring them down with"
    note "'docker compose down' first — or pick a different prefix."
  else
    note "If you are deliberately running a second copy alongside an existing"
    note "stack, set a prefix and re-run:   STACK_PREFIX=test- ./setup.sh"
  fi
  exit 1
fi
ok "No container name collisions."
[ "$OURS" -gt 0 ] && note "$OURS already running from this project — re-running is fine; compose updates them in place."

if [ "$DET_DOCKER_OK" -eq 1 ] && docker network inspect homelab >/dev/null 2>&1 \
   && [ "${DOCKER_NETWORK:-anteiku}" = "homelab" ]; then
  err "A docker network called 'homelab' already exists and you are targeting it."
  note "Pick a different DOCKER_NETWORK so this project stays separate."
  exit 1
fi
ok "Network name is free of conflicts."

# ============================================================
#  Ports — shift any that are taken.
# ============================================================
h1 "Ports"
declare -A PORT_FINAL
declare -A PORT_CLAIMED     # ports handed out in THIS run
declare -A PORT_MOVED       # key -> original, for the ones we shifted

# Walk upward one port at a time until we find one that is neither in use
# on the host nor already claimed by an earlier service in this same run.
# Without the claim check two services can both be told "5056 is free".
# Catalogue key -> compose service name, where they differ.
svc_of() { case "$1" in immich) echo immich-server ;; *) echo "$1" ;; esac; }

# Is <port> published by THIS project's container for <service>? Then it
# is that service's own port from a previous run, not a clash. Without
# this, re-running setup.sh on a running stack walks every service one
# port further each time.
held_by_us() {
  [ "$DET_DOCKER_OK" -eq 1 ] || return 1
  docker ps --filter "label=com.docker.compose.project=${MY_PROJECT}" \
            --filter "label=com.docker.compose.service=$2" \
            --format '{{.Ports}}' 2>/dev/null | grep -qE "[:.]$1->"
}
usable() {   # port service
  [ -z "${PORT_CLAIMED[$1]:-}" ] || return 1
  ! port_in_use "$1" || held_by_us "$1" "$2"
}

# Preference order, so ports stay put across re-runs:
#   1. the default, if usable  (lets a freed port 53 go back to Pi-hole)
#   2. last run's port, if still usable
#   3. walk upward from the default
find_free_port() {   # default service [previous]
  local p="$1" svc="$2" prev="${3:-}" tries=0
  if usable "$p" "$svc"; then echo "$p"; return 0; fi
  if [ -n "$prev" ] && usable "$prev" "$svc"; then echo "$prev"; return 0; fi
  while [ "$tries" -lt 500 ]; do
    p=$(( p + 1 )); tries=$(( tries + 1 ))
    [ "$p" -gt 65535 ] && break
    if usable "$p" "$svc"; then echo "$p"; return 0; fi
  done
  return 1
}

# Secondary ports some services publish beyond their main web UI.
#   owner|VARNAME|default|note-if-moved
#   owner|VARNAME|default|what it is|consequence-if-moved
#     harmless - just use the new port
#     discovery - stops working; everything else fine
#     certs     - Let's Encrypt validation breaks
EXTRA_PORTS="
jellyfin|PORT_JELLYFIN_DISCOVERY|7359|client auto-discovery|discovery
jellyfin|PORT_JELLYFIN_DLNA|1900|DLNA announcement|discovery
nginx-proxy-manager|PORT_NPM_HTTPS|443|HTTPS traffic|certs
nginx-proxy-manager|PORT_NPM_ADMIN|81|the NPM admin UI|harmless
pihole|PORT_PIHOLE_WEB|8053|the Pi-hole admin UI|harmless
"

PORT_SHIFTS=0
DISCOVERY_MOVED=0
for ((i=0;i<N;i++)); do
  [ "${SEL[$i]}" -eq 1 ] || continue
  k="${CAT_KEYS[$i]}"; orig="${CAT_PORT[$i]}"
  if [ "$orig" = "-" ]; then ok "$k: no ports to publish"; continue; fi
  VAR="PORT_$(echo "$k" | tr '[:lower:]-' '[:upper:]_')"
  if ! p="$(find_free_port "$orig" "$(svc_of "$k")" "$(prev_port "$VAR")")"; then
    err "$k: no free port found at or above $orig."
    note "Free something up, or set PORT_$(echo "$k" | tr '[:lower:]-' '[:upper:]_') by hand."
    exit 1
  fi
  PORT_FINAL["$k"]="$p"; PORT_CLAIMED["$p"]=1
  if [ "$p" != "$orig" ]; then
    PORT_MOVED["$k"]="$orig"; PORT_SHIFTS=$(( PORT_SHIFTS + 1 ))
    warn "$k: $orig taken by $(who_has_port "$orig") — moved to $p"
  else
    ok "$k: $p"
  fi
done
# Secondary ports, same +1 walk and same claim tracking.
declare -A EXTRA_FINAL
while IFS='|' read -r owner var dflt what impact; do
  [ -z "${owner:-}" ] && continue
  _sel_has "$owner" || continue
  if ! p="$(find_free_port "$dflt" "$(svc_of "$owner")" "$(prev_port "$var")")"; then
    warn "$var: no free port at or above $dflt — $what will be unavailable."
    continue
  fi
  EXTRA_FINAL["$var"]="$p"; PORT_CLAIMED["$p"]=1
  if [ "$p" = "$dflt" ]; then
    ok "$var: $p  ($what)"
    continue
  fi
  warn "$var: $dflt taken by $(who_has_port "$dflt") — moved to $p"
  case "$impact" in
    discovery)
      DISCOVERY_MOVED=1
      note "$what only works on its standard port, so clients will not"
      note "find the server by themselves. Enter the address by hand."
      note "Playback and everything else are unaffected." ;;
    certs)
      note "Let's Encrypt validates by connecting to the standard port"
      note "from the internet. On $p, automatic certificates will not"
      note "work. Proxying on your own LAN is unaffected." ;;
    *)
      note "No consequence beyond the number — reach $what on $p." ;;
  esac
done <<< "$(echo "$EXTRA_PORTS" | sed '/^[[:space:]]*$/d')"

if [ "$PORT_SHIFTS" -gt 0 ]; then
  note ""
  note "$PORT_SHIFTS service(s) moved off their default port. Your actual"
  note "ports are written to ports.md — use that, not the defaults in the"
  note "stack guides."
fi

# ============================================================
#  Pi-hole needs port 53, and something usually has it already.
# ============================================================
if _sel_has pihole; then
  h1 "DNS (port 53)"
  if [ "${PORT_FINAL[pihole]}" != "53" ]; then
    warn "Port 53 is taken by $(who_has_port 53) — Pi-hole moved to ${PORT_FINAL[pihole]}."
    note ""
    note "Pi-hole on a non-standard port CANNOT serve your network. Clients"
    note "and routers only ask for DNS on 53. It will still start, and you"
    note "can query it for testing, but nothing will use it for real."
    note ""
    if who_has_port 53 | grep -qi 'systemd-resolve'; then
      note "The holder is systemd-resolved, the usual culprit. It reserves"
      note "53 for local lookups. Freeing it is safe and reversible — the"
      note "two commands and what they do are in stacks/infra.md."
    else
      note "Find out what holds it:  sudo ss -lntup | grep :53"
    fi
    note "Free port 53, then re-run this script."
  else
    ok "Port 53 is free — Pi-hole can serve the whole network."
  fi
fi

# ============================================================
#  Immich: where the photos live, and the ML decision.
# ============================================================
PHOTOS_DEF=""
if _sel_has immich; then
  h1 "Immich"
  PHOTOS_DEF="${PHOTOS_LOCATION:-./photos}"
  mkdir -p "$PHOTOS_DEF" 2>/dev/null || true
  PHOTOS_DEF="$(abspath "$PHOTOS_DEF")"
  kv "Photo library" "$PHOTOS_DEF"
  note "Kept separate from your media library on purpose: photos are"
  note "irreplaceable, films are not. Back this one up: backup.sh doesn't"
  note "copy it (docs/backups.md, \"Your photos\")."

  P_FREE="$(free_gb "$PHOTOS_DEF" 2>/dev/null || echo 0)"
  if [ "${P_FREE:-0}" -lt 20 ]; then
    warn "only ${P_FREE} GB free where the photos would go."
    note "A phone library is routinely 50-200 GB. Point PHOTOS_LOCATION"
    note "at a bigger disk before you start backing up a phone."
  else
    ok "${P_FREE} GB free for photos"
  fi

  echo
  if _sel_has immich-ml; then
    warn "Machine learning is ON. Read this before you start it."
    note "Face recognition and smart search run on your CPU. The first"
    note "scan of an existing library pegs every core for HOURS - days"
    note "for a large one - and everything else on the box feels slow"
    note "while it runs. On a laptop, expect heat and fan noise."
    note ""
    note "It is limited to ${IMMICH_ML_CPUS:-2.0} CPUs so the rest of your"
    note "homelab stays usable. Raise IMMICH_ML_CPUS in .env if you want"
    note "it finished sooner and do not mind the machine being busy."
    note ""
    note "Everything else - phone backup, albums, sharing, timeline,"
    note "viewing, maps - works fine without it. You can remove it later"
    note "and Immich keeps working."
  else
    ok "Machine learning is OFF (the default)."
    note "You lose: face recognition, object detection, and searching by"
    note "what is IN a photo. You keep: phone backup, albums, sharing,"
    note "the timeline, EXIF and map - everything most people use."
    note ""
    note "It is off because it is the most CPU-hungry thing in this repo;"
    note "the first scan can occupy a modest machine for hours."
    note ""
    note "ONE STEP AFTER FIRST LOGIN: Administration > Settings >"
    note "Machine Learning > untick Enabled. Until then Immich keeps"
    note "looking for a container that is not there and logs that it is"
    note "unhealthy. Harmless, but it looks like a fault."
    note ""
    note "To add ML later, re-run setup.sh and select immich-ml."
  fi
fi

# ============================================================
#  Transcoding hardware (only matters if Jellyfin was chosen)
# ============================================================
GPU_PROFILE="cpu"
if _sel_has jellyfin; then
  h1 "Transcoding hardware"
  GPU_PROFILE="$(pick_gpu_profile)"
  case "$GPU_PROFILE" in
    intel)
      ok "Intel Quick Sync (tested path)."
      note "device: $DET_INTEL_RENDER"
      note "pinned by PCI slot, so it survives reboots; exposed to"
      note "Jellyfin as /dev/dri/intel-render"
      case "$DET_GPU_VENDORS" in
        *nvidia*)
          note ""
          note "You also have an NVIDIA card. Intel is still the better"
          note "pick here: purpose-built encoder, far less setup, and it"
          note "leaves the discrete card free. Override with"
          note "GPU_PROFILE_OVERRIDE=nvidia ./setup.sh if you disagree." ;;
      esac ;;
    nvidia)
      warn "NVIDIA NVENC — this path is NOT maintainer-tested."
      note "Requires the proprietary driver (nouveau has no NVENC) and"
      note "nvidia-container-toolkit on the host. See hw/gpu-nvidia.yaml."
      note "Falls back to CPU transcoding if either is missing." ;;
    amd)
      warn "AMD VAAPI — this path is NOT maintainer-tested."
      note "device: $DET_AMD_RENDER" ;;
    cpu)
      ok "No usable GPU found — CPU transcoding."
      note "Fine for direct play and light use. See hw/cpu-only.yaml." ;;
  esac
  # Allow an explicit override.
  if [ -n "${GPU_PROFILE_OVERRIDE:-}" ]; then
    GPU_PROFILE="$GPU_PROFILE_OVERRIDE"
    warn "overridden by GPU_PROFILE_OVERRIDE -> $GPU_PROFILE"
  fi
  if [ "$GPU_PROFILE" != "cpu" ] && [ -z "${DET_RENDER_GID:-}" ]; then
    warn "Could not determine the render group id."
    note "Jellyfin may open the GPU read-only and silently use the CPU."
  fi
fi

# ============================================================
#  Paths
# ============================================================
h1 "Paths"
# Paths are stored ABSOLUTE - see abspath() in lib/detect.sh for why.
APPDATA_DEF="${APPDATA:-./appdata}"
MEDIA_DEF="${MEDIA_ROOT:-./media}"
mkdir -p "$APPDATA_DEF" "$MEDIA_DEF" 2>/dev/null || true
APPDATA_DEF="$(abspath "$APPDATA_DEF")"
MEDIA_DEF="$(abspath "$MEDIA_DEF")"
kv "Config (APPDATA)" "$APPDATA_DEF"
kv "Media (MEDIA_ROOT)" "$MEDIA_DEF"

MEDIA_FS="$(fs_of "$(dirname "$MEDIA_DEF")" 2>/dev/null || echo '?')"
APP_FS="$(fs_of "$(dirname "$APPDATA_DEF")" 2>/dev/null || echo '?')"
if [ "$MEDIA_FS" != "$APP_FS" ]; then
  note "Config and media are on different filesystems. That is fine and often"
  note "ideal — configs on SSD, media on a big HDD."
fi
note "What matters: downloads and library both live UNDER ${MEDIA_DEF},"
note "so imports are hardlinks, not copies."

# The *arrs run as PUID:PGID and refuse a root folder they cannot write.
# The error they give ("not writable by user 'abc'") names a user that
# does not exist on your host, so it is hard to act on. Catch it here.
if [ -e "$MEDIA_DEF" ]; then
  M_UID="$(stat -c %u "$MEDIA_DEF" 2>/dev/null || echo -1)"
  if [ "$M_UID" != "$DET_UID" ] && [ "$M_UID" != "-1" ]; then
    warn "$MEDIA_DEF is owned by uid $M_UID, but containers run as $DET_UID."
    note "Sonarr/Radarr will reject their root folder with a confusing"
    note "\"not writable by user 'abc'\" error. Fix it before starting:"
    note "  sudo chown -R ${DET_UID}:${DET_GID} $MEDIA_DEF"
  else
    ok "media root ownership matches PUID:PGID ($DET_UID:$DET_GID)."
  fi
fi

# ============================================================
#  Updates. Asked once: a re-run keeps the answer, --reconfigure asks
#  again. update.sh only ever offers tested releases, never main.
# ============================================================
h1 "Updates"
case "${UPDATE_MODE:-}" in
  ''|notify|auto|off) ;;
  *) warn "UPDATE_MODE=$UPDATE_MODE is not notify, auto or off: asking again."; UPDATE_MODE="" ;;
esac
if { [ -z "${UPDATE_MODE:-}" ] || [ "$RECONFIGURE" -eq 1 ]; } \
   && [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ -t 0 ]; then
  note "Every Anteiku release is brought up and tested together, on real"
  note "hardware, before it is published. A weekly check asks GitHub for"
  note "the newest one. Nothing about you is sent."
  echo
  printf '    %s1%s  notify   tell me; I run ./update.sh myself  %s(default)%s\n' "$C_B$C_INF" "$C_RST" "$C_GREY" "$C_RST"
  printf '    %s2%s  auto     install tested releases by itself, Sunday night\n' "$C_B$C_INF" "$C_RST"
  printf '    %s3%s  off      never check\n' "$C_B$C_INF" "$C_RST"
  case "${UPDATE_MODE:-notify}" in auto) d=2 ;; off) d=3 ;; *) d=1 ;; esac
  printf '  Choice %s[%s]%s: ' "$C_B" "$d" "$C_RST"
  read -r ans || ans=""
  case "${ans:-$d}" in
    1|notify) UPDATE_MODE=notify ;;
    2|auto)   UPDATE_MODE=auto ;;
    3|off)    UPDATE_MODE=off ;;
    *) warn "'$ans' is not 1, 2 or 3: keeping ${UPDATE_MODE:-notify}." ;;
  esac
fi
UPDATE_MODE="${UPDATE_MODE:-notify}"
case "$UPDATE_MODE" in
  notify) ok "notify: a message when a tested release is out; you run ./update.sh" ;;
  auto)   ok "auto: tested releases install themselves, Sundays at 04:30"
          note "Backup first. Never a release that says \"Action needed\" (you get"
          note "a message instead), never one less than 3 days old." ;;
  off)    ok "off: no checks. ./update.sh --check asks by hand." ;;
esac
if [ "$UPDATE_MODE" != off ] && ! _sel_has ntfy; then
  note "Without ntfy there is nothing to message you: ./doctor.sh shows it."
fi
[ "$UPDATE_MODE" = auto ] && [ -z "${BACKUP_DEST:-}" ] \
  && warn "auto needs BACKUP_DEST in .env: it won't update without a backup."

# ============================================================
#  Write
# ============================================================
h1 "Configuration to write"
TMP="$(mktemp)"
{
  echo "# Generated by setup.sh on $(date -I). Safe to edit by hand."
  echo
  echo "PUID=$DET_UID"
  echo "PGID=$DET_GID"
  echo "TZ=$DET_TZ"
  echo "UMASK=002"
  echo
  echo "APPDATA=$APPDATA_DEF"
  echo "MEDIA_ROOT=$MEDIA_DEF"
  echo
  if _sel_has pihole; then
    echo "# Pi-hole admin password — generated, change it if you like."
    echo "PIHOLE_PASSWORD=${PIHOLE_PASSWORD:-$(_genpw)}"
    echo "# Upstream resolvers Pi-hole forwards to when not cached/blocked."
    echo "PIHOLE_DNS_1=${PIHOLE_DNS_1:-1.1.1.1}"
    echo "PIHOLE_DNS_2=${PIHOLE_DNS_2:-9.9.9.9}"
    echo
  fi
  echo "# Where backups go. Ideally a DIFFERENT physical disk from your"
  echo "# data — see docs/backups.md. Leave empty to pass a path instead."
  if [ -n "${BACKUP_DEST:-}" ]; then
    echo "BACKUP_DEST=${BACKUP_DEST}"
  else
    echo "# BACKUP_DEST=/mnt/backup-drive   <- set this, then backups need no argument"
  fi
  echo "BACKUP_RETAIN_DAYS=30"
  echo "# Optional push notifications for scheduled backups (ntfy)."
  echo "# NTFY_URL=http://localhost:8095"
  echo "# NTFY_TOPIC=homelab"
  echo
  echo "# New tested releases: notify, auto or off. See docs/updating.md."
  echo "UPDATE_MODE=$UPDATE_MODE"
  echo
  if _sel_has ntfy; then
    echo "# ntfy. Locked down by default; run scripts/ntfy-setup.sh to"
    echo "# create the user these credentials refer to."
    echo "NTFY_URL=http://localhost:${PORT_FINAL[ntfy]:-8095}"
    echo "NTFY_TOPIC=${NTFY_TOPIC:-homelab}"
    echo "NTFY_USER=${NTFY_USER:-homelab}"
    echo "NTFY_PASS=${NTFY_PASS:-$(_genpw)}"
    echo
  fi
  if _sel_has vaultwarden; then
    echo "# Vaultwarden. DOMAIN must match the URL you really use,"
    echo "# including https:// — see stacks/extras.md."
    echo "VAULTWARDEN_DOMAIN=${VAULTWARDEN_DOMAIN:-http://localhost:${PORT_FINAL[vaultwarden]:-8222}}"
    echo "# Set to false as soon as your accounts exist."
    echo "VAULTWARDEN_SIGNUPS=${VAULTWARDEN_SIGNUPS:-true}"
    echo "VAULTWARDEN_ADMIN_TOKEN=${VAULTWARDEN_ADMIN_TOKEN:-$(_genpw)$(_genpw)}"
    echo
  fi
  if _sel_has immich; then
    echo "# Immich. PHOTOS_LOCATION is deliberately NOT under MEDIA_ROOT."
    echo "PHOTOS_LOCATION=${PHOTOS_DEF}"
    echo "IMMICH_DB_USER=immich"
    echo "IMMICH_DB_NAME=immich"
    echo "IMMICH_DB_PASSWORD=${IMMICH_DB_PASSWORD:-$(_genpw)}"
    if _sel_has immich-ml; then
      echo "IMMICH_ML_URL=http://${STACK_PREFIX}immich-machine-learning:3003"
      echo "# CPUs the ML container may use. Higher = faster scan, busier box."
      echo "IMMICH_ML_CPUS=${IMMICH_ML_CPUS:-2.0}"
    else
      echo "# Machine learning not installed. Turn it off in Immich:"
      echo "#   Administration > Settings > Machine Learning > Enabled"
      echo "# Until you do, the log says the ML server is unhealthy. It is"
      echo "# noise, not a fault."
    fi
    echo
  fi
  if _sel_has uptime-kuma; then
    echo "# Uptime Kuma admin account, created on first bootstrap run."
    echo "KUMA_USER=${KUMA_USER:-admin}"
    echo "KUMA_PASSWORD=${KUMA_PASSWORD:-$(_genpw)}"
    echo
  fi
  if _sel_has jellyfin; then
    echo "# Transcoding hardware. compose layers hw/gpu-*.yaml over the"
    echo "# base stack; change the file here to switch acceleration."
    if [ "$GPU_PROFILE" = "cpu" ]; then
      echo "COMPOSE_FILE=compose.yaml:hw/cpu-only.yaml"
    else
      echo "COMPOSE_FILE=compose.yaml:hw/gpu-${GPU_PROFILE}.yaml"
    fi
    [ -n "${DET_RENDER_GID:-}" ] && echo "RENDER_GID=${DET_RENDER_GID}"
    [ -n "${DET_INTEL_RENDER:-}" ] && echo "INTEL_RENDER_PATH=${DET_INTEL_RENDER}"
    [ -n "${DET_AMD_RENDER:-}" ]   && echo "AMD_RENDER_PATH=${DET_AMD_RENDER}"
    echo
  fi
  echo "COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-anteiku}"
  echo "DOCKER_NETWORK=${DOCKER_NETWORK:-anteiku}"
  echo "STACK_PREFIX=${STACK_PREFIX}"
  echo
  echo "# Only these services start. Add or remove names to change that."
  echo "COMPOSE_PROFILES=$(IFS=,; echo "${CHOSEN[*]}")"
  echo
  for ((i=0;i<N;i++)); do
    [ "${SEL[$i]}" -eq 1 ] || continue
    k="${CAT_KEYS[$i]}"
    [ "${CAT_PORT[$i]}" = "-" ] && continue
    echo "PORT_$(echo "$k" | tr '[:lower:]-' '[:upper:]_')=${PORT_FINAL[$k]}"
  done
  for v in "${!EXTRA_FINAL[@]}"; do echo "$v=${EXTRA_FINAL[$v]}"; done | sort
  # Version overrides (docs/updating.md): kept from the old .env like any
  # other value. Only names the stacks actually read are written.
  OVERRIDES=()
  while IFS= read -r v; do
    [ -n "${!v:-}" ] && OVERRIDES+=("$v=${!v}")
  done < <(grep -ohE '\$\{[A-Z0-9_]+_VERSION:-' stacks/*.yaml | sed -E 's/^\$\{//; s/:-$//' | sort -u)
  if [ "${#OVERRIDES[@]}" -gt 0 ]; then
    echo
    echo "# Version overrides: these run instead of the version pinned in"
    echo "# stacks/. Delete a line to go back to the pin. See docs/updating.md."
    printf '%s\n' "${OVERRIDES[@]}"
  fi
} > "$TMP"

# Never show secrets on screen: people paste this output into issues and
# chats. They are in the file itself, which is mode 600.
SECRET_RE="${SECRET_KEYS// /|}"
# Comments muted, keys coloured; both are no-ops without colour.
sed -E "s/^(${SECRET_RE})=.*/\1=${C_GREY}<hidden>${C_RST}/
        s/^(#.*)/${C_NOTE}\1${C_RST}/
        s/^([A-Z0-9_]+)=/${C_INF}\1${C_RST}=/
        s/^/  /" "$TMP"
note "Passwords are hidden here. They are in $ENV_FILE (readable only by you)."
if [ "${#OVERRIDES[@]}" -gt 0 ]; then
  warn "${#OVERRIDES[@]} service(s) held at a version override: ${OVERRIDES[*]%%=*}"
  note "They won't move with the pinned versions until you delete those lines."
fi

echo
if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s  DRY RUN — %s was not written.%s\n' "$C_WARN" "$ENV_FILE" "$C_RST"
  printf '  Selected: %s\n' "${CHOSEN[*]}"
  printf '  %sports.md was not written either.%s\n' "$C_WARN" "$C_RST"
  rm -f "$TMP"; exit 0
fi

if [ -e "$ENV_FILE" ]; then
  if [ "$RERUN" -eq 1 ]; then
    info "Updating $ENV_FILE — existing values are kept, new services added."
  else
    warn "$ENV_FILE already exists."
  fi
  if [ "$ASSUME_YES" -eq 0 ]; then
    printf '  Write it? A backup goes to %s.bak %s[y/N]%s ' "$ENV_FILE" "$C_B" "$C_RST"
    read -r yn; case "$yn" in [yY]*) ;; *) echo "  Aborted."; rm -f "$TMP"; exit 0 ;; esac
  fi
  cp "$ENV_FILE" "${ENV_FILE}.bak"
  note "backed up to ${ENV_FILE}.bak"
fi

mv "$TMP" "$ENV_FILE"; chmod 600 "$ENV_FILE"
ok "wrote $ENV_FILE"

# ============================================================
#  Pre-create data directories.
#
#  Docker creates a missing bind-mount source directory itself, as
#  ROOT. A container that runs as your user then cannot write to its
#  own config directory. Navidrome fails with "Database could not be
#  opened" and restarts forever; others fail in their own ways. The
#  cause is never obvious from the error.
#
#  Making them first, as the right user, avoids the whole class.
# ============================================================
h1 "Creating directories"
_mk() { mkdir -p "$1" 2>/dev/null && return 0; warn "could not create $1"; return 1; }

for ((i=0;i<N;i++)); do
  [ "${SEL[$i]}" -eq 1 ] || continue
  _mk "$APPDATA_DEF/${CAT_KEYS[$i]}"
done
# Services whose config lives in subdirectories.
_sel_has jellyfin && { _mk "$APPDATA_DEF/jellyfin/config"; _mk "$APPDATA_DEF/jellyfin/transcode"; }
_sel_has immich    && { _mk "$APPDATA_DEF/immich/postgres"; _mk "$PHOTOS_DEF"; }
_sel_has ntfy      && { _mk "$APPDATA_DEF/ntfy/cache"; _mk "$APPDATA_DEF/ntfy/lib"; }
_sel_has calibre-web && { _mk "$APPDATA_DEF/calibre-web/config"; _mk "$MEDIA_DEF/books/ingest"; }
_sel_has immich-ml && _mk "$APPDATA_DEF/immich/model-cache"

# Library folders the services expect to find under MEDIA_ROOT.
_sel_has sonarr        && _mk "$MEDIA_DEF/series"
_sel_has radarr        && _mk "$MEDIA_DEF/movies"
_sel_has lidarr        && _mk "$MEDIA_DEF/music"
_sel_has navidrome     && _mk "$MEDIA_DEF/music"
_sel_has lazylibrarian && _mk "$MEDIA_DEF/books"
_sel_has kavita        && _mk "$MEDIA_DEF/books"
_sel_has qbittorrent   && _mk "$MEDIA_DEF/torrents"

BAD_OWN=0
while IFS= read -r d; do
  [ -z "$d" ] && continue
  [ "$(stat -c %u "$d" 2>/dev/null)" != "$DET_UID" ] && { BAD_OWN=$((BAD_OWN+1)); note "wrong owner: $d"; }
done <<< "$(find "$APPDATA_DEF" "$MEDIA_DEF" -maxdepth 2 -type d 2>/dev/null)"

if [ "$BAD_OWN" -gt 0 ]; then
  warn "$BAD_OWN directory(ies) are not owned by uid $DET_UID."
  note "Containers running as your user will fail to write to them."
  note "Fix before starting:"
  note "  sudo chown -R ${DET_UID}:${DET_GID} $APPDATA_DEF $MEDIA_DEF"
else
  ok "all data directories exist and are owned by $DET_UID:$DET_GID"
fi

# ============================================================
#  ports.md — generated. Your actual ports, not the defaults.
# ============================================================
write_ports_md() {
  local out="ports.md" host="${HOST_ADDR:-localhost}"
  {
    echo "# Your ports"
    echo
    echo "Generated by \`./setup.sh\` on $(date -I). **Do not edit** — re-run"
    echo "setup.sh and this is rewritten. Not committed to git; it describes"
    echo "this machine only."
    echo
    echo "| Service | Open in browser | Host port | Inside Docker | Moved? |"
    echo "|---|---|---|---|---|"
    local i k hp ip moved web ports inner
    for ((i=0;i<N;i++)); do
      [ "${SEL[$i]}" -eq 1 ] || continue
      k="${CAT_KEYS[$i]}"; ip="${CAT_INTERNAL[$i]}"
      # Services with nothing to browse to (Immich ML) still get a
      # row, so the table is a complete list of what is installed.
      if [ "${CAT_PORT[$i]}" = "-" ]; then
        echo "| \`${STACK_PREFIX}${k}\` | no web UI | — | — | — |"
        continue
      fi
      hp="${PORT_FINAL[$k]}"
      if [ -n "${PORT_MOVED[$k]:-}" ]; then
        moved="yes — default ${PORT_MOVED[$k]} was taken"
      else
        moved="no"
      fi
      # Most services: one port, browsed to directly, and the container
      # answers to the service name. A few differ, and getting these
      # wrong sends people to a port that is not a web page.
      web="$hp"; ports="\`${hp}\`"; inner="\`${k}:${ip}\`"
      case "$k" in
        immich)
          inner="\`immich-server:${ip}\`" ;;
        pihole)
          web="${EXTRA_FINAL[PORT_PIHOLE_WEB]:-8053}"
          ports="\`${hp}\` DNS, \`${web}\` web"
          inner="\`pihole:80\` web, \`pihole:53\` DNS" ;;
        nginx-proxy-manager)
          web="${EXTRA_FINAL[PORT_NPM_ADMIN]:-81}"
          ports="\`${hp}\` http, \`${EXTRA_FINAL[PORT_NPM_HTTPS]:-443}\` https, \`${web}\` admin"
          inner="\`nginx-proxy-manager:81\` admin" ;;
      esac
      echo "| \`${STACK_PREFIX}${k}\` | <http://${host}:${web}> | ${ports} | ${inner} | ${moved} |"
    done
    echo
    echo "## Which address do I use where?"
    echo
    echo "**From your browser** — the \"Open in browser\" column. That is the"
    echo "host port, reachable from your LAN."
    echo
    echo "**From one container to another** — the \"Inside Docker\" column."
    echo "When you tell Sonarr where qBittorrent is, use \`qbittorrent:8080\`,"
    echo "*not* your LAN IP and *not* the host port. Containers on the same"
    echo "compose network resolve each other by service name, and that keeps"
    echo "working when your IP changes or a host port moves."
    echo
    echo "Note the two can differ: qBittorrent listens on 8080 inside its"
    echo "container no matter which host port you reach it on."
    if [ "${PORT_SHIFTS:-0}" -gt 0 ]; then
      echo
      echo "## Why some of these moved"
      echo
      echo "${PORT_SHIFTS} service(s) could not have their usual port because"
      echo "something on this machine already had it. setup.sh walked upward"
      echo "one port at a time until it found a free one. Nothing is wrong —"
      echo "just use the ports in the table above, and ignore the defaults"
      echo "printed in the stack guides and in most tutorials online."
    fi
    echo
    echo "## Changing one yourself"
    echo
    echo "Edit the matching \`PORT_*\` line in \`.env\`, then:"
    echo
    echo '```bash'
    echo "docker compose up -d        # recreates only what changed"
    echo '```'
    echo
    echo "Re-running \`./setup.sh\` regenerates this file."
  } > "$out"
  ok "wrote $out"
}
write_ports_md

h1 "Next"
step() { printf '  %s%s%s  %-20s %s%s%s%s\n' "$C_CRIM$C_B" "$1" "$C_RST" "$2" "$C_B$C_INF" "$3" "$C_RST" "${4:+  $C_GREY$4$C_RST}"; }
step 1 "Your ports"       "cat ports.md"          "bookmark this"
step 2 "Review config"    "cat $ENV_FILE"
step 3 "Check the plan"   "docker compose config"
if [ "$RERUN" -eq 1 ]; then
  step 4 "Apply it"       "docker compose up -d"  "starts what is new; running services are left alone"
else
  step 4 "Start it"       "docker compose up -d"
fi
step 5 "See what is up"   "docker compose ps"
if [ "$UPDATE_MODE" != off ] && ! { have crontab && crontab -l 2>/dev/null \
     | awk -v t="# anteiku-update $PWD" 'substr($0, length($0) - length(t) + 1) == t {f=1} END {exit !f}'; }; then
  step 6 "Weekly update check" "./update.sh --schedule" "one line in your crontab"
fi
echo
note "Per-service setup, in order, is in stacks/<stack>.md."

# Removed with --reconfigure: say exactly how to finish the job. Done by
# hand on purpose - deleting a service's data is not something a setup
# script should ever do for you.
if [ "${#REMOVED[@]}" -gt 0 ]; then
  h1 "Finishing a removal"
  warn "Deselected services are no longer managed, but are NOT deleted."
  for x in "${REMOVED[@]}"; do
    svcs="$(COMPOSE_PROFILES="$x" docker compose --env-file "$ENV_FILE" config --services 2>/dev/null | tr '\n' ' ')"
    printf '\n  %s%s%s\n' "$C_B" "$x" "$C_RST"
    printf '    stop and remove:  %sdocker compose --profile %s rm -sf %s%s\n' "$C_B" "$x" "${svcs:-$x}" "$C_RST"
    printf '    its data, kept:   %s%s/%s%s  %s(delete it yourself once you are sure)%s\n' "$C_B" "$APPDATA_DEF" "$x" "$C_RST" "$C_GREY" "$C_RST"
  done
  echo
  note "Also delete its Uptime Kuma monitor and any proxy host pointing at"
  note "it, or they will keep alerting about a service that is gone."
fi

# Gone from the catalogue: compose no longer defines the service, so
# "compose rm" can't remove it. Look the container up by this project's
# label, never by name alone: another stack may have one called the same.
if [ "${#GONE[@]}" -gt 0 ]; then
  h1 "No longer part of Anteiku"
  warn "Installed earlier, since removed from Anteiku. They are no longer"
  warn "managed, but are NOT deleted. CHANGELOG.md says why they went."
  for x in "${GONE[@]}"; do
    names="${STACK_PREFIX}$x"
    [ "$DET_DOCKER_OK" -eq 1 ] && names="$(docker ps -a --filter "label=com.docker.compose.project=$MY_PROJECT" \
      --format '{{.Names}}' 2>/dev/null | grep -Fx "${STACK_PREFIX}$x" || true)"
    printf '\n  %s%s%s\n' "$C_B" "$x" "$C_RST"
    if [ -n "$names" ]; then
      printf '    stop and remove:  %sdocker rm -f %s%s\n' "$C_B" "$names" "$C_RST"
    else
      printf '    container:        %snone left in project %s%s\n' "$C_GREY" "$MY_PROJECT" "$C_RST"
    fi
    if [ -d "$APPDATA_DEF/$x" ]; then
      printf '    its data, kept:   %s%s/%s%s  %s(delete it yourself once you are sure)%s\n' "$C_B" "$APPDATA_DEF" "$x" "$C_RST" "$C_GREY" "$C_RST"
    fi
  done
  echo
  note "Also delete its Uptime Kuma monitor and any proxy host pointing at"
  note "it, or they will keep alerting about a service that is gone."
fi

# On a re-run, only talk about what was just added.
_tell() {
  [ "$RERUN" -eq 0 ] && { _sel_has "$1"; return; }
  local x; for x in "${ADDED[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1
}

# ------------------------------------------------------------------
#  First-run expectations. These all look like faults and are not.
#  Saying so here saves people chasing a problem that does not exist.
# ------------------------------------------------------------------
[ "$RERUN" -eq 1 ] && [ "${#ADDED[@]}" -eq 0 ] && exit 0
h1 "What you will see on first start (all normal)"

printf '  %sGive it a minute.%s Containers create their databases on first\n' "$C_B$C_CRIM" "$C_RST"
printf '  boot. A service may restart once or show 502 while it does.\n\n'

if _tell sonarr || _tell radarr || _tell lidarr; then
  printf '  %s"No indexers available" — expected, not broken.%s\n' "$C_B$C_CRIM" "$C_RST"
  printf '  Sonarr and Radarr show this on their Health page as an ERROR.\n'
  printf '  It is correct: this project ships no indexers, so until you add\n'
  printf '  your own there is nothing for them to search. Everything else\n'
  printf '  can be perfectly configured and this will still be displayed.\n\n'
fi

if _tell qbittorrent; then
  printf '  %sqBittorrent generates a temporary password.%s Read it with:\n' "$C_B$C_CRIM" "$C_RST"
  printf '    %sdocker compose logs qbittorrent | grep -i password%s\n' "$C_B$C_INF" "$C_RST"
  printf '  Log in, then change it immediately — it is regenerated on every\n'
  printf '  restart until you set your own.\n\n'
  printf '  %sSet a seeding ratio limit%s (Options > BitTorrent > Seeding\n' "$C_B$C_CRIM" "$C_RST"
  printf '  Limits). Without one nothing ever retires a finished torrent and\n'
  printf '  the download directory grows until the disk is full.\n\n'
fi

if _tell seerr && [ "$DET_UID" != "1000" ]; then
  printf '  %sSeerr runs as uid 1000, not as you (uid %s).%s Give it its\n' "$C_B$C_CRIM" "$DET_UID" "$C_RST"
  printf '  config directory before starting, or it cannot write there:\n'
  printf '    %ssudo chown -R 1000:1000 %s/seerr%s\n\n' "$C_B$C_INF" "$APPDATA_DEF" "$C_RST"
fi

if [ "${DISCOVERY_MOVED:-0}" -eq 1 ]; then
  printf '  %sJellyfin auto-discovery is off.%s Its discovery port was taken,\n' "$C_B$C_CRIM" "$C_RST"
  printf '  so clients will not find the server by themselves. Enter the\n'
  printf '  address from ports.md manually in your Jellyfin app. Playback is\n'
  printf '  completely unaffected.\n\n'
fi

if _tell calibre-web; then
  printf '  %sCalibre-Web default login is admin / admin123.%s Change it on\n' "$C_B$C_CRIM" "$C_RST"
  printf '  first login. Files dropped in books/ingest are MOVED into the\n'
  printf '  library - never put your only copy there.\n\n'
fi

if _tell vaultwarden; then
  printf '  %sVaultwarden: turn signups OFF once your account exists.%s\n' "$C_B$C_CRIM" "$C_RST"
  printf '  Set VAULTWARDEN_SIGNUPS=false in .env and run compose again.\n'
  printf '  Until then anyone who reaches the page can create an account on\n'
  printf '  your password manager.\n\n'
  printf '  %sThe browser extensions and phone apps need HTTPS.%s Plain http\n' "$C_B$C_CRIM" "$C_RST"
  printf '  works in a browser tab and will NOT work in the extension. The\n'
  printf '  one-command fix is in stacks/extras.md.\n\n'
fi

if _tell ntfy; then
  printf '  %sRun ./scripts/ntfy-setup.sh%s to create the ntfy user. Nothing\n' "$C_B$C_CRIM" "$C_RST"
  printf '  can publish or subscribe until you do - it ships deny-all on\n'
  printf '  purpose.\n\n'
fi

if _tell immich && ! _sel_has immich-ml; then
  printf '  %sImmich: switch machine learning off after first login.%s\n' "$C_B$C_CRIM" "$C_RST"
  printf '  Administration > Settings > Machine Learning > untick Enabled.\n'
  printf '  Until you do, the log repeats "Machine learning server became\n'
  printf '  unhealthy" - it is looking for a container you chose not to\n'
  printf '  install. Noise, not a fault.\n\n'
fi

if _tell immich-ml; then
  printf '  %sImmich will get very busy on first scan.%s Face and smart-search\n' "$C_B$C_CRIM" "$C_RST"
  printf '  jobs start as soon as photos arrive and can run for hours. That\n'
  printf '  is expected, it is one-time, and you can pause it any time in\n'
  printf '  Administration > Jobs.\n\n'
fi

printf '  %sConnect services by container NAME, not by IP.%s When one app\n' "$C_B$C_CRIM" "$C_RST"
printf '  asks where another lives, use the "Inside Docker" column of\n'
printf '  ports.md (e.g. qbittorrent:8080) — never your LAN IP and never\n'
printf '  the host port. See ports.md for why.\n'
echo
