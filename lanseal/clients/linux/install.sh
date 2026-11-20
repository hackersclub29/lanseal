#!/usr/bin/env bash
# LANSeal Linux client installer (Kali / Debian / Ubuntu).
# Bootstraps CA trust, generates the private key locally, enrolls with a one-time token, configures
# strongSwan (swanctl), applies the fail-closed firewall, connects, and tests.
# Get the exact command (with token) from the gateway: sudo lanseal enroll <name> linux
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

GW="" GWNAME="" CA_PORT=9000 FP="" NAME="" TOKEN="" OVERLAY="" PROT="" KTY=RSA KSZ=3072 YES=false
IKE="aes256gcm16-prfsha384-ecp384,aes256-sha384-ecp384,aes256-sha256-modp2048"
ESP="aes256gcm16-ecp384,aes256-sha384-ecp384,aes256-sha256-modp2048"
while [ $# -gt 0 ]; do
  case "$1" in
    --gateway) GW="$2"; shift 2;; --gateway-name) GWNAME="$2"; shift 2;; --ca-port) CA_PORT="$2"; shift 2;;
    --fingerprint) FP="$2"; shift 2;; --name) NAME="$2"; shift 2;; --token) TOKEN="$2"; shift 2;;
    --overlay) OVERLAY="$2"; shift 2;; --protected) PROT="$2"; shift 2;;
    --kty) KTY="$2"; shift 2;; --size) KSZ="$2"; shift 2;; --ike) IKE="$2"; shift 2;; --esp) ESP="$2"; shift 2;;
    --yes) YES=true; shift;; *) die "unknown option $1";;
  esac
done
for v in GW GWNAME FP NAME TOKEN OVERLAY PROT; do [ -n "${!v}" ] || die "missing --$(echo "$v" | tr 'A-Z' 'a-z')"; done
[[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]] || die "invalid device name"
[[ "$FP" =~ ^[0-9a-f]{64}$ ]] || die "fingerprint must be 64 hex characters (SHA-256 of the root)"
case "$IKE$ESP" in *3des*|*des-*|*md5*|*sha1*|*modp1024*|*null*) die "weak proposal refused";; esac
python3 - "$GW" "$OVERLAY" "$PROT" <<'PY' || exit 1
import ipaddress, sys
gw, ov, prot = sys.argv[1:]
ipaddress.IPv4Address(gw)
o = ipaddress.ip_network(ov)
for p in prot.split(","):
    n = ipaddress.ip_network(p)
    if o.overlaps(n):
        sys.exit(f"overlay {o} overlaps protected subnet {n}")
PY
FQDN="$NAME.${GWNAME#*.}"

. /etc/os-release
case "${ID:-} ${ID_LIKE:-}" in *kali*|*debian*|*ubuntu*) ;; *) die "unsupported distribution: ${PRETTY_NAME:-unknown} (Debian family only)";; esac
log "distribution: ${PRETTY_NAME:-$ID}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq strongswan-swanctl charon-systemd libcharon-extra-plugins libstrongswan-extra-plugins \
  nftables iproute2 curl openssl python3 >/dev/null
command -v step >/dev/null || die "step-cli not found; install it from https://smallstep.com/docs/step-cli/installation/ and re-run"

# 1. Trust: pin the root by fingerprint (never trust-on-first-use without it).
export STEPPATH=/etc/lanseal/step
install -d -m 0700 "$STEPPATH"
if [ ! -e "$STEPPATH/certs/root_ca.crt" ]; then
  step ca bootstrap --ca-url "https://$GW:$CA_PORT" --fingerprint "$FP" --force >/dev/null
  log "CA trust bootstrapped (root pinned by fingerprint)"
else
  log "CA trust already bootstrapped; skipping"
fi

# 2. Enrollment: the private key is generated here and never leaves this host.
CRT="$STEPPATH/device-chain.crt"; KEY="$STEPPATH/device.key"
if [ -e "$CRT" ] && openssl x509 -checkend 86400 -noout -in "$CRT" >/dev/null 2>&1; then
  log "valid device certificate already present; skipping enrollment"
else
  [ ! -e "$KEY" ] || cp -a "$KEY" "$KEY.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  step ca certificate "$FQDN" "$CRT" "$KEY" --token "$TOKEN" --kty "$KTY" --size "$KSZ" --force >/dev/null
  chmod 0600 "$KEY"
  log "certificate issued for $FQDN"
fi

