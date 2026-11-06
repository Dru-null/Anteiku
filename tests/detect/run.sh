#!/usr/bin/env bash
# ============================================================
#  tests/detect/run.sh — detection against mocked hardware.
#
#    bash tests/detect/run.sh            every case, one line each
#    bash tests/detect/run.sh -q         failures and the summary only
#    bash tests/detect/run.sh <case>...  just these (names from --list)
#    bash tests/detect/run.sh --list
#
#  Each case in cases.sh builds a fake machine: /etc, /proc, /sys and
#  /dev/dri under a temp dir (lib/detect.sh reads them through
#  ANTEIKU_DETECT_ROOT), and stand-ins for lspci, ss, docker and the
#  other tools it calls, first on PATH. Then the real lib/detect.sh,
#  doctor.sh and setup.sh --dry-run --yes run against it, and the case
#  checks what they made of it. A real setup.sh --yes (subject
#  setup_real, the only one that reaches its "Next" steps) runs in a
#  copy of the repo inside the case's temp dir.
#
#  Results are Mocked: what the scripts do with that input, never that
#  the hardware works. A check marked "current" records today's output
#  of a known problem; its ticket is expected to change it.
#
#  Writes nothing outside a mktemp dir. Needs bash and coreutils only.
# ============================================================
# The stand-ins below are code written into files, so their $ must stay
# literal: single quotes on purpose.
# shellcheck disable=SC2016
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
REPO="$PWD"
export LC_ALL=C

QUIET=0; LIST=0; ONLY=()
for a in "$@"; do case "$a" in
  -q) QUIET=1 ;;
  --list) LIST=1 ;;
  -h|--help) sed -n '2,/^# ===/s/^# \{0,2\}//p' "tests/detect/${0##*/}"; exit 0 ;;
  -*) echo "unknown option: $a (try --help)" >&2; exit 2 ;;
  *) ONLY+=("$a") ;;
esac; done

# shellcheck source=tests/detect/cases.sh
. tests/detect/cases.sh
CASES=()
while IFS= read -r f; do CASES+=("$f"); done \
  < <(sed -n 's/^\(case_[a-z0-9_]*\)().*/\1/p' tests/detect/cases.sh)
# Every case_ function must be found, or a typo would drop it silently.
defined="$(declare -F | awk '$3 ~ /^case_/ {print $3}' | sort)"
if [ "$defined" != "$(printf '%s\n' "${CASES[@]}" | sort)" ]; then
  echo "tests/detect: write cases as 'case_name() {' on one line; not found: $(comm -23 <(echo "$defined") <(printf '%s\n' "${CASES[@]}" | sort) | paste -sd' ')" >&2; exit 1
fi
if [ "$LIST" -eq 1 ]; then printf '%s\n' "${CASES[@]#case_}"; exit 0; fi
if [ "${#ONLY[@]}" -gt 0 ]; then
  for o in "${ONLY[@]}"; do declare -F "case_$o" >/dev/null || { echo "no such case: $o" >&2; exit 2; }; done
  CASES=("${ONLY[@]/#/case_}")
fi
# doctor.sh and setup.sh read .env from the checkout: an install there
# would change what they print.
if [ -e .env ]; then
  echo "tests/detect: this checkout has a .env; run it from a clean copy (check.sh does)" >&2; exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Tools a case controls. None of them is reachable from the real PATH:
