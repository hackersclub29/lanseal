#!/usr/bin/env python3
"""validate.py CONFIG.yaml [--live]
Validate every value before anything is generated. --live also checks the overlay
subnet against the host's real routes/addresses. Exit 0 valid, 1 invalid, 2 usage."""
import ipaddress
import os
import re
import sys

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

WEAK = re.compile(r"(^|[-_])(des|3des|md5|sha1|null|rc4|blowfish|cast128|modp768|modp1024|modp1536)([-_]|$)", re.I)
HOST = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    live = "--live" in sys.argv
    errs = []
    err = errs.append

    try:
        with open(sys.argv[1], encoding="utf-8") as fh:
            c = yaml.safe_load(fh)
    except (OSError, yaml.YAMLError) as e:
        print(f"cannot read config: {e}")
        return 1
    if not isinstance(c, dict):
        print("config root must be a mapping")
        return 1

    def get(path):
        n = c
        for p in path.split("."):
            if not isinstance(n, dict) or p not in n:
                err(f"missing key: {path}")
                return None
            n = n[p]
        return n

    if get("version") != 1:
        err("version must be 1")

    lan_if, lan_ip = get("server.lan_interface"), get("server.lan_address")
    dns_name, ports = get("server.dns_name"), get("server.admin_tcp_ports_lan")
    if not (isinstance(lan_if, str) and re.fullmatch(r"[A-Za-z0-9_.:-]{1,15}", lan_if)):
        err("server.lan_interface is not a valid interface name")
    try:
        lan_addr = ipaddress.IPv4Address(lan_ip)
    except ValueError:
        lan_addr = None
        err("server.lan_address is not an IPv4 address")
    if not (isinstance(dns_name, str) and HOST.match(dns_name)):
        err("server.dns_name must be a lower-case FQDN")
    if not (isinstance(ports, list) and ports and all(isinstance(p, int) and 1 <= p <= 65535 for p in ports)):
        err("server.admin_tcp_ports_lan must be a non-empty list of ports (refusing to lock you out of SSH)")

    protected = get("network.protected_subnets")
    if not isinstance(protected, list) or not protected:
        err("network.protected_subnets must be a non-empty list of IPv4 CIDRs")
        protected = []
    prot = []
    for s in protected:
        try:
            network = ipaddress.ip_network(s, strict=True)
            if network.version != 4:
                raise ValueError("IPv4 required")
            prot.append(network)
        except (ValueError, TypeError):
            err(f"network.protected_subnets: invalid CIDR {s!r}")
    try:
        overlay = ipaddress.ip_network(get("network.overlay_subnet"), strict=True)
    except (ValueError, TypeError):
        overlay = None
        err("network.overlay_subnet is not a valid CIDR")
    gw_ov = pool = None
    try:
        gw_ov = ipaddress.IPv4Address(get("network.gateway_overlay_address"))
        pool = ipaddress.IPv4Address(get("network.device_pool_start"))
    except (ValueError, TypeError):
        err("network.gateway_overlay_address / device_pool_start must be IPv4 addresses")

    if overlay is not None:
        if overlay.version != 4 or not 16 <= overlay.prefixlen <= 28:
            err("overlay_subnet must be IPv4 between /16 and /28")
        if not overlay.is_private:
            err("overlay_subnet must be a private range")
        for p in prot:
            if overlay.overlaps(p):
                err(f"overlay_subnet {overlay} overlaps protected subnet {p}")
        if gw_ov and gw_ov not in overlay:
            err("gateway_overlay_address is outside overlay_subnet")
        if pool and pool not in overlay:
            err("device_pool_start is outside overlay_subnet")
        if gw_ov and pool and pool <= gw_ov:
            err("device_pool_start must be above gateway_overlay_address")
    if lan_addr and prot and not any(lan_addr in p for p in prot):
        err(f"server.lan_address {lan_addr} is not inside any protected subnet")

    if live and overlay is not None:
        import discover as d
        hit = d.overlaps(str(overlay), d.discover()["used_networks"])
        if hit:
            err(f"overlay_subnet overlaps existing local networks/routes: {', '.join(hit)}")

    dom = get("dns.domain")
    if not (isinstance(dom, str) and HOST.match(dom)):
        err("dns.domain must be a lower-case domain name")
    if isinstance(dns_name, str) and isinstance(dom, str) and not dns_name.endswith("." + dom):
        err("server.dns_name must be inside dns.domain")

    kt, ks = get("pki.key_type"), get("pki.key_size")
    if kt not in ("RSA", "EC"):
        err("pki.key_type must be RSA or EC")
    if kt == "RSA" and ks not in (3072, 4096):
        err("RSA key_size must be 3072 or 4096")
    if kt == "EC" and ks not in (256, 384):
        err("EC key_size must be 256 or 384")
    port = get("pki.ca_port")
    if not (isinstance(port, int) and 1 <= port <= 65535):
        err("pki.ca_port invalid")
    for k in ("pki.device_cert_lifetime", "pki.gateway_cert_lifetime"):
        v = get(k)
        if not (isinstance(v, str) and re.fullmatch(r"[0-9]+h", v) and int(v[:-1]) >= 24):
            err(f"{k} must be hours >= 24h, e.g. 720h")
    ttl = get("pki.enrollment_token_ttl")
    if not (isinstance(ttl, str) and re.fullmatch(r"[0-9]+[mh]", ttl)):
        err("pki.enrollment_token_ttl must look like 15m")
    name = get("pki.ca_name")
    if not (isinstance(name, str) and len(name) >= 3 and re.fullmatch(r"[A-Za-z0-9 ._-]+", name)):
        err("pki.ca_name must be 3+ characters of letters, digits, space . _ -")

    for k in ("ipsec.ike_proposals", "ipsec.esp_proposals"):
        v = get(k)
        if not (isinstance(v, list) and v):
            err(f"{k} must be a non-empty list")
            continue
        for p in v:
            if not isinstance(p, str) or not re.fullmatch(r"[a-z0-9_-]+", p):
                err(f"{k}: malformed proposal {p!r}")
                continue
            if WEAK.search(p):
                err(f"{k}: weak algorithm refused in {p!r}")
            if "gcm" not in p and "sha2" not in p and not re.search(r"sha(256|384|512)", p):
                err(f"{k}: {p!r} has no strong integrity algorithm")
            if k.endswith("esp_proposals") and not re.search(r"(ecp|modp|curve)", p):
                err(f"{k}: {p!r} has no DH group, so no Perfect Forward Secrecy")
    for k in ("ipsec.ike_rekey_time", "ipsec.child_rekey_time", "ipsec.dpd_delay"):
        v = get(k)
        if not (isinstance(v, str) and re.fullmatch(r"[0-9]+[smh]", v)):
            err(f"{k} must look like 30s / 1h")
    if get("firewall.fail_closed") is not True:
        err("firewall.fail_closed must be true (silent plaintext fallback is not supported)")

    if errs:
        print("Configuration INVALID:")
        for e in errs:
            print(f"  - {e}")
        return 1
    print("Configuration valid.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
