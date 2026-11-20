#!/usr/bin/env python3
"""Device registry (JSON, 0600). Source of truth for which identities may connect.

  registry.py add NAME PLATFORM OVERLAY POOL_START GATEWAY_OV   -> prints allocated address
  registry.py revoke NAME | get NAME | list | set-serial NAME SERIAL
  registry.py hosts GATEWAY_FQDN GATEWAY_OV DOMAIN              -> hosts-file lines (active devices)
"""
import fcntl
import ipaddress
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

PATH = os.environ.get("LANSEAL_REGISTRY", "/var/lib/lanseal/devices.json")
PLATFORMS = ("linux", "windows", "android")


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Store:
    def __enter__(self):
        os.makedirs(os.path.dirname(PATH), exist_ok=True)
        self.lock = open(PATH + ".lock", "w")
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        try:
            with open(PATH, encoding="utf-8") as fh:
                self.data = json.load(fh)
        except FileNotFoundError:
            self.data = {}
        return self

    def save(self):
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(PATH))
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(self.data, fh, indent=2, sort_keys=True)
        os.chmod(tmp, 0o600)
        os.replace(tmp, PATH)

    def __exit__(self, *exc):
        fcntl.flock(self.lock, fcntl.LOCK_UN)
        self.lock.close()


def main(argv):
    if not argv:
        sys.exit(__doc__)
    cmd, args = argv[0], argv[1:]
    with Store() as s:
        d = s.data
        if cmd == "add":
            name, platform, overlay, start, gw = args
            if platform not in PLATFORMS:
                sys.exit(f"platform must be one of {PLATFORMS}")
            if name in d and d[name]["status"] == "active":
                sys.exit(f"device '{name}' already enrolled")
            net = ipaddress.ip_network(overlay)
            used = {ipaddress.ip_address(v["address"]) for v in d.values() if v["status"] == "active"}
            used.add(ipaddress.ip_address(gw))
            addr = ipaddress.ip_address(start)
            while addr in net and (addr in used or addr in (net.network_address, net.broadcast_address)):
                addr += 1
            if addr not in net or addr == net.broadcast_address:
                sys.exit("overlay pool exhausted")
            history = d.get(name, {}).get("history", [])
            d[name] = {"platform": platform, "address": str(addr), "status": "active", "enrolled": now(),
                       "serial": "", "history": history}
            s.save()
            print(addr)
        elif cmd == "revoke":
            if args[0] not in d:
                sys.exit("unknown device")
            d[args[0]]["history"].append({"event": "revoked", "at": now(), "address": d[args[0]]["address"]})
            d[args[0]]["status"] = "revoked"
            s.save()
        elif cmd == "get":
            print(json.dumps(d[args[0]]) if args[0] in d else "")
        elif cmd == "list":
            print(json.dumps(d))
        elif cmd == "set-serial":
            if args[0] not in d:
                sys.exit("unknown device")
            d[args[0]]["serial"] = args[1].replace(":", "").lower()
            s.save()
        elif cmd == "hosts":
            gwname, gwip, domain = args
            print(f"{gwip} {gwname}")
            for n, v in sorted(d.items()):
                if v["status"] == "active":
                    print(f"{v['address']} {n}.{domain} {n}")
        else:
            sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