# a case gets a stand-in, or nothing (a "missing tool" case).
# crontab, curl and git are update.sh's, not detection's: never reachable, so
# no case can touch the host's crontab or the network. The one crontab a
# case can get (crontab_lists) only answers -l, from a file.
STUBBED="lspci ss netstat nproc getent docker timedatectl uname id tailscale df crontab curl git"
REAL_ID="$(type -P id)"; RUN_UID="$("$REAL_ID" -u)"; RUN_GID="$("$REAL_ID" -g)"
BASE="$WORK/base-bin"; mkdir -p "$BASE"
declare -A seen=(); for t in $STUBBED; do seen[$t]=1; done
links=()
IFS=: read -ra dirs <<< "$PATH"
for d in "${dirs[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    n="${f##*/}"
    [ -n "${seen[$n]:-}" ] && continue
    [ -f "$f" ] && [ -x "$f" ] || continue
    seen[$n]=1; links+=("$f")
  done
done
[ "${#links[@]}" -gt 0 ] && printf '%s\0' "${links[@]}" | xargs -0 ln -s -t "$BASE"
for t in $STUBBED; do [ -e "$BASE/$t" ] && { echo "tests/detect: $t leaked into the base PATH" >&2; exit 1; }; done

# ------------------------------------------------------------ fixtures
# A case calls these first; the first check runs the scripts, and the
# machine can't change after that.
FX=""; R=""; T=""; RAN=""

_frozen() { [ -z "$RAN" ] || _fail "fixture '$1' after a check ran: put fixture lines first"; }
_stub() { # name: body on stdin, as a bash script
  { echo '#!/usr/bin/env bash'; echo "T='$T'"
    # A call the stand-in doesn't know fails the case: scripts hide
    # these behind 2>/dev/null, and a silent stub hides a real path.
    echo 'odd() { echo "${0##*/} $*" >> "$T/odd"; exit 1; }'; cat; } > "$FX/bin/$1"; chmod 755 "$FX/bin/$1"
}

from()      { WHERE="$1"; }                       # where the data came from
os_release(){ _frozen os_release; mkdir -p "$R/etc"; cat > "$R/etc/os-release"; }
no_os_release() { _frozen no_os_release; rm -f "$R/etc/os-release"; }
arch()      { _frozen arch; echo "$1" > "$T/arch"; }
kernel()    { _frozen kernel; echo "$1" > "$T/kernel"; }
cores()     { _frozen cores; echo "$1" > "$T/cores"; }
cpuinfo()   { _frozen cpuinfo; mkdir -p "$R/proc"; cat > "$R/proc/cpuinfo"; }
cpu_model() { # "model name" [count]: an x86 /proc/cpuinfo
  local i; _frozen cpu_model; mkdir -p "$R/proc"
  for ((i=0; i<${2:-4}; i++)); do
    printf 'processor\t: %s\nvendor_id\t: x\nmodel name\t: %s\nflags\t\t: fpu sse2\n\n' "$i" "$1"
  done > "$R/proc/cpuinfo"
}
mem_kb()    { # MemTotal [SwapTotal], in kB as the kernel prints them
  _frozen mem_kb; mkdir -p "$R/proc"
  printf 'MemTotal:       %8s kB\nMemFree:          812344 kB\nMemAvailable:    2048000 kB\nSwapTotal:      %8s kB\nSwapFree:       %8s kB\n' \
    "$1" "${2:-0}" "${2:-0}" > "$R/proc/meminfo"
}
tz_ctl()       { _frozen tz_ctl; echo "$1" > "$T/tz"; rm -f "$T/tz.fail"; }
tz_ctl_fails() { _frozen tz_ctl_fails; rm -f "$T/tz"; : > "$T/tz.fail"; }   # installed, no systemd
tz_file()      { _frozen tz_file; mkdir -p "$R/etc"; echo "$1" > "$R/etc/timezone"; }
tz_link()      { _frozen tz_link; mkdir -p "$R/etc"; ln -s "$1" "$R/etc/localtime"; }   # target as the distro writes it
prev_env()     { _frozen prev_env; cat > "$FX/prev.env"; }   # an earlier run's .env: setup.sh --env-file
refuses()      { _frozen refuses; : > "$T/setup.refuses"; }  # setup.sh must stop with exit 1, not 0
installed()    { # [UPDATE_MODE]: doctor and update.sh run from an install in the case's temp dir
  _frozen installed; mkdir -p "$FX/install"
  tar -C "$REPO" --exclude=./.git --exclude=./.env -cf - . | tar -C "$FX/install" -xf - \
    || _fail "installed: copy failed"
  printf 'UPDATE_MODE=%s\n' "${1:-notify}" > "$FX/install/.env"
}
crontab_lists(){ # stdin: what 'crontab -l' prints; empty = cron installed, no crontab yet
  _frozen crontab_lists; cat > "$T/crontab"
  _stub crontab <<'EOF'
[ "$*" = -l ] || odd "$@"   # never writes: -l only
[ -s "$T/crontab" ] || { echo "no crontab for you" >&2; exit 1; }
cat "$T/crontab"
EOF
}
shell_env()    { _frozen shell_env; echo "$1" >> "$T/shell.env"; }   # KEY=value exported to doctor.sh
setup_env()    { _frozen setup_env; echo "$1" >> "$T/setup.env"; }   # KEY=value for setup.sh and setup_real, after their defaults
# locked_dir <path>: an empty folder nobody may write to (mode 555). The
# case's paths are real folders: -w, mkdir and stat see the real thing.
locked_dir()   {
  _frozen locked_dir
  if ! { mkdir -p "$1" && chmod 555 "$1"; }; then _fail "locked_dir: could not make $1"; return 0; fi
  [ -w "$1" ] && _fail "locked_dir: $1 is still writable (running as root?)"; return 0
}
install_env()  { # stdin: more .env lines for the install (after 'installed')
  _frozen install_env; [ -d "$FX/install" ] || { _fail "install_env: needs the 'installed' fixture"; return 0; }
  cat >> "$FX/install/.env"
}
pci()       { # slot class vendor device [driver]: a PCI device in sysfs
  _frozen pci; local d="$R/sys/bus/pci/devices/0000:$1"
  mkdir -p "$d"; echo "$2" > "$d/class"; echo "0x${3}" > "$d/vendor"; echo "0x${4}" > "$d/device"
  if [ -n "${5:-}" ]; then mkdir -p "$R/sys/bus/pci/drivers/$5"; ln -s "../../drivers/$5" "$d/driver"; fi
}
gpu()       { # "lspci line" vendor:device [driver]: the line, and the card in sysfs
  _frozen gpu; [ -n "${2:-}" ] || { _fail "gpu: no vendor:device for [$1]"; return 0; }
  echo "$1" >> "$T/lspci"
  local class
  case "$1" in
    *"VGA compatible controller"*) class=0x030000 ;;
    *"3D controller"*)             class=0x030200 ;;
    *"Display controller"*)        class=0x038000 ;;
    *) _fail "gpu: no display class in [$1]"; return 0 ;;
  esac
  pci "${1%% *}" "$class" "${2%%:*}" "${2#*:}" "${3:-}"
}
override()  { _frozen override; echo "$1" > "$T/override"; }   # GPU_PROFILE_OVERRIDE for setup.sh
render()    { # renderDNNN driver [pci-id]: a node, its driver in sysfs, its by-path link
  _frozen render; local node="$1" drv="$2" pci="${3:-}"
  mkdir -p "$R/dev/dri" "$R/sys/bus/pci/drivers/$drv" "$R/sys/class/drm/$node/device"
  : > "$R/dev/dri/$node"
  ln -s "../../../../bus/pci/drivers/$drv" "$R/sys/class/drm/$node/device/driver"
  if [ -n "$pci" ]; then
    mkdir -p "$R/dev/dri/by-path"; ln -s "../$node" "$R/dev/dri/by-path/pci-$pci-render"
  fi
}
group()     { _frozen group; sed -i "/^$1:/d" "$T/groups"; [ -n "${2:-}" ] && echo "$1:x:$2:" >> "$T/groups"; return 0; }
user_groups(){ _frozen user_groups; echo "$1" > "$T/user-groups"; }
user_ids()  { _frozen user_ids; echo "$1" > "$T/uid"; echo "$2" > "$T/gid"; }   # id -u, id -g
docker_is() { # absent | down | up ; plus: rootless, nvidia-runtime, no-compose
  _frozen docker_is; local w
  for w in "$@"; do case "$w" in
    absent) rm -f "$FX/bin/docker" ;;
    down) rm -f "$T/docker.up" ;;
    up) : > "$T/docker.up" ;;
    rootless) : > "$T/docker.rootless" ;;
    nvidia-runtime) : > "$T/docker.nvidia" ;;
    no-compose) rm -f "$T/compose" ;;
  esac; done
}
container() { # name port [compose project] [compose service]: a running container
  _frozen container
  printf '%s|%s|%s|0.0.0.0:%s->%s/tcp, [::]:%s->%s/tcp\n' "$1" "${3:-}" "${4:-}" "$2" "$2" "$2" "$2" >> "$T/docker.ps"
}
listen()    { # port [process name, as root-free ss -p would show it]
  _frozen listen; printf 'tcp   LISTEN 0      4096         0.0.0.0:%s      0.0.0.0:*%s\n' "$1" \
    "${2:+    users:((\"$2\",pid=4242,fd=7))}" >> "$T/listen"
}
tailscale_is() { # up <ip> <name> | down
  _frozen tailscale_is; _stub tailscale <<'EOF'
case "$1 ${2:-}" in
  "ip -4") [ -f "$T/ts.ip" ] && cat "$T/ts.ip" || exit 1 ;;
  "status --json") [ -f "$T/ts.name" ] && printf '{"Self":{"DNSName":"%s."}}\n' "$(cat "$T/ts.name")" || exit 1 ;;
  *) odd "$@" ;;
