#!/usr/bin/env python3
"""
Apply a monitor plan (JSON on stdin) to Uptime Kuma.

Runs inside a throwaway container on the compose network - Kuma has no
REST API, only socket.io, so this needs a client library we do not want
installed on the host.
"""
import json, os, sys
from uptime_kuma_api import UptimeKumaApi, MonitorType

rows = json.load(sys.stdin)
api = UptimeKumaApi(os.environ["KUMA_URL"], timeout=30)
user, pw = os.environ["KUMA_USER"], os.environ["KUMA_PASSWORD"]

try:
    api.setup(user, pw)
    print("  created the Kuma admin account")
except Exception:
    pass                       # already initialised; just log in
api.login(user, pw)

existing = {m["name"]: m["id"] for m in api.get_monitors()}
made = skipped = failed = 0


def ensure_group(name):
    global made
    if name in existing:
        return existing[name]
    gid = api.add_monitor(type=MonitorType.GROUP, name=name)["monitorID"]
    existing[name] = gid
    made += 1
    print("  group    " + name)
    return gid


for r in rows:
    name = "Internet" if r["service"] == "__internet__" else r["service"]
    if name in existing:
        print("  skip     %s (exists)" % name)
        skipped += 1
        continue
    if r["type"] == "docker":
        # A docker monitor needs a Docker Host entry in Kuma, which
        # cannot be created blind. Report it instead of failing.
        print("  note     %s needs a Docker Host configured in Kuma first"
              % name)
        skipped += 1
        continue
    gid = ensure_group(r["group"])
    common = dict(name=name, parent=gid, interval=60)
    try:
        if r["type"] == "http":
            api.add_monitor(type=MonitorType.HTTP,
                            url="http://%s%s" % (r["target"], r["path"]),
                            accepted_statuscodes=r["codes"],
                            maxretries=2, **common)
        elif r["type"] == "ping":
            api.add_monitor(type=MonitorType.PING, hostname=r["target"],
                            maxretries=3, **common)
        made += 1
        print("  monitor  " + name)
    except Exception as e:
        failed += 1
        print("  FAILED   %s: %s" % (name, e))

print("\n  created %d, skipped %d, failed %d" % (made, skipped, failed))
api.disconnect()
sys.exit(1 if failed else 0)
