#!/usr/bin/env bash
# Shared helpers for LANSeal server scripts. Source this file; do not execute it.
LANSEAL_ETC="${LANSEAL_ETC:-/etc/lanseal}"
LANSEAL_VAR="${LANSEAL_VAR:-/var/lib/lanseal}"
LANSEAL_CONFIG="${LANSEAL_CONFIG:-$LANSEAL_ETC/config.yaml}"
LANSEAL_BACKUP="${LANSEAL_BACKUP:-$LANSEAL_VAR/backups}"
LANSEAL_LIB="${LANSEAL_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

_log() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$1" "${*:2}" >&2; }
info() { _log INFO "$@"; }
warn() { _log WARN "$@"; }
die()  { _log ERROR "$@"; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"; }
need_cmd()  { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1 ${2:-}"; }

# cfg KEY -> value(s) from the validated config file.
cfg() { python3 "$LANSEAL_LIB/cfg.py" "$LANSEAL_CONFIG" "$1"; }

# backup_file PATH: copy an existing file into the timestamped backup tree before it is modified.
backup_file() {
  local f="$1" dest
  [ -e "$f" ] || return 0
  dest="$LANSEAL_BACKUP/$(date -u +%Y%m%dT%H%M%SZ)$f"
  mkdir -p "$(dirname "$dest")"
  cp -a "$f" "$dest"
  info "backed up $f -> $dest"
}

# install_file_from_stdin PATH MODE [OWNER:GROUP]: idempotent write; backs up and logs only on change.
install_file_from_stdin() {
  local path="$1" mode="$2" owner="${3:-root:root}" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if [ -e "$path" ] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    return 0
  fi
  backup_file "$path"
  mkdir -p "$(dirname "$path")"
  install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$path"
  rm -f "$tmp"
  info "wrote $path"
}

# split_pem FILE PREFIX: write each certificate in FILE to PREFIX-<n>.pem (n starts at 0).
split_pem() {
  awk -v p="$2" '/-----BEGIN CERTIFICATE-----/{n++; f=sprintf("%s-%d.pem", p, n-1)} f{print > f} /-----END CERTIFICATE-----/{close(f); f=""}' "$1"
}

# Printable device-name rule used everywhere (also becomes a DNS label and certificate CN).
valid_device_name() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]]; }