esac
EOF
  if [ "$1" = up ]; then echo "$2" > "$T/ts.ip"; echo "$3" > "$T/ts.name"; fi
}
# Free space in decimal GB, as the README states sizes; df reports 1K
# blocks, so a whole GB is 976563 of them (rounded up, never under).
disk()      { _frozen disk; _disk '*' "$((${1} * 976563))" "${2:-ext4}" "${3:-/}"; }  # freeGB [type] [mount]: every path
disk_kb()   { _frozen disk_kb; _disk '*' "$1" "${2:-ext4}" "${3:-/}"; }               # free 1K blocks [type] [mount]
disk_at()   { _frozen disk_at; _disk "$1" "$(($2 * 976563))" "${3:-ext4}" "${4:-/}"; } # path freeGB [type] [mount]: that path and below
no_path()   { _frozen no_path; _disk "$1" - - -; }                                     # df: no such file or directory
_disk()     { sed -i "\\|^$1 |d" "$T/disks" 2>/dev/null; printf '%s %s %s %s\n' "$@" >> "$T/disks"; }
docker_store(){ # containerd (Docker 29's default) | classic; [Docker Root Dir]
  _frozen docker_store; echo "$1" > "$T/docker.store"; [ -n "${2:-}" ] && echo "$2" > "$T/docker.root"; return 0; }
