#!/usr/bin/env bash
# Read-only diagnostics for a LANSeal Linux client.
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
sec() { printf '\n===== %s =====\n' "$1"; }
sec "service";            systemctl is-active strongswan lanseal-client-firewall lanseal-renew.timer 2>&1
sec "IKE/Child SAs (negotiated algorithms)"; swanctl --list-sas 2>&1 | head -40
sec "device certificate"; openssl x509 -in /etc/swanctl/x509/lanseal-device.pem -noout -subject -serial -enddate -ext extendedKeyUsage,subjectAltName 2>&1
sec "routing: policy rules + table 220 (strongSwan)"; ip rule show; ip route show table 220 2>&1; ip route show | grep -E 'unreachable|default' 
sec "xfrm policies"; ip xfrm policy 2>&1 | head -30
sec "firewall table"; nft list table inet lanseal_client 2>&1 | head -50
sec "recent logs"; journalctl -u strongswan -n 40 --no-pager 2>&1
