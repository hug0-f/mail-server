#!/usr/bin/env bash
set -Eeuo pipefail
umask 0022

# === Argument parsing ===
START_STEP=0
ASSUME_YES=0
usage() {
  cat <<EOF
Usage: $0 [--start-step N | -s N | N] [--yes|-y]
  --start-step N   Resume from step N (0..3).
  --yes, -y        Skip confirmation prompts.
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --start-step|-s) START_STEP="${2:-0}"; shift 2 ;;
    --yes|-y)        ASSUME_YES=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    [0-9]*)          START_STEP="$1"; shift ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
if ! [[ "$START_STEP" =~ ^[0-3]$ ]]; then
  echo "Invalid start step. Must be an integer 0..3."
  exit 2
fi

if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root." >&2
  exit 1
fi

trap 'echo "ERROR: Script aborted at step ${CURRENT_STEP}. You can resume with: ./ldap-server.sh --start-step ${CURRENT_STEP}"' ERR

# === Environment ===
ENV_FILE="${ENV_FILE:-./ldap.env}"
[ -f "$ENV_FILE" ] || { echo "Error: $ENV_FILE not found." >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"

LDAP_MODE="${LDAP_MODE:-}"
LDAP_VMAIL_UID="${LDAP_VMAIL_UID:-5000}"
LDAP_QUOTA_DEFAULT="${LDAP_QUOTA_DEFAULT:-1G}"
LDAP_QUOTA_ATTR="${LDAP_QUOTA_ATTR:-}"

SHARED_CONF_DIR="/etc/mail-server"
SHARED_CONF="$SHARED_CONF_DIR/ldap.conf"

# === Step 0: prerequisites and packages ===
step0() {
  CURRENT_STEP=0
  echo "[0/3] Validating environment and installing packages..."

  case "$LDAP_MODE" in
    external|local) ;;
    "")  echo "Error: LDAP_MODE is empty. Set it to 'external' or 'local' in $ENV_FILE." >&2; exit 1 ;;
    *)   echo "Error: invalid LDAP_MODE='$LDAP_MODE'. Use 'external' or 'local'." >&2; exit 1 ;;
  esac

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ldap-utils ca-certificates curl openssl
}

# === Step 1: mode dispatch ===
step1() {
  CURRENT_STEP=1
  echo "[1/3] Configuring LDAP backend (mode=$LDAP_MODE)..."

  case "$LDAP_MODE" in
    external) configure_external ;;
    local)    install_lldap ;;
  esac
}