containerd_conf(){ _frozen containerd_conf; mkdir -p "$R/etc/containerd"; cat > "$R/etc/containerd/config.toml"; }
no_tool()   { _frozen no_tool; local t; for t in "$@"; do rm -f "$FX/bin/$t"; done; }

# The machine every case starts from: Ubuntu 24.04 on x86_64, 16 GB,
# no GPU, Docker running (default image store, no containerd config),
# nothing listening, 200 GB free on ext4 for every path.
defaults() {
  mkdir -p "$R/etc" "$R/proc" "$T" "$FX/bin" "$FX/home"
  os_release <<'EOF'
PRETTY_NAME="Ubuntu 24.04.3 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION="24.04.3 LTS (Noble Numbat)"
ID=ubuntu
ID_LIKE=debian
EOF
  arch x86_64; kernel 6.8.0-87-generic; cores 6
  cpu_model "Intel(R) Core(TM) i5-8500T CPU @ 2.10GHz" 6
  mem_kb 16247300 4194300
  tz_ctl America/Toronto
  printf 'render:x:992:\nvideo:x:44:\n' > "$T/groups"
  user_groups "you adm docker"
  : > "$T/docker.up"; echo "2.40.3" > "$T/compose"
  docker_store containerd /var/lib/docker
  disk 200
  # What lspci's stand-in lists besides GPUs. Intel's vendor id on a host
  # bridge: only display devices (class 0x03xxxx) may count as a GPU.
  pci 00:00.0 0x060000 8086 3ec4; pci 00:14.0 0x0c0330 8086 a36d; pci 02:00.0 0x010802 144d a808 nvme
  _stub uname <<'EOF'
case "${1:-}" in -r) cat "$T/kernel" ;; -m) cat "$T/arch" ;; *) odd "$@" ;; esac
EOF
  _stub nproc <<< 'cat "$T/cores"'
  _stub timedatectl <<'EOF'
[ "$*" = "show -p Timezone --value" ] || odd "$@"
[ -f "$T/tz" ] && { cat "$T/tz"; exit 0; }
exit 1
EOF
  _stub getent <<'EOF'
[ "${1:-}" = group ] || odd "$@"
grep "^${2:-}:" "$T/groups" && exit 0
exit 2
EOF
  _stub id <<EOF
[ "\$*" = "-nG" ] && { cat "\$T/user-groups"; exit 0; }
case "\$*" in
  -u) [ -f "\$T/uid" ] && { cat "\$T/uid"; exit 0; } ;;
  -g) [ -f "\$T/gid" ] && { cat "\$T/gid"; exit 0; } ;;
  *) odd "\$@" ;;
esac
exec "$REAL_ID" "\$@"
EOF
  _stub lspci <<'EOF'
echo "00:00.0 Host bridge: Example Corp. Host Bridge (rev 07)"
echo "00:14.0 USB controller: Example Corp. USB 3.1 xHCI Host Controller (rev 10)"
[ -f "$T/lspci" ] && cat "$T/lspci"
echo "02:00.0 Non-Volatile memory controller: Example Corp. NVMe SSD Controller"
EOF
  _stub ss <<'EOF'
case "${1:-}" in
  -lntuH) [ -f "$T/listen" ] && sed 's/ *users:.*//' "$T/listen" ;;
  -lntupH) [ -f "$T/listen" ] && cat "$T/listen" ;;
  *) odd "$@" ;;
esac
exit 0
EOF
  _stub netstat <<'EOF'
