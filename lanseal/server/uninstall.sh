#!/usr/bin/env bash
# Removes LANSeal's services, firewall table and managed config. Keeps the CA and all backups unless --purge.
# Usage: sudo ./uninstall.sh [--purge]
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
PURGE=false; [ "${1:-}" = "--purge" ] && PURGE=true
nft delete table ip lanseal_gw 2>/dev/null || true
for u in lanseal-firewall lanseal-overlay step-ca; do systemctl disable --now "$u.service" 2>/dev/null || true; done
rm -f /etc/systemd/system/{lanseal-firewall,lanseal-overlay,step-ca}.service /etc/systemd/system/dnsmasq.service.d/lanseal.conf
rm -f /etc/dnsmasq.d/lanseal.conf /etc/swanctl/conf.d/dev-*.conf /etc/sysctl.d/90-lanseal.conf
systemctl daemon-reload; systemctl restart dnsmasq 2>/dev/null || true; swanctl --load-all >/dev/null 2>&1 || true
rm -f /usr/local/sbin/lanseal; rm -rf /usr/local/lib/lanseal
echo "Removed services/config. Backups remain in /var/lib/lanseal/backups. sysctl values revert at next boot (or run: sysctl net.ipv4.ip_forward=0)."
if $PURGE; then rm -rf /etc/step-ca /etc/lanseal /var/lib/lanseal /etc/swanctl/x509/lanseal-gateway.pem /etc/swanctl/private/lanseal-gateway.key; echo "PURGED CA and state."; fi