# 3. Install into strongSwan's credential directories.
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
awk -v p="$TMPD/c" '/-----BEGIN CERTIFICATE-----/{n++; f=sprintf("%s-%d.pem", p, n-1)} f{print > f} /-----END CERTIFICATE-----/{close(f); f=""}' "$CRT"
install -d -m 0755 /etc/swanctl/x509 /etc/swanctl/x509ca /etc/swanctl/x509ocsp /etc/swanctl/x509aa /etc/swanctl/x509ac /etc/swanctl/x509crl /etc/swanctl/pubkey /etc/swanctl/rsa /etc/swanctl/ecdsa /etc/swanctl/pkcs8 /etc/swanctl/pkcs12 /etc/swanctl/conf.d
install -d -m 0700 /etc/swanctl/private
install -m 0644 "$TMPD/c-0.pem" /etc/swanctl/x509/lanseal-device.pem
install -m 0600 "$KEY" /etc/swanctl/private/lanseal-device.key
install -m 0644 "$STEPPATH/certs/root_ca.crt" /etc/swanctl/x509ca/lanseal-root.pem
[ ! -e "$TMPD/c-1.pem" ] || install -m 0644 "$TMPD/c-1.pem" /etc/swanctl/x509ca/lanseal-intermediate.pem

# 4. strongSwan configuration (own file; existing swanctl.conf is only extended, after a backup).
SWCONF=/etc/swanctl/swanctl.conf
if [ ! -e "$SWCONF" ] || ! grep -q '^include conf.d/\*.conf' "$SWCONF"; then
  [ ! -e "$SWCONF" ] || cp -a "$SWCONF" "$SWCONF.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  printf '\ninclude conf.d/*.conf\n' >>"$SWCONF"
fi
cat >/etc/swanctl/conf.d/lanseal.conf <<CONF
# Managed by LANSeal client installer.
connections {
  lanseal {
    version = 2
    mobike = yes
    fragmentation = yes
    proposals = $IKE
    remote_addrs = $GW
    vips = 0.0.0.0
    dpd_delay = 30s
    local {
      auth = pubkey
      certs = lanseal-device.pem
      id = $FQDN
    }
    remote {
      auth = pubkey
      id = $GWNAME
    }
    children {
      lanseal {
        # Only the overlay goes through the tunnel; the default route and the internet are untouched.
        remote_ts = $OVERLAY
        mode = tunnel
        esp_proposals = $ESP
        rekey_time = 1h
        start_action = start
        dpd_action = restart
        close_action = start
      }
    }
  }
}
CONF

# 5. Renewal (daily timer; renews at 2/3 of lifetime, then reloads credentials).
cat >/usr/local/sbin/lanseal-renew <<'RENEW'
#!/usr/bin/env bash
set -Eeuo pipefail
export STEPPATH=/etc/lanseal/step
CRT="$STEPPATH/device-chain.crt"; KEY="$STEPPATH/device.key"
if step certificate needs-renewal "$CRT" --expires-in 33%; then
  step ca renew "$CRT" "$KEY" --force
  d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
  awk -v p="$d/c" '/-----BEGIN CERTIFICATE-----/{n++; f=sprintf("%s-%d.pem", p, n-1)} f{print > f} /-----END CERTIFICATE-----/{close(f); f=""}' "$CRT"
  install -m 0644 "$d/c-0.pem" /etc/swanctl/x509/lanseal-device.pem
  swanctl --load-creds >/dev/null
  logger -t lanseal "device certificate renewed"
fi
RENEW
chmod 0755 /usr/local/sbin/lanseal-renew
cat >/etc/systemd/system/lanseal-renew.service <<'U1'
[Unit]
Description=LANSeal device certificate renewal
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/lanseal-renew
U1
cat >/etc/systemd/system/lanseal-renew.timer <<'U2'
[Unit]
Description=Daily LANSeal certificate renewal check
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
U2
systemctl daemon-reload
systemctl enable --now lanseal-renew.timer >/dev/null

# 6. Fail-closed firewall, then connect.
FWARGS=(--gateway-ip "$GW" --ca-port "$CA_PORT" --protected "$PROT" --overlay "$OVERLAY")
$YES && FWARGS+=(--yes)
"$HERE/firewall.sh" "${FWARGS[@]}"
systemctl enable --now strongswan.service >/dev/null
swanctl --load-all >/dev/null || die "swanctl rejected the configuration (run diagnostics.sh)"
log "waiting for the tunnel..."
for _ in $(seq 1 30); do swanctl --list-sas 2>/dev/null | grep -q ESTABLISHED && break; sleep 1; done
swanctl --list-sas | grep -q ESTABLISHED || die "tunnel did not establish; run: $HERE/diagnostics.sh"

# 7. Report. The tunnel being ESTABLISHED is not proof of encryption; see tests/leak-tests/leak-test.sh.
SERIAL="$(openssl x509 -serial -noout -in /etc/swanctl/x509/lanseal-device.pem | cut -d= -f2)"
cat <<OUT

LANSeal client '$NAME' is connected.
Certificate serial: $SERIAL
On the gateway, record it so the CA-side revocation can be done later:
  sudo lanseal set-serial $NAME $SERIAL
Quick check: ping -c3 <gateway overlay address>   |   Diagnostics: $HERE/diagnostics.sh
(A ping alone is not proof of encryption: run tests/leak-tests/leak-test.sh.)
OUT