[ "${1:-}" = -lntu ] || odd "$@"
echo "Active Internet connections (only servers)"
echo "Proto Recv-Q Send-Q Local Address           Foreign Address         State"
[ -f "$T/listen" ] && awk '{printf "tcp        0      0 %-23s %-23s LISTEN\n", $5, $6}' "$T/listen"
exit 0
EOF
  _stub docker <<'EOF'
case "${1:-}" in
  --version) echo "Docker version 29.0.1, build eedd969" ;;
  info) [ -f "$T/docker.up" ] || { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
        echo "Server Version: 29.0.1"
        if [ -f "$T/docker.nvidia" ]; then echo " Runtimes: io.containerd.runc.v2 nvidia runc"
        else echo " Runtimes: io.containerd.runc.v2 runc"; fi
        # Lines as Docker 29 prints them; the classic store has no driver-type.
        if [ "$(cat "$T/docker.store")" = classic ]; then echo " Storage Driver: overlay2"; echo "  Backing Filesystem: extfs"
        else echo " Storage Driver: overlayfs"; echo "  driver-type: io.containerd.snapshotter.v1"; fi
        echo " Default Runtime: runc"; echo " Security Options:"; echo "  seccomp"
        [ -f "$T/docker.rootless" ] && echo "  rootless"
        echo " Docker Root Dir: $(cat "$T/docker.root")"; exit 0 ;;
  compose) [ "${2:-}" = version ] && [ -f "$T/compose" ] && { cat "$T/compose"; exit 0; }
           [ "${2:-}" = version ] || odd "$@"
           echo "docker: unknown command: docker compose" >&2; exit 1 ;;
  ps) [ -f "$T/docker.up" ] || exit 1
      shift; proj="*"; svc="*"; fmt="{{.ID}}"
      while [ $# -gt 0 ]; do case "$1" in
        --filter) case "$2" in
          label=com.docker.compose.project=*) proj="${2#label=com.docker.compose.project=}" ;;
          label=com.docker.compose.service=*) svc="${2#label=com.docker.compose.service=}" ;;
          *) odd ps "$@" ;; esac; shift 2 ;;
        --format) fmt="$2"; shift 2 ;;
        -q) fmt="{{.ID}}"; shift ;;
        -a) shift ;;
        *) odd ps "$@" ;;
      esac; done
      [ -f "$T/docker.ps" ] || exit 0
      while IFS='|' read -r name p s ports; do
        # shellcheck disable=SC2053
        [[ $p == $proj && $s == $svc ]] || continue
        case "$fmt" in
          '{{.ID}}') echo "0123456789ab" ;;
          '{{.Label "com.docker.compose.service"}} {{.Ports}}') echo "$s $ports" ;;
          '{{.Names}} {{.Ports}}') echo "$name $ports" ;;
          '{{.Names}}|{{.Label "com.docker.compose.project"}}') echo "$name|$p" ;;
          *) odd ps --format "$fmt" ;;
        esac
      done < "$T/docker.ps"; exit 0 ;;
  network) [ "${2:-}" = inspect ] || odd "$@"; exit 1 ;;   # no such network
  *) odd "$@" ;;
esac
EOF
  # One path per call, as the scripts use it: the longest disk_at prefix
  # wins, else the '*' line. Each mount is its own device.
  _stub df <<'EOF'
[ $# -ge 2 ] || odd "$@"
p="${!#}"; best=""; kb=""
while read -r at k ty mn; do
  if [ "$at" = '*' ]; then [ -z "$best" ] && { kb=$k; type=$ty; mnt=$mn; }
  elif [ "$p" = "$at" ] || [ "${p#"$at"/}" != "$p" ]; then
    [ "${#at}" -gt "${#best}" ] && { best=$at; kb=$k; type=$ty; mnt=$mn; }
  fi
done < "$T/disks"
[ "$kb" = - ] && { echo "df: $p: No such file or directory" >&2; exit 1; }
dev="/dev/fx$(printf '%s' "$mnt" | cksum | cut -c1-4)"
case "${*:1:$#-1}" in
  # GNU df rounds up to whole blocks; pre-T-069 doctor asked for GiB.
  "-P --block-size=1G") printf 'Filesystem     1073741824-blocks  Used Available Capacity Mounted on\n%s %17s %5s %9s %8s %s\n' "$dev" 0 0 $(( (kb + 1048575) / 1048576 )) "67%" "$mnt" ;;
  "-PT") printf 'Filesystem     Type 1024-blocks      Used Available Capacity Mounted on\n%s       %-4s %11s %9s %9s %8s %s\n' "$dev" "$type" $((kb * 3)) $((kb * 2)) "$kb" "67%" "$mnt" ;;
  "-P") printf 'Filesystem     1024-blocks      Used Available Capacity Mounted on\n%s   %11s %9s %9s %8s %s\n' "$dev" $((kb * 3)) $((kb * 2)) "$kb" "67%" "$mnt" ;;
  *) odd "$@" ;;
