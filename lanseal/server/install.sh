#!/usr/bin/env bash
# LANSeal gateway installer (Ubuntu/Debian). Idempotent; every modified file is backed up first.
# Phases covered here: 1 (private CA) and 2 (IPsec gateway).
# Usage: sudo ./install.sh [--yes]
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANSEAL_LIB="$HERE/lib"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
need_root
YES=false; [ "${1:-}" = "--yes" ] && YES=true
trap 'die "install failed at line $LINENO (see messages above; nothing is rolled back automatically, see docs/rollback.md)"' ERR

[ -r "$LANSEAL_CONFIG" ] || die "$LANSEAL_CONFIG missing; run ./configure.sh first"
python3 "$LANSEAL_LIB/validate.py" "$LANSEAL_CONFIG" --live || die "configuration invalid"
. /etc/os-release
case "${ID:-}${ID_LIKE:-}" in *ubuntu*|*debian*) ;; *) die "only Ubuntu/Debian are supported for the gateway (found: ${PRETTY_NAME:-unknown})";; esac

LAN_IF="$(cfg server.lan_interface)"; LAN_IP="$(cfg server.lan_address)"; GW_FQDN="$(cfg server.dns_name)"
OVERLAY="$(cfg network.overlay_subnet)"; GW_OV="$(cfg network.gateway_overlay_address)"; DOMAIN="$(cfg dns.domain)"
CA_PORT="$(cfg pki.ca_port)"; CA_NAME="$(cfg pki.ca_name)"; KTY="$(cfg pki.key_type)"; KSZ="$(cfg pki.key_size)"
DEV_LIFE="$(cfg pki.device_cert_lifetime)"; GW_LIFE="$(cfg pki.gateway_cert_lifetime)"
IKE_PROP="$(cfg ipsec.ike_proposals | paste -sd, -)"
PROT_CSV="$(cfg network.protected_subnets | paste -sd, -)"; ADMIN_CSV="$(cfg server.admin_tcp_ports_lan | paste -sd, -)"

