#!/usr/bin/env python3
"""
Build the monitor plan from what is installed, and optionally apply it.

Split out from the shell script because generating JSON and talking to a
socket.io API are both things Python does without fighting quoting rules.

  plan   : read .env, print the plan as JSON
  render : pretty-print a plan for a human to read
"""
import json, os, sys

# service | group | type | target(container:port) | health path | extra accepted code
CATALOGUE = """
pihole|Critical|http|pihole:80|/admin/login|
nginx-proxy-manager|Critical|http|nginx-proxy-manager:81|/|
vaultwarden|Critical|http|vaultwarden:80|/alive|
jellyfin|Media|http|jellyfin:8096|/health|
navidrome|Media|http|navidrome:4533|/ping|
kavita|Media|http|kavita:5000|/|
seerr|Media|http|seerr:5055|/api/v1/status|
calibre-web|Media|http|calibre-web:8083|/|
immich|Media|http|immich-server:2283|/api/server/ping|
immich-ml|Media|http|immich-machine-learning:3003|/ping|
prowlarr|Acquisition|http|prowlarr:9696|/|
sonarr|Acquisition|http|sonarr:8989|/|
radarr|Acquisition|http|radarr:7878|/|
lidarr|Acquisition|http|lidarr:8686|/|
lazylibrarian|Acquisition|http|lazylibrarian:5299|/|
bazarr|Acquisition|http|bazarr:6767|/|
qbittorrent|Acquisition|http|qbittorrent:8080|/|401
byparr|Acquisition|http|byparr:8191|/|
dozzle|Infra|http|dozzle:8080|/|
ntfy|Infra|http|ntfy:80|/v1/health|
diun|Containers|docker|diun||
"""

GROUP_ORDER = ["Critical", "Media", "Acquisition", "Infra", "Containers", "External"]


def build_plan(profiles, prefix):
    chosen = {p.strip() for p in profiles.split(",") if p.strip()}
    rows = []
    for line in CATALOGUE.strip().splitlines():
        if not line.strip():
            continue
        svc, grp, typ, tgt, path, extra = (line.split("|") + [""] * 6)[:6]
        if svc not in chosen:
            continue
        # Any HTTP answer proves the service is alive. A 401 from a login
        # page means "up and asking who you are", not "down" - so accept
        # redirects, and auth codes where that service returns one.
        codes = ["200-299", "300-399"] + ([extra] if extra else [])
        rows.append({"service": svc, "group": grp, "type": typ, "target": tgt,
                     "path": path, "codes": codes, "container": prefix + svc})
    # Always included: tells you whether it is your stack or your line.
    rows.append({"service": "__internet__", "group": "External", "type": "ping",
                 "target": "1.1.1.1", "path": "", "codes": [], "container": ""})
    rows.sort(key=lambda r: (GROUP_ORDER.index(r["group"])
                             if r["group"] in GROUP_ORDER else 99, r["service"]))
    return rows


def render(rows):
    groups = {}
    for r in rows:
        groups.setdefault(r["group"], []).append(r)
    out = []
    for g in GROUP_ORDER:
        if g not in groups:
            continue
        out.append("  " + g)
        for r in groups[g]:
            if r["type"] == "ping":
                tgt = "ping " + r["target"]
            elif r["type"] == "docker":
                tgt = "docker container " + r["container"]
            else:
                tgt = "http://" + r["target"] + r["path"]
            name = "Internet" if r["service"] == "__internet__" else r["service"]
            out.append("      %-22s %s" % (name, tgt))
    out.append("")
    out.append("  %d monitors across %d groups" % (len(rows), len(groups)))
    return "\n".join(out)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "plan"
    if cmd == "plan":
        print(json.dumps(build_plan(os.environ.get("COMPOSE_PROFILES", ""),
                                    os.environ.get("STACK_PREFIX", ""))))
    elif cmd == "render":
        print(render(json.load(sys.stdin)))
    else:
        sys.exit("usage: kuma-monitors.py plan|render")