esac
EOF
}

# ------------------------------------------------------------ running
_env() {
  env -i "PATH=$FX/bin:$BASE" "HOME=$FX/home" LC_ALL=C NO_COLOR=1 \
    "ANTEIKU_DETECT_ROOT=$R" "$@"
}
# Everything lib/detect.sh gives the scripts, one KEY=value per line.
PROBE='. lib/detect.sh
detect_os; detect_cpu; detect_mem; detect_gpu; detect_render; detect_docker; detect_tailscale
for v in DET_DISTRO DET_DISTRO_VER DET_KERNEL DET_ARCH DET_TZ DET_UID DET_GID DET_CPU DET_CORES \
  DET_MEM_MIB DET_MEM_GIB DET_SWAP_MIB DET_SWAP_GIB DET_GPU_VENDORS DET_GPU_OTHER DET_NVIDIA_DRIVER DET_RENDER_GID DET_INTEL_RENDER DET_AMD_RENDER \
  DET_DOCKER_VER DET_DOCKER_NVIDIA DET_COMPOSE_VER DET_DOCKER_OK DET_DOCKER_ROOTLESS DET_IN_DOCKER_GROUP \
  DET_DOCKER_ROOT DET_DOCKER_STORE \
  DET_TS_INSTALLED DET_TS_UP DET_TS_IP DET_TS_NAME; do printf "%s=%s\n" "$v" "${!v}"; done
printf "DET_GPUS=%s\n" "$(printf "%s" "$DET_GPUS" | paste -sd ";")"
printf "DET_RENDER_NODES=%s\n" "$(printf "%s" "$DET_RENDER_NODES" | paste -sd ";")"
printf "pick=%s\n" "$(pick_gpu_profile)"
for p in 53 5055 5299 6767 7878 8181 8686 8989 9696; do
  port_in_use "$p"
  case $? in
    0) printf "port.%s=used by %s\n" "$p" "$(who_has_port "$p")" ;;
    1) printf "port.%s=free\n" "$p" ;;
    *) printf "port.%s=unchecked\n" "$p" ;;
  esac
done
printf "DET_TZ_FROM=%s\nfamily=%s\nhint=%s\ncron_hint=%s\n" "$DET_TZ_FROM" "$(pkg_family)" "$(install_hint ss curl)" "$(cron_hint)"
printf "fs_of=%s\nfstype_of=%s\nfree_gb=%s\n" "$(fs_of .)" "$(fstype_of .)" "$(free_gb .)"
detect_image_store; printf "image_store=%s\nimage_store_why=%s\n" "$DET_IMAGE_STORE" "$DET_IMAGE_STORE_WHY"'

