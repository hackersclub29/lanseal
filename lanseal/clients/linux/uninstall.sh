#!/usr/bin/env bash
# LANSeal Linux client uninstaller. Removes strongSwan config, firewall, renewal timer, and CA trust.
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Stop and disable services
log "stopping services..."
systemctl disable --now lanseal-renew.timer 2>/dev/null || true
systemctl disable --now lanseal-client-firewall.service 2>/dev/null || true
systemctl disable --now strongswan.service 2>/dev/null || true

# 2. Remove firewall
log "removing firewall..."
"$HERE/firewall.sh" --remove 2>/dev/null || true

# 3. Remove strongSwan configuration
log "removing strongSwan configuration..."
rm -f /etc/swanctl/conf.d/lanseal.conf
rm -f /etc/swanctl/x509/lanseal-device.pem
rm -f /etc/swanctl/private/lanseal-device.key
rm -f /etc/swanctl/x509ca/lanseal-root.pem
rm -f /etc/swanctl/x509ca/lanseal-intermediate.pem
# Remove include line from swanctl.conf if present
if [ -f /etc/swanctl/swanctl.conf ]; then
  sed -i '/include conf.d\/\*.conf/d' /etc/swanctl/swanctl.conf
fi

# 4. Remove CA trust and certificates
log "removing CA trust..."
rm -rf /etc/lanseal/step

# 5. Remove renewal script and timer
log "removing renewal timer..."
rm -f /usr/local/sbin/lanseal-renew
rm -f /etc/systemd/system/lanseal-renew.service
rm -f /etc/systemd/system/lanseal-renew.timer
systemctl daemon-reload

# 6. Remove ip route if present
ip route del unreachable 10.77.0.0/24 metric 4000 2>/dev/null || true

log "LANSeal client uninstalled."