#!/usr/bin/env bash
# Plaintext-leak and fail-closed test, run on a LANSeal Linux client.
# Prerequisite: an HTTP server on another enrolled device's OVERLAY address, e.g. on that device:
#   python3 -m http.server 8080 --bind <its overlay address>
# Usage: sudo ./leak-test.sh --iface wlan0 --target <overlay ip> [--port 8080] [--peer-lan-ip <LAN ip of that device>]
# Proof of encryption = (a) ESP seen on the wire, (b) a unique marker sent in cleartext HTTP never appears
# in the capture, (c) no TCP segments to the service port appear on the physical interface.
# The fail-closed section stops the tunnel (and restarts it afterwards).
set -uo pipefail
IFACE="" TARGET="" PORT=8080 PEER="" SKIP_FC=false
while [ $# -gt 0 ]; do case "$1" in
  --iface) IFACE="$2"; shift 2;; --target) TARGET="$2"; shift 2;; --port) PORT="$2"; shift 2;;
  --peer-lan-ip) PEER="$2"; shift 2;; --skip-failclosed) SKIP_FC=true; shift;; *) echo "unknown $1"; exit 2;; esac; done
[ "$(id -u)" -eq 0 ] && [ -n "$IFACE" ] && [ -n "$TARGET" ] || { echo "usage: sudo $0 --iface IF --target OVERLAY_IP [--port N] [--peer-lan-ip IP]"; exit 2; }
command -v tcpdump >/dev/null || { echo "install tcpdump first"; exit 2; }
OUT="$(dirname "$0")/report-$(date -u +%Y%m%dT%H%M%SZ).txt"
MARK="LANSEAL-MARK-$(head -c6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
FAILS=0
say()  { echo "$*" | tee -a "$OUT"; }
check() { # check "description" expected(PASS cond) -> runs on $? of previous command via arg
  if [ "$2" = 0 ]; then say "PASS  $1"; else say "FAIL  $1"; FAILS=$((FAILS+1)); fi; }
capture() { # capture FILE SECONDS-CMD...
  local f="$1"; shift; tcpdump -i "$IFACE" -nn -U -w "$f" >/dev/null 2>&1 & TD=$!; sleep 1; "$@"; local rc=$?; sleep 1; kill "$TD" 2>/dev/null; wait "$TD" 2>/dev/null; return $rc; }
say "LANSeal leak test $(date -u +%FT%TZ)  iface=$IFACE target=$TARGET:$PORT marker=$MARK"

say; say "--- T1 tunnel up: traffic must be ESP, payload must not be visible"
P1="$(mktemp)"
capture "$P1" curl -s -m 8 -o /dev/null -w '%{http_code}' -H "X-Lanseal-Marker: $MARK" "http://$TARGET:$PORT/?m=$MARK" >"$P1.code"
CODE="$(cat "$P1.code" 2>/dev/null)"; say "      HTTP status: ${CODE:-none}"
[ "$CODE" = "200" ]; check "HTTP request over the overlay succeeded (200)" $?
ESPN="$(tcpdump -nn -r "$P1" 'esp or udp port 4500' 2>/dev/null | wc -l)"; say "      ESP/NAT-T packets on $IFACE: $ESPN"
[ "$ESPN" -gt 0 ]; check "ESP (or UDP/4500 NAT-T) packets observed on the physical interface" $?
grep -qa "$MARK" "$P1"; [ $? -ne 0 ]; check "cleartext marker is NOT present anywhere in the capture" $?
TCPN="$(tcpdump -nn -r "$P1" "tcp port $PORT" 2>/dev/null | wc -l)"
[ "$TCPN" -eq 0 ]; check "no TCP/$PORT segments visible on the physical interface" $?

if ! $SKIP_FC; then
  say; say "--- T2 tunnel down: nothing may fall back to plaintext"
  swanctl --terminate --ike lanseal >/dev/null 2>&1; systemctl stop strongswan; sleep 2
  P2="$(mktemp)"
  capture "$P2" curl -s -m 5 -o /dev/null -H "X-Lanseal-Marker: $MARK" "http://$TARGET:$PORT/?m=$MARK"
  [ $? -ne 0 ]; check "overlay request FAILS while the tunnel is down" $?
  grep -qa "$MARK" "$P2"; [ $? -ne 0 ]; check "marker not on the wire while tunnel is down" $?
  N2="$(tcpdump -nn -r "$P2" "host $TARGET" 2>/dev/null | wc -l)"
  [ "$N2" -eq 0 ]; check "no packets to the overlay target left the host" $?
  if [ -n "$PEER" ]; then
    P3="$(mktemp)"
    capture "$P3" curl -s -m 5 -o /dev/null -H "X-Lanseal-Marker: $MARK" "http://$PEER:$PORT/?m=$MARK"
    [ $? -ne 0 ]; check "direct plaintext request to the peer's LAN address FAILS" $?
    grep -qa "$MARK" "$P3"; [ $? -ne 0 ]; check "marker not on the wire for the direct-LAN attempt" $?
    rm -f "$P3"
  else say "SKIP  direct LAN peer test (no --peer-lan-ip given)"; fi
  systemctl start strongswan; swanctl --load-all >/dev/null 2>&1
  for _ in $(seq 1 30); do swanctl --list-sas 2>/dev/null | grep -q ESTABLISHED && break; sleep 1; done
  swanctl --list-sas 2>/dev/null | grep -q ESTABLISHED; check "tunnel re-established automatically after restart" $?
  rm -f "$P2"
fi
rm -f "$P1" "$P1.code"
say; say "RESULT: $FAILS failure(s). Report saved to $OUT"
say "Manual follow-up: open a capture of $IFACE in Wireshark during a request and confirm only ESP/IKE is shown."
exit "$FAILS"
