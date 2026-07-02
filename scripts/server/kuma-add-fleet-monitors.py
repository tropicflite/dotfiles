#!/usr/bin/env python3
"""Add Tailscale fleet ping monitors to Uptime Kuma."""

import sys
from uptime_kuma_api import UptimeKumaApi, MonitorType

KUMA_URL = "http://localhost:3003"
NTFY_NOTIFICATION_ID = 1

MONITORS = [
    ("Desktop", "100.78.51.10"),
    ("Laptop",  "100.120.69.120"),
    ("Mini",    "100.73.76.59"),
    ("Phone",   "100.82.1.81"),
    ("Quest",   "100.74.113.62"),
]

def main():
    if len(sys.argv) < 2:
        print("Usage: kuma-add-fleet-monitors.py <password>")
        sys.exit(1)

    password = sys.argv[1]

    api = UptimeKumaApi(KUMA_URL)
    api.login("matt", password)

    existing = {m["name"] for m in api.get_monitors()}

    for name, host in MONITORS:
        if name in existing:
            print(f"  SKIP {name} — already exists")
            continue

        data = api._build_monitor_data(
            type=MonitorType.PING,
            name=name,
            hostname=host,
            interval=60,
            maxretries=3,
            notificationIDList={str(NTFY_NOTIFICATION_ID): True},
        )
        data["conditions"] = []
        from uptime_kuma_api import Event
        with api.wait_for_event(Event.MONITOR_LIST):
            result = api._call("add", data)
        print(f"  ADD  {name} ({host}) → id={result.get('monitorID')}")

    api.disconnect()
    print("Done.")

if __name__ == "__main__":
    main()
