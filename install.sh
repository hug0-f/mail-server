#!/usr/bin/env bash
set -Eeuo pipefail
umask 0022

# === Argument parsing ===
SKIP_LDAP=0
SKIP_MAIL=0
START_LDAP=""
START_MAIL=""
PURGE=0
ASSUME_YES=0
usage() {
  cat <<EOF
Usage: $0 [options]
  --skip-ldap          Skip ldap-server.sh (force system mode).
  --skip-mail          Skip mail-server.sh.
  --start ldap:N       Resume ldap-server.sh at step N.
  --start mail:N       Resume mail-server.sh at step N.
  --purge              Forward --purge to mail-server.sh.
  --yes, -y            Skip confirmation prompts.
  -h, --help           Show this help.
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-ldap) SKIP_LDAP=1; shift ;;
    --skip-mail) SKIP_MAIL=1; shift ;;
    --start)
      case "${2:-}" in
        ldap:*) START_LDAP="${2#ldap:}" ;;
        mail:*) START_MAIL="${2#mail:}" ;;
        *) echo "Invalid --start target: ${2:-}" >&2; usage; exit 2 ;;
      esac
      shift 2 ;;
    --purge) PURGE=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LDAP_ENV="$SCRIPT_DIR/ldap.env"
MAIL_SCRIPT="$SCRIPT_DIR/mail-server.sh"
LDAP_SCRIPT="$SCRIPT_DIR/ldap-server.sh"

# === Root check ===
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root." >&2
  exit 1
fi

# === Validate ldap.env ===
if [ ! -f "$LDAP_ENV" ]; then
  echo "Error: $LDAP_ENV not found. Copy ldap.env.example and edit it." >&2
  exit 1
fi

# Read LDAP_MODE without sourcing the whole file.
LDAP_MODE=$(awk -F= '/^[[:space:]]*LDAP_MODE[[:space:]]*=/ { sub(/^[[:space:]]*LDAP_MODE[[:space:]]*=[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }' "$LDAP_ENV" || true)

# === Decide whether to run LDAP step ===
RUN_LDAP=0
if [ "$SKIP_LDAP" -eq 1 ]; then
  echo "[install] --skip-ldap given, running in system mode."
elif [ -z "$LDAP_MODE" ]; then
  if [ "$ASSUME_YES" -eq 1 ]; then
    echo "[install] ldap.env has empty LDAP_MODE, proceeding in system mode (--yes given)."
  else
    echo "ldap.env contains no LDAP_MODE."
    read -rp "Proceed in system mode (PAM + system users)? [y/N] " ans
    case "$ans" in
      y|Y|yes|YES) ;;
      *) echo "Aborted. Set LDAP_MODE in $LDAP_ENV or pass --skip-ldap."; exit 1 ;;
    esac
  fi
else
  RUN_LDAP=1
  echo "[install] LDAP_MODE=$LDAP_MODE"
fi

# === Run ldap-server.sh ===
if [ "$RUN_LDAP" -eq 1 ]; then
  if [ ! -x "$LDAP_SCRIPT" ]; then
    echo "Error: $LDAP_SCRIPT not found or not executable." >&2
    echo "       LDAP support is not yet implemented; pass --skip-ldap to force system mode." >&2
    exit 1
  fi
  ldap_args=()
  [ -n "$START_LDAP" ] && ldap_args+=(--start-step "$START_LDAP")
  [ "$ASSUME_YES" -eq 1 ] && ldap_args+=(--yes)
  echo "[install] running ldap-server.sh ${ldap_args[*]}"
  "$LDAP_SCRIPT" "${ldap_args[@]}"
fi

# === Run mail-server.sh ===
if [ "$SKIP_MAIL" -eq 1 ]; then
  echo "[install] --skip-mail given, done."
  exit 0
fi
if [ ! -x "$MAIL_SCRIPT" ]; then
  echo "Error: $MAIL_SCRIPT not found or not executable." >&2
  exit 1
fi
mail_args=()
[ -n "$START_MAIL" ] && mail_args+=(--start-step "$START_MAIL")
[ "$PURGE" -eq 1 ] && mail_args+=(--purge)
[ "$ASSUME_YES" -eq 1 ] && mail_args+=(--yes)
echo "[install] running mail-server.sh ${mail_args[*]}"
"$MAIL_SCRIPT" "${mail_args[@]}"
