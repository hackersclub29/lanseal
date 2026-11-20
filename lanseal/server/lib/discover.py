#!/usr/bin/env python3
"""Discover the host's real network configuration and print it as JSON.
Read-only: nothing here changes system state."""
import ipaddress
import json
import re
import shutil
import subprocess
import sys

VPN_KINDS = {"wireguard", "tun", "tap", "ppp", "vti", "vti6", "xfrm", "gre", "gretap", "ipip", "sit", "vxlan"}
VPN_NAME = re.compile(r"^(tun|tap|wg|ppp|ipsec|vti|xfrm|tailscale|zt|nordlynx|proton)")
CANDIDATES = ["10.77.0.0/24", "10.78.0.0/24", "172.30.77.0/24", "100.96.77.0/24", "10.99.77.0/24"]


def run_json(*args):
    try:
        out = subprocess.check_output(["ip", "-j", *args], text=True, stderr=subprocess.DEVNULL)
        return json.loads(out or "[]")
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
        return []


def dns_servers():
    found = []
    if shutil.which("resolvectl"):
        try:
            out = subprocess.check_output(["resolvectl", "dns"], text=True, stderr=subprocess.DEVNULL)
            found += re.findall(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", out)
        except (OSError, subprocess.CalledProcessError):
            pass
    try:
        with open("/etc/resolv.conf", encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"\s*nameserver\s+(\S+)", line)
                if m and not m.group(1).startswith("127."):
                    found.append(m.group(1))
    except OSError:
        pass
    seen, out = set(), []
    for ip in found:
        if ip not in seen:
            seen.add(ip)
            out.append(ip)
    return out


def discover():
    links = run_json("link", "show")
    addrs = run_json("addr", "show")
    routes4 = run_json("-4", "route", "show")

    vpn = []
    for link in links:
        kind = (link.get("linkinfo") or {}).get("info_kind", "")
        if kind in VPN_KINDS or VPN_NAME.match(link.get("ifname", "")):
            vpn.append(link["ifname"])

    interfaces, used, ipv6 = [], set(), False
    for a in addrs:
        name, v4 = a.get("ifname"), []
        for info in a.get("addr_info", []):
            if info.get("family") == "inet6" and info.get("scope") == "global":
                ipv6 = True
            if info.get("family") != "inet":
                continue
            net = ipaddress.ip_interface(f"{info['local']}/{info['prefixlen']}")
            v4.append({"address": str(net.ip), "prefixlen": net.network.prefixlen, "network": str(net.network)})
            if name != "lo":
                used.add(str(net.network))
        interfaces.append({"name": name, "state": a.get("operstate"), "ipv4": v4})

    default = None
    for r in routes4:
        if r.get("dst") == "default":
            if default is None or r.get("metric", 0) < default.get("metric", 0):
                default = {"gateway": r.get("gateway"), "interface": r.get("dev"), "metric": r.get("metric", 0)}
        elif r.get("dst"):
            try:
                used.add(str(ipaddress.ip_network(r["dst"], strict=False)))
            except ValueError:
                pass

    return {"interfaces": interfaces, "default_route": default, "dns_servers": dns_servers(),
            "vpn_interfaces": vpn, "used_networks": sorted(used), "ipv6_present": ipv6}


def overlaps(candidate, used):
    c = ipaddress.ip_network(candidate)
    return [u for u in used if c.overlaps(ipaddress.ip_network(u))]


def pick_overlay(used):
    for c in CANDIDATES:
        if not overlaps(c, used):
            return c
    return None


if __name__ == "__main__":
    data = discover()
    data["suggested_overlay"] = pick_overlay(data["used_networks"])
    json.dump(data, sys.stdout, indent=2)
    print()
