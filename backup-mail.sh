#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

# === Argument parsing ===
OUT_DIR=/root/backups
KEEP=7
usage() {
  cat <<EOF
Usage: $0 [--output DIR] [--keep N]
  --output DIR   Destination directory (default /root/backups).
  --keep N       Keep only the last N backups (default 7; 0 disables rotation).
  -h, --help     Show this help.
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUT_DIR="$2"; shift 2 ;;
    --keep)   KEEP="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root." >&2
  exit 1
fi
[[ "$KEEP" =~ ^[0-9]+$ ]] || { echo "Error: --keep must be a non-negative integer." >&2; exit 2; }

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

stamp=$(date +%Y%m%d-%H%M%S)
tar_out="$OUT_DIR/mail-${stamp}.tar.gz"

# Consistent SQLite snapshot for LLDAP if present.
snapshot=""
if [ -f /var/lib/lldap/users.db ] && command -v sqlite3 >/dev/null 2>&1; then
  snapshot=/var/lib/lldap/users.db.snapshot
  sqlite3 /var/lib/lldap/users.db ".backup '$snapshot'"
fi

# === Tar ===
PATHS=(
  /var/vmail
  /var/lib/lldap
  /etc/mail-server
  /etc/dovecot
  /etc/postfix
  /etc/opendkim
  /etc/lldap
  /etc/aliases
  /root/lldap_admin
)
EXISTING=()
for p in "${PATHS[@]}"; do
  [ -e "$p" ] && EXISTING+=("$p")
done

if [ "${#EXISTING[@]}" -eq 0 ]; then
  echo "Nothing to back up (no expected paths found)."
  [ -n "$snapshot" ] && rm -f "$snapshot"
  exit 0
fi

tar czf "$tar_out" \
  --ignore-failed-read \
  --exclude='/var/vmail/*/*/Mail/*/tmp/*' \
  "${EXISTING[@]}" 2>/dev/null || true

[ -n "$snapshot" ] && rm -f "$snapshot"

chmod 600 "$tar_out"

# === Rotation ===
if [ "$KEEP" -gt 0 ]; then
  mapfile -t old < <(find "$OUT_DIR" -maxdepth 1 -name 'mail-*.tar.gz' -type f -printf '%T@\t%p\n' \
                       | sort -nr | tail -n +$((KEEP + 1)) | cut -f2-)
  for f in "${old[@]:-}"; do
    [ -n "$f" ] && rm -f "$f" && echo "Rotated out: $f"
  done
fi

size=$(du -h "$tar_out" | cut -f1)
echo "Backup written: $tar_out ($size)"
