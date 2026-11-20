#!/usr/bin/env bash
# Interactive configuration wizard: discovers the real network, asks you to confirm every
# value, validates, and writes /etc/lanseal/config.yaml (existing file is backed up).
# Usage: sudo ./configure.sh [--yes]     (--yes accepts all discovered defaults)
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANSEAL_LIB="$HERE/lib"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
need_root
need_cmd python3
need_cmd ip "(package iproute2)"
YES=false; [ "${1:-}" = "--yes" ] && YES=true

ask() { # ask VAR "prompt" default
  local __var="$1" prompt="$2" def="$3" ans
  if $YES; then printf -v "$__var" '%s' "$def"; return; fi
  read -r -p "$prompt [$def]: " ans || true
  printf -v "$__var" '%s' "${ans:-$def}"
}

disc="$(python3 "$LANSEAL_LIB/discover.py")"
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1" <<<"$disc"; }

def_if="$(j "(d['default_route'] or {}).get('interface','')")"
def_gw="$(j "(d['default_route'] or {}).get('gateway','')")"
[ -n "$def_if" ] || die "no default route found; connect to the LAN first (or pass values manually by editing config.yaml)"
def_ip="$(j "next((a['address'] for i in d['interfaces'] if i['name']=='$def_if' for a in i['ipv4']), '')")"
def_net="$(j "next((a['network'] for i in d['interfaces'] if i['name']=='$def_if' for a in i['ipv4']), '')")"
overlay="$(j "d['suggested_overlay'] or ''")"
[ -n "$overlay" ] || die "none of the candidate overlay subnets is free; set network.overlay_subnet by hand"

echo "=== Discovered network ==="
echo "  LAN interface : $def_if"
echo "  LAN address   : $def_ip"
echo "  LAN subnet    : $def_net"
echo "  Default gw    : $def_gw"
echo "  DNS servers   : $(j "', '.join(d['dns_servers'])")"
echo "  VPN-like links: $(j "', '.join(d['vpn_interfaces']) or 'none'")"
echo "  IPv6 present  : $(j "d['ipv6_present']")  (LANSeal protects IPv4 only; see docs/limitations.md)"
echo "  Free overlay  : $overlay"
echo

ask lan_if  "LAN interface" "$def_if"
ask lan_ip  "Gateway LAN address" "$def_ip"
ask prot    "Protected LAN subnet" "$def_net"
ask domain  "Internal DNS domain" "lanseal.home.arpa"
ask gwname  "Gateway DNS name" "gw.$domain"
ask overlay "Overlay subnet" "$overlay"
ov_base="${overlay%/*}"; ov_pref="${overlay#*/}"
IFS=. read -r o1 o2 o3 o4 <<<"$ov_base"
ask gw_ov   "Gateway overlay address" "$o1.$o2.$o3.$((o4 + 1))"
ask pool    "First device overlay address" "$o1.$o2.$o3.$((o4 + 16))"
ask ssh     "Gateway TCP ports to keep open to the LAN (comma separated)" "22"
ssh_yaml="[$(echo "$ssh" | tr -d ' ')]"

tmp="$(mktemp)"
sed -e "s|^  lan_interface:.*|  lan_interface: $lan_if|" \
    -e "s|^  lan_address:.*|  lan_address: $lan_ip|" \
    -e "s|^  dns_name:.*|  dns_name: $gwname|" \
    -e "s|^  admin_tcp_ports_lan:.*|  admin_tcp_ports_lan: $ssh_yaml|" \
    -e "s|^  protected_subnets:.*|  protected_subnets: [$prot]|" \
    -e "s|^  overlay_subnet:.*|  overlay_subnet: $overlay|" \
    -e "s|^  gateway_overlay_address:.*|  gateway_overlay_address: $gw_ov|" \
    -e "s|^  device_pool_start:.*|  device_pool_start: $pool|" \
    -e "s|^  domain:.*|  domain: $domain|" \
    "$HERE/../config/config.example.yaml" >"$tmp"
: "$ov_pref"

python3 "$LANSEAL_LIB/validate.py" "$tmp" --live || { rm -f "$tmp"; die "fix the values above and re-run"; }
echo; cat "$tmp"; echo
if ! $YES; then read -r -p "Write this to $LANSEAL_CONFIG? [y/N] " ok; [[ "$ok" =~ ^[Yy]$ ]] || { rm -f "$tmp"; die "aborted, nothing written"; }; fi
install_file_from_stdin "$LANSEAL_CONFIG" 0640 root:root <"$tmp"
rm -f "$tmp"
info "configuration saved. Next: sudo ./install.sh"