_run() { # probe | doctor | setup | setup_real | update_check | update | update_schedule: once per case, on first use
  case " $RAN " in *" $1 "*) return 0 ;; esac
  local rc OVR="" ENVF="" DIR="$REPO" SHENV=() SUENV=()
  [ -f "$T/override" ] && OVR="$(cat "$T/override")"
  [ -f "$T/shell.env" ] && mapfile -t SHENV < "$T/shell.env"
  [ -f "$T/setup.env" ] && mapfile -t SUENV < "$T/setup.env"
  [ -f "$FX/prev.env" ] && ENVF="--env-file=$FX/prev.env"
  [ -d "$FX/install" ] && DIR="$FX/install"   # doctor and update.sh only
  case "$1" in
    probe)  (cd "$REPO" && _env bash -c "$PROBE") > "$FX/probe" 2>&1; rc=$? ;;
    doctor) (cd "$DIR" && _env "${SHENV[@]}" bash doctor.sh) < /dev/null > "$FX/doctor" 2>&1; rc=$? ;;
    setup)  (cd "$REPO" && _env STACK_PREFIX=fx- COMPOSE_PROJECT_NAME=anteiku-fx DOCKER_NETWORK=anteiku-fx \
               APPDATA=./appdata MEDIA_ROOT=./media PHOTOS_LOCATION=./photos "${SUENV[@]}" \
               ${OVR:+"GPU_PROFILE_OVERRIDE=$OVR"} \
               bash setup.sh --dry-run --yes ${ENVF:+"$ENVF"}) < /dev/null > "$FX/setup" 2>&1; rc=$? ;;
    # A real --yes run in its own copy: .env, ports.md and the data folders
    # land there, mktemp under the case's tmp/. prev_env is that copy's
    # .env, as a user re-runs. The checkout must not change.
    setup_real)
      mkdir -p "$FX/real" "$FX/tmp"
      tar -C "$REPO" --exclude=./.git --exclude=./.env -cf - . | tar -C "$FX/real" -xf - \
        || _fail "setup_real: copy failed"
      [ -f "$FX/prev.env" ] && cp "$FX/prev.env" "$FX/real/.env"
      local before; before="$(ls -A "$REPO")"
      (cd "$FX/real" && _env TMPDIR="$FX/tmp" STACK_PREFIX=fx- COMPOSE_PROJECT_NAME=anteiku-fx DOCKER_NETWORK=anteiku-fx \
         APPDATA=./appdata MEDIA_ROOT=./media PHOTOS_LOCATION=./photos "${SUENV[@]}" \
         ${OVR:+"GPU_PROFILE_OVERRIDE=$OVR"} \
         bash setup.sh --yes) < /dev/null > "$FX/setup_real" 2>&1; rc=$?
      _check "setup_real leaves the checkout alone" "$before" "$(ls -A "$REPO")"
      _check "setup_real leaves nothing in tmp/" "" "$(ls -A "$FX/tmp")"
      awk '/^-- / {f = /^-- Next /} f' "$FX/setup_real" > "$FX/next"   # that section only
      [ -s "$FX/next" ] || [ -f "$T/setup.refuses" ] || _fail "setup_real never reached its Next steps" ;;
    next) _run setup_real; RAN="$RAN next"; return 0 ;;   # setup_real's "Next" section
    update_check|update|update_schedule)
      [ -d "$FX/install" ] || { _fail "$1: needs the 'installed' fixture"; RAN="$RAN $1"; return 0; }
      local arg; case "$1" in update_check) arg=--check ;; update) arg="" ;; update_schedule) arg=--schedule ;; esac
      (cd "$FX/install" && _env bash update.sh ${arg:+"$arg"}) < /dev/null > "$FX/$1" 2>&1
      echo "$?" > "$FX/$1.rc"; RAN="$RAN $1"; return 0 ;;
  esac
  RAN="$RAN $1"
  local cur="$CUR" want=0; CUR=""
  # Both scripts must finish on any machine: doctor always exits 0, and
  # setup.sh (dry or real) stops early only on its own refusals ('refuses': exit 1).
  case "$1" in setup|setup_real) [ -f "$T/setup.refuses" ] && want=1 ;; esac
  _check "$1 exits $want" "$want" "$rc"
  [ "$rc" -eq "$want" ] || tail -n 8 "$FX/$1" | sed 's/^/        | /' >> "$FX/report"
  CUR="$cur"
}

N_CHK=0; N_FAIL=0; CUR=""
_fail() { N_FAIL=$((N_FAIL+1)); printf '      FAIL %s\n' "$1" >> "$FX/report"; }
_check() { # label expected got
  N_CHK=$((N_CHK+1))
  if [ "$2" = "$3" ]; then
    [ -n "$CUR" ] && printf '      current, expected to change in %s: %s -> %s\n' "$CUR" "$1" "$3" >> "$FX/report"
  else
    _fail "$1: expected [$2], got [$3]"
  fi
}
current() { CUR="$1"; printf '      %s (%s)\n' "$2" "$1" >> "$FX/report"; }   # to the end of the case

# is <DET_X|pick|port.N|fs_of|fstype_of|free_gb|image_store|image_store_why> <value>
is() { _run probe; _check "$1" "$2" "$(sed -n "s/^$1=//p" "$FX/probe" | head -n 1)"; }
# env_is KEY value / env_absent KEY: the .env setup.sh --dry-run would write
_envline() { sed -n '/Configuration to write/,$p' "$FX/setup" | sed -n "s/^  $1=//p" | head -n 1; }
env_is()     { _run setup; _check ".env $1" "$2" "$(_envline "$1")"; }
env_absent() { _run setup; _check ".env $1" "(absent)" "$(sed -n '/Configuration to write/,$p' "$FX/setup" | grep -q "^  $1=" && echo present || echo '(absent)')"; }
# Lines as lib/detect.sh prints them (LC_ALL=C: ASCII symbols, no colour).
_line() { case "$1" in
  ok) printf '  +  %s' "$2" ;; warn) printf '  !  %s' "$2" ;; err) printf '  x  %s' "$2" ;; info) printf '  i  %s' "$2" ;;
  note) printf '     %s' "$2" ;; kv) printf '  %-20s %s' "$2" "$3" ;;
  step) printf '  %s  %-20s %s%s' "$2" "$3" "$4" "${5:+  $5}" ;; esac; }   # step N label command [hint]