install_lldap() {
  : "${LLDAP_VERSION:=v0.6.3}"
  : "${LLDAP_HTTP_PORT:=17170}"
  : "${LLDAP_LDAP_PORT:=3890}"
  : "${LLDAP_LDAPS_PORT:=6360}"

  if [ -z "${LLDAP_ADMIN_PASSWORD:-}" ] && [ -f /root/lldap_admin ]; then
    LLDAP_ADMIN_PASSWORD=$(awk -F': ' '/^Password:/ {print $2; exit}' /root/lldap_admin || true)
    [ -n "${LLDAP_ADMIN_PASSWORD:-}" ] && echo "[lldap] Reusing existing admin password from /root/lldap_admin."
  fi
  if [ -z "${LLDAP_ADMIN_PASSWORD:-}" ]; then
    LLDAP_ADMIN_PASSWORD=$(openssl rand -hex 16)
    echo "[lldap] Generated new admin password."
  fi

  local arch deb_arch deb_file deb_url version_num
  arch=$(uname -m)
  case "$arch" in
    x86_64)         deb_arch=amd64 ;;
    aarch64)        deb_arch=arm64 ;;
    armv7l|armv6l)  deb_arch=armhf ;;
    *) echo "Error: unsupported arch '$arch' for LLDAP." >&2; exit 1 ;;
  esac
  version_num="${LLDAP_VERSION#v}"
  deb_file="lldap_${version_num}-1_${deb_arch}.deb"
  deb_url="https://github.com/lldap/lldap/releases/download/${LLDAP_VERSION}/${deb_file}"

  if ! dpkg -s lldap >/dev/null 2>&1; then
    echo "[lldap] Downloading $deb_url..."
    local tmp
    tmp=$(mktemp -d)
    if ! curl -fsSL -o "$tmp/$deb_file" "$deb_url"; then
      echo "Error: failed to download $deb_url" >&2
      echo "       Verify LLDAP_VERSION and asset name at https://github.com/lldap/lldap/releases" >&2
      rm -rf "$tmp"
      exit 1
    fi
    [ -s "$tmp/$deb_file" ] || { echo "Error: downloaded file is empty." >&2; rm -rf "$tmp"; exit 1; }
    apt-get install -y "$tmp/$deb_file"
    rm -rf "$tmp"
  else
    echo "[lldap] Package already installed."
  fi

  mkdir -p /etc/lldap
  local jwt_secret=""
  if [ -f /etc/lldap/lldap_config.toml ]; then
    jwt_secret=$(awk -F'"' '/^jwt_secret/ {print $2; exit}' /etc/lldap/lldap_config.toml || true)
  fi
  [ -n "$jwt_secret" ] || jwt_secret=$(openssl rand -hex 32)

  local tmp_cfg=/etc/lldap/lldap_config.toml.tmp
  (umask 0027 && cat > "$tmp_cfg" <<EOF
ldap_host = "127.0.0.1"
ldap_port = ${LLDAP_LDAP_PORT}
http_host = "127.0.0.1"
http_port = ${LLDAP_HTTP_PORT}
ldap_base_dn = "dc=mail,dc=local"
ldap_user_dn = "admin"
ldap_user_email = "admin@mail.local"
ldap_user_pass = "${LLDAP_ADMIN_PASSWORD}"
jwt_secret = "${jwt_secret}"
EOF
)
  chown root:lldap "$tmp_cfg" 2>/dev/null || true
  mv "$tmp_cfg" /etc/lldap/lldap_config.toml

  (umask 0077 && cat > /root/lldap_admin <<EOF
LLDAP admin credentials
=======================
URL:      http://127.0.0.1:${LLDAP_HTTP_PORT}
Username: admin
Password: ${LLDAP_ADMIN_PASSWORD}
EOF
)
  echo "[lldap] Admin credentials stored in /root/lldap_admin (mode 600)."

  systemctl daemon-reload
  systemctl enable lldap >/dev/null 2>&1 || true
  systemctl restart lldap

  echo "[lldap] Waiting for LLDAP to become ready..."
  local i
  for i in $(seq 1 15); do
    if ldapsearch -x -H "ldap://127.0.0.1:${LLDAP_LDAP_PORT}" \
         -D "uid=admin,ou=people,dc=mail,dc=local" -w "$LLDAP_ADMIN_PASSWORD" \
         -b "dc=mail,dc=local" -s base >/dev/null 2>&1; then
      echo "[lldap] Ready."
      break
    fi
    sleep 2
    if [ "$i" -eq 15 ]; then
      echo "Error: LLDAP did not become ready in time. Check 'journalctl -u lldap'." >&2
      exit 1
    fi
  done

  LDAP_URI="ldap://127.0.0.1:${LLDAP_LDAP_PORT}"
  LDAP_BASE_DN="dc=mail,dc=local"
  LDAP_BIND_DN="uid=admin,ou=people,dc=mail,dc=local"
  LDAP_BIND_PW="$LLDAP_ADMIN_PASSWORD"
  LDAP_USER_FILTER='(&(objectClass=person)(mail=%u))'
  LDAP_USER_ATTR="mail"
  LDAP_TLS_CA=""
  LDAP_TLS_REQUIRE_CERT="never"
  echo "[lldap] Derived LDAP variables for local backend."
}