ip -4 addr show dev "$LAN_IF" | grep -qw "$LAN_IP" || die "$LAN_IP is not assigned to $LAN_IF"
echo "About to install the LANSeal gateway on $LAN_IF ($LAN_IP), overlay $OVERLAY."
echo "This installs packages, creates a CA, changes sysctl, and (after confirmation) loads a firewall."
$YES || { read -r -p "Continue? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || die "aborted"; }

# ---- packages ---------------------------------------------------------------------------
info "installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq strongswan-swanctl charon-systemd libcharon-extra-plugins libstrongswan-extra-plugins \
  nftables dnsmasq python3-yaml curl openssl iproute2 >/dev/null
for c in step step-ca; do
  command -v "$c" >/dev/null || die "'$c' not found. Install Smallstep step-cli and step-ca from https://smallstep.com/docs/step-cli/installation/ and https://smallstep.com/docs/step-ca/installation/ then re-run."
done

# ---- directories, library, CLI --------------------------------------------------------------
install -d -m 0755 /usr/local/lib/lanseal
install -m 0755 "$HERE"/lib/*.py "$HERE/lib/common.sh" /usr/local/lib/lanseal/
install -m 0755 "$HERE/bin/lanseal" /usr/local/sbin/lanseal
ln -sf /usr/local/sbin/lanseal /usr/local/bin/lanseal
install -d -m 0755 "$LANSEAL_VAR" "$LANSEAL_BACKUP"
install -d -m 0755 "$LANSEAL_ETC"

# Clean up any stale overlay interface from previous runs
ip link del lanseal0 2>/dev/null || true
ip addr del "$GW_OV/32" dev lanseal0 2>/dev/null || true

# ---- sysctl (forwarding on, redirects off, loose rp_filter for hairpinned tunnel traffic) ----
install_file_from_stdin /etc/sysctl.d/90-lanseal.conf 0644 <<SYS
net.ipv4.ip_forward = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.rp_filter = 2
SYS
sysctl --system >/dev/null

# ---- overlay address ------------------------------------------------------------------------
sed "s|@GW_OV@|$GW_OV|g" "$HERE/templates/lanseal-overlay.service" | install_file_from_stdin /etc/systemd/system/lanseal-overlay.service 0644
systemctl daemon-reload
systemctl enable --now lanseal-overlay.service

# ---- step-ca (PKI control plane) -------------------------------------------------------------
id step >/dev/null 2>&1 || useradd --system --home /etc/step-ca --shell /usr/sbin/nologin step
export STEPPATH=/etc/step-ca
CA_JSON="$STEPPATH/config/ca.json"
PW="$STEPPATH/secrets/password.txt"
if [ ! -e "$CA_JSON" ]; then
  info "initialising private CA (root + intermediate)"
  install -d -m 0700 "$STEPPATH" "$STEPPATH/secrets"
  umask 077; openssl rand -base64 36 >"$PW"; umask 022
  step ca init --deployment-type standalone --name "$CA_NAME" \
    --dns "$GW_FQDN" --dns "$LAN_IP" --dns localhost --dns 127.0.0.1 --address ":$CA_PORT" \
    --provisioner lanseal-admin --password-file "$PW" --provisioner-password-file "$PW" >/dev/null
  # Keep the root key off the always-on host: the running CA only needs the intermediate key.
  OFFLINE="/root/lanseal-ROOT-KEY-move-offline"
  install -d -m 0700 "$OFFLINE"
  mv "$STEPPATH/secrets/root_ca_key" "$OFFLINE/root_ca_key"
  warn "ROOT CA KEY moved to $OFFLINE. Copy it to offline storage and keep the password ($PW) backed up separately."
else
  info "CA already initialised; leaving it untouched"
fi

install -d -m 0755 "$STEPPATH/templates"
install -m 0644 "$HERE/templates/ipsec-client.tpl" "$HERE/templates/ipsec-gateway.tpl" "$STEPPATH/templates/"
has_prov() { python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); sys.exit(0 if any(p["name"]==sys.argv[2] for p in c["authority"]["provisioners"]) else 1)' "$CA_JSON" "$1"; }
if ! has_prov lanseal-enroll; then
  backup_file "$CA_JSON"
  step ca provisioner add lanseal-enroll --type JWK --create --password-file "$PW" --ca-config "$CA_JSON" \
    --x509-template "$STEPPATH/templates/ipsec-client.tpl" \
    --x509-min-dur 5m --x509-max-dur "$DEV_LIFE" --x509-default-dur "$DEV_LIFE" >/dev/null
fi
if ! has_prov lanseal-gateway; then
  backup_file "$CA_JSON"
  step ca provisioner add lanseal-gateway --type JWK --create --password-file "$PW" --ca-config "$CA_JSON" \
    --x509-template "$STEPPATH/templates/ipsec-gateway.tpl" \
    --x509-min-dur 5m --x509-max-dur "$GW_LIFE" --x509-default-dur "$GW_LIFE" >/dev/null
fi
# Enable CRL generation (step-ca marks this experimental). Passive revocation works regardless.
python3 - "$CA_JSON" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
if c.get("crl", {}).get("enabled") is not True:
    c["crl"] = {"enabled": True, "generateOnRevoke": True}
    json.dump(c, open(p, "w"), indent=2)
PY
install -d -m 0700 -o step -g step "$STEPPATH/db"
chown -R step:step "$STEPPATH"
chmod 0600 "$PW"

install_file_from_stdin /etc/systemd/system/step-ca.service 0644 <"$HERE/templates/step-ca.service"
systemctl daemon-reload
systemctl enable step-ca.service
systemctl restart step-ca.service
ROOT_CRT="$STEPPATH/certs/root_ca.crt"
for i in $(seq 1 20); do
  step ca health --ca-url "https://127.0.0.1:$CA_PORT" --root "$ROOT_CRT" >/dev/null 2>&1 && break
  [ "$i" -eq 20 ] && die "step-ca did not become healthy: journalctl -u step-ca"
  sleep 1
done
info "step-ca healthy"

# ---- gateway certificate -----------------------------------------------------------------------
install -d -m 0755 /etc/swanctl/x509 /etc/swanctl/x509ca /etc/swanctl/x509ocsp /etc/swanctl/x509aa /etc/swanctl/x509ac /etc/swanctl/x509crl /etc/swanctl/pubkey /etc/swanctl/rsa /etc/swanctl/ecdsa /etc/swanctl/pkcs8 /etc/swanctl/pkcs12 /etc/swanctl/conf.d
install -d -m 0700 /etc/swanctl/private
cert_days_left() { openssl x509 -checkend $((14*86400)) -noout -in "$1" >/dev/null 2>&1; }
if [ ! -e /etc/swanctl/x509/lanseal-gateway.pem ] || ! cert_days_left /etc/swanctl/x509/lanseal-gateway.pem; then
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  step ca certificate "$GW_FQDN" "$TMPD/gw.crt" "$TMPD/gw.key" --provisioner lanseal-gateway \
    --provisioner-password-file "$PW" --san "$GW_FQDN" --san "$LAN_IP" --kty "$KTY" --size "$KSZ" \
    --ca-url "https://127.0.0.1:$CA_PORT" --root "$ROOT_CRT" --force >/dev/null
  split_pem "$TMPD/gw.crt" "$TMPD/c"
  insp="$(step certificate inspect "$TMPD/c-0.pem")"
  grep -q "Server Authentication" <<<"$insp" || die "gateway certificate lacks serverAuth EKU (template not applied)"
  grep -q "1.3.6.1.5.5.8.2.2" <<<"$insp" || warn "gateway certificate lacks the IKE-intermediate EKU; Windows may reject it"
  grep -q "$GW_FQDN" <<<"$insp" || die "gateway certificate lacks the expected DNS SAN"
  backup_file /etc/swanctl/x509/lanseal-gateway.pem
  install -m 0644 "$TMPD/c-0.pem" /etc/swanctl/x509/lanseal-gateway.pem
  install -m 0600 "$TMPD/gw.key" /etc/swanctl/private/lanseal-gateway.key
  rm -rf "$TMPD"; trap - EXIT
fi
install -m 0644 "$ROOT_CRT" /etc/swanctl/x509ca/lanseal-root.pem
install -m 0644 "$STEPPATH/certs/intermediate_ca.crt" /etc/swanctl/x509ca/lanseal-intermediate.pem

# ---- strongSwan (IPsec data plane) ---------------------------------------------------------------
install_file_from_stdin /etc/swanctl/swanctl.conf 0644 <<SW
# Managed by LANSeal. One file per enrolled device lives in conf.d/ (created by 'lanseal enroll').
include conf.d/*.conf
SW
systemctl enable --now strongswan.service
swanctl --load-all >/dev/null || die "swanctl rejected the configuration"

# ---- DNS inside the overlay -----------------------------------------------------------------------
install_file_from_stdin /etc/dnsmasq.d/lanseal.conf 0644 <<DNS
# Managed by LANSeal: authoritative names for enrolled devices, answered on the overlay address only.
listen-address=$GW_OV
bind-interfaces
no-resolv
no-hosts
addn-hosts=$LANSEAL_VAR/hosts
domain=$DOMAIN
local=/$DOMAIN/
DNS
python3 "$LANSEAL_LIB/registry.py" hosts "$GW_FQDN" "$GW_OV" "$DOMAIN" >"$LANSEAL_VAR/hosts"
chmod 644 "$LANSEAL_VAR/hosts"
install -d -m 0755 /etc/systemd/system/dnsmasq.service.d
install_file_from_stdin /etc/systemd/system/dnsmasq.service.d/lanseal.conf 0644 <<UNIT
[Unit]
After=lanseal-overlay.service
Requires=lanseal-overlay.service
UNIT
systemctl daemon-reload
systemctl enable dnsmasq.service
systemctl restart dnsmasq.service

# ---- firewall (validated, then applied with an automatic 60 s rollback) ------------------------------------
NFT="$LANSEAL_ETC/gateway.nft"
sed -e "s|@PROTECTED@|{ ${PROT_CSV//,/, } }|g" -e "s|@CA_PORT@|$CA_PORT|g" -e "s|@ADMIN_PORTS@|${ADMIN_CSV//,/, }|g" \
    -e "s|@OVERLAY@|$OVERLAY|g" -e "s|@GW_OV@|$GW_OV|g" "$HERE/templates/gateway.nft.in" \
  | install_file_from_stdin "$NFT" 0600
nft -c -f "$NFT" || die "nft rejected $NFT (syntax/feature check failed); firewall NOT applied"
install_file_from_stdin /etc/systemd/system/lanseal-firewall.service 0644 <<FW
[Unit]
Description=LANSeal gateway firewall
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f $NFT
ExecStop=/usr/sbin/nft delete table ip lanseal_gw

[Install]
WantedBy=multi-user.target
FW
systemctl daemon-reload
nft -f "$NFT"
if $YES; then keep=keep; else
  echo "Firewall loaded. If you can still reach this host, type 'keep' within 60 s; otherwise it is removed automatically."
  read -r -t 60 -p "> " keep || keep=""
fi
if [ "$keep" = "keep" ]; then
  systemctl enable lanseal-firewall.service
  info "firewall kept and enabled at boot"
else
  nft delete table ip lanseal_gw
  warn "firewall removed (not confirmed). Re-run install.sh, or load $NFT manually, when ready."
fi

echo
info "gateway installed. Root fingerprint (clients pin this): $(step certificate fingerprint "$ROOT_CRT")"
info "Enroll a device:  sudo lanseal enroll <name> <linux|windows|android>"