_has() { # subject line
  _run "$1"; N_CHK=$((N_CHK+1))
  if grep -qxF -- "$2" "$FX/$1"; then
    [ -n "$CUR" ] && printf '      current, expected to change in %s: %s says "%s"\n' "$CUR" "$1" "${2#"${2%%[! ]*}"}" >> "$FX/report"
  else _fail "$1 has no line [$2]"; fi
}
_lacks() { _run "$1"; N_CHK=$((N_CHK+1)); grep -qF -- "$2" "$FX/$1" && _fail "$1 should not say [$2]"; return 0; }
doctor()      { _has doctor "$(_line "$@")"; }    # doctor ok|warn|err|note "text"; doctor kv Key "value"
doctor_lacks(){ _lacks doctor "$1"; }
setup()       { _has setup "$(_line "$@")"; }
setup_lacks() { _lacks setup "$1"; }
# setup.sh --yes for real (setup_real), its "Next" section only: next ok|warn|note|step …
real()        { _has setup_real "$(_line "$@")"; }   # setup_real's whole output: real warn "…"
real_lacks()  { _lacks setup_real "$1"; }
next()        { _has next "$(_line "$@")"; }
next_lacks()  { _lacks next "$1"; }
# update.sh in the install: update_check (--check), update, update_schedule (--schedule)
upd()         { local s="$1"; shift; _has "$s" "$(_line "$@")"; }   # upd update_check err "..."
upd_lacks()   { _lacks "$1" "$2"; }
exits()       { _run "$1"; _check "$1 exit code" "$2" "$(cat "$FX/$1.rc" 2>/dev/null)"; }

# ------------------------------------------------------------ cases
# Each case runs in its own subshell, a few at a time; results are
# printed afterwards in file order.
run_case() {
  local fn="$1"
  FX="$WORK/fx/${fn#case_}"; R="$FX/root"; T="$FX/tool"; RAN=""; WHERE="written"
  N_CHK=0; N_FAIL=0; CUR=""
  mkdir -p "$FX"; : > "$FX/report"
  defaults
  "$fn"
  [ "$N_CHK" -eq 0 ] && _fail "the case checked nothing"
  if [ -f "$T/odd" ]; then
    while IFS= read -r l; do _fail "a stand-in got a call it doesn't know: $l"; done < <(sort -u "$T/odd")
  fi
  printf '%s|%s|%s\n' "$N_CHK" "$N_FAIL" "$WHERE" > "$FX/result"
}
JOBS="${DETECT_JOBS:-4}"; running=0
for fn in "${CASES[@]}"; do
  ( run_case "$fn" ) &
  running=$((running+1))
  [ "$running" -ge "$JOBS" ] && { wait -n; running=$((running-1)); }
done
wait

TOTAL_CHK=0; TOTAL_FAIL=0; declare -A CURRENT=()
for fn in "${CASES[@]}"; do
  FX="$WORK/fx/${fn#case_}"
  if ! IFS='|' read -r n f where < "$FX/result" 2>/dev/null; then
    n=0; f=1; where="?"; echo "      FAIL the case did not finish" >> "$FX/report"
  fi
  TOTAL_CHK=$((TOTAL_CHK+n)); TOTAL_FAIL=$((TOTAL_FAIL+f))
  while IFS= read -r t; do CURRENT[$t]=1; done < <(grep -oE 'in T-[0-9]+' "$FX/report" | cut -c4-)
  if [ "$f" -gt 0 ]; then
    printf 'FAIL %-34s %s, %s of %s checks failed\n' "${fn#case_}" "$where" "$f" "$n"
    grep '^      FAIL\|^        |' "$FX/report"
  elif [ "$QUIET" -eq 0 ]; then
    printf 'ok   %-34s %s, %s checks\n' "${fn#case_}" "$where" "$n"
    grep -v '^      FAIL' "$FX/report"
  fi
done

cur="$(printf '%s\n' "${!CURRENT[@]}" | sort | paste -sd' ')"
printf '%s cases, %s checks, %s failed (Mocked)%s\n' "${#CASES[@]}" "$TOTAL_CHK" "$TOTAL_FAIL" \
  "${cur:+; current output that is expected to change: $cur}"
[ "$TOTAL_FAIL" -eq 0 ]
