#!/usr/bin/env python3
"""Render the device registry (JSON on stdin) as a table. Tunnel state comes from env SAS (swanctl --list-sas)."""
import json
import os
import sys

sas = os.environ.get("SAS", "")
devices = json.load(sys.stdin)


def tunnel_state(name):
    for line in sas.splitlines():
        if line.startswith(f"lanseal-{name}:") and "ESTABLISHED" in line:
            return "ESTABLISHED"
    return "-"


print(f"{'NAME':<16}{'PLATFORM':<10}{'OVERLAY IP':<16}{'STATUS':<9}{'TUNNEL':<13}SERIAL")
for name, v in sorted(devices.items()):
    print(f"{name:<16}{v['platform']:<10}{v['address']:<16}{v['status']:<9}{tunnel_state(name):<13}{v['serial'] or 'unknown'}")