configure_external() {
  : "${LDAP_URI:?LDAP_URI is required for external mode}"
  : "${LDAP_BASE_DN:?LDAP_BASE_DN is required for external mode}"
  : "${LDAP_BIND_DN:?LDAP_BIND_DN is required for external mode}"
  : "${LDAP_USER_FILTER:=(&(objectClass=inetOrgPerson)(mail=%u))}"
  : "${LDAP_USER_ATTR:=mail}"
  : "${LDAP_TLS_CA:=/etc/ssl/certs/ca-certificates.crt}"
  : "${LDAP_TLS_REQUIRE_CERT:=demand}"

  if [ -z "${LDAP_BIND_PW:-}" ]; then
    if [ "$ASSUME_YES" -eq 1 ]; then
      echo "Error: LDAP_BIND_PW is empty and --yes given (no interactive prompt)." >&2
      exit 1
    fi
    read -rsp "LDAP bind password for $LDAP_BIND_DN: " LDAP_BIND_PW
    echo
    [ -n "$LDAP_BIND_PW" ] || { echo "Error: empty password." >&2; exit 1; }
  fi

  echo "Testing LDAP connection to $LDAP_URI..."
  if ! LDAPTLS_CACERT="$LDAP_TLS_CA" \
       ldapsearch -x -H "$LDAP_URI" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PW" \
         -b "$LDAP_BASE_DN" -s base >/dev/null 2>&1; then
    echo "Error: LDAP bind/search failed. Check LDAP_URI, LDAP_BIND_DN, LDAP_BIND_PW, LDAP_BASE_DN, LDAP_TLS_CA." >&2
    exit 1
  fi
  echo "LDAP connection OK."
}

# === Step 2: write shared ldap.conf ===
step2() {
  CURRENT_STEP=2
  echo "[2/3] Writing $SHARED_CONF..."

  mkdir -p "$SHARED_CONF_DIR"
  chmod 755 "$SHARED_CONF_DIR"

  local tmp="$SHARED_CONF.tmp"
  {
    echo "# Generated by ldap-server.sh — do not edit manually."
    echo "LDAP_ENABLED=1"
    printf 'LDAP_MODE=%q\n'              "$LDAP_MODE"
    printf 'LDAP_URI=%q\n'               "$LDAP_URI"
    printf 'LDAP_BASE_DN=%q\n'           "$LDAP_BASE_DN"
    printf 'LDAP_BIND_DN=%q\n'           "$LDAP_BIND_DN"
    printf 'LDAP_BIND_PW=%q\n'           "$LDAP_BIND_PW"
    printf 'LDAP_USER_FILTER=%q\n'       "$LDAP_USER_FILTER"
    printf 'LDAP_USER_ATTR=%q\n'         "$LDAP_USER_ATTR"
    printf 'LDAP_TLS_CA=%q\n'            "$LDAP_TLS_CA"
    printf 'LDAP_TLS_REQUIRE_CERT=%q\n'  "$LDAP_TLS_REQUIRE_CERT"
    printf 'LDAP_VMAIL_UID=%q\n'         "$LDAP_VMAIL_UID"
    printf 'LDAP_QUOTA_DEFAULT=%q\n'     "$LDAP_QUOTA_DEFAULT"
    printf 'LDAP_QUOTA_ATTR=%q\n'        "$LDAP_QUOTA_ATTR"
  } > "$tmp"
  chmod 640 "$tmp"
  chown root:root "$tmp"
  mv "$tmp" "$SHARED_CONF"
  echo "Wrote $SHARED_CONF (mode 640)."
}

# === Step 3: vmail user and /var/vmail ===
step3() {
  CURRENT_STEP=3
  echo "[3/3] Creating vmail user and /var/vmail..."

  if ! getent group vmail >/dev/null; then
    groupadd -g "$LDAP_VMAIL_UID" vmail
  fi
  if ! id vmail >/dev/null 2>&1; then
    useradd -r -u "$LDAP_VMAIL_UID" -g vmail -d /var/vmail -s /usr/sbin/nologin vmail
  fi
  mkdir -p /var/vmail
  chown vmail:vmail /var/vmail
  chmod 770 /var/vmail
  echo "vmail user/group ready (UID=$LDAP_VMAIL_UID); /var/vmail prepared."
}

# === Run selected steps ===
for n in 0 1 2 3; do
  [ "$n" -lt "$START_STEP" ] && continue
  "step${n}"
done
