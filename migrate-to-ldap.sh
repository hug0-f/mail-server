#!/usr/bin/env bash
set -Eeuo pipefail
umask 0022

# === Argument parsing ===
DRY_RUN=0
usage() {
  cat <<EOF
Usage: $0 [--dry-run]
  --dry-run    Preview actions without writing files or moving maildirs.
  -h, --help   Show this help.
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# === Preflight ===
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root." >&2
  exit 1
fi

LDAP_SHARED_CONF="/etc/mail-server/ldap.conf"
if [ ! -f "$LDAP_SHARED_CONF" ]; then
  echo "Error: $LDAP_SHARED_CONF not found. Run ldap-server.sh first." >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$LDAP_SHARED_CONF"
if [ "${LDAP_ENABLED:-0}" != "1" ]; then
  echo "Error: LDAP_ENABLED is not 1 in $LDAP_SHARED_CONF." >&2
  exit 1
fi

id vmail >/dev/null 2>&1 || { echo "Error: vmail user not found. Run ldap-server.sh step 3 first." >&2; exit 1; }
[ -d /var/vmail ]        || { echo "Error: /var/vmail not found." >&2; exit 1; }

domain=$(cat /etc/mailname)

OUT_DIR=/root/ldap-migration
LDIF="$OUT_DIR/users.ldif"
PWFILE="$OUT_DIR/passwords.txt"

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

# === Discover users ===
mapfile -t users < <(awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' /etc/passwd)

count=0
if [ "$DRY_RUN" -eq 0 ]; then
  : > "$LDIF"
  : > "$PWFILE"
  chmod 600 "$LDIF" "$PWFILE"
fi

for user in "${users[@]}"; do
  src="/home/${user}/Mail"
  [ -d "$src" ] || continue

  email="${user}@${domain}"
  dst_parent="/var/vmail/${domain}/${user}"
  dst="${dst_parent}/Mail"
  pw=$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-16)
  count=$((count + 1))

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] $user: would create LDAP entry for $email and move $src -> $dst"
    continue
  fi

  cat >>"$LDIF" <<EOF
dn: uid=${user},ou=people,${LDAP_BASE_DN}
objectClass: inetOrgPerson
objectClass: person
uid: ${user}
cn: ${user}
sn: ${user}
mail: ${email}
userPassword: ${pw}

EOF
  printf '%s\t%s\n' "$email" "$pw" >>"$PWFILE"

  if [ -d "$dst" ]; then
    echo "[skip] $dst already exists; not moving $src."
  else
    mkdir -p "$dst_parent"
    mv "$src" "$dst"
    echo "[move] $src -> $dst"
  fi
  chown -R vmail:vmail "$dst_parent"
done

if [ "$count" -eq 0 ]; then
  echo "No users with ~/Mail directories found. Nothing to migrate."
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run done. $count user(s) would be migrated. Re-run without --dry-run to apply."
  exit 0
fi

echo
echo "Migration done. $count user(s) processed."
echo "Files generated (mode 600):"
echo "  $LDIF"
echo "  $PWFILE"
echo
case "${LDAP_MODE:-external}" in
  local)
    cat <<EOF
Next steps (LLDAP local mode):
  1. Review $LDIF before importing.
  2. Import using the LLDAP admin (mail-reader is read-only):
       ldapadd -x -H $LDAP_URI -D uid=admin,ou=people,$LDAP_BASE_DN -W -f $LDIF
     (Admin password is in /root/lldap_admin. LLDAP will hash userPassword on insert.)
  3. Distribute the temporary passwords from $PWFILE, then:
       shred -u $PWFILE
EOF
    ;;
  *)
    cat <<EOF
Next steps:
  1. Review $LDIF and adjust attributes for your schema if needed.
  2. Import into LDAP:
       ldapadd -x -H $LDAP_URI -D $LDAP_BIND_DN -W -f $LDIF
     (-W prompts for the bind password.)
  3. Distribute the temporary passwords from $PWFILE to each user.
  4. After distribution, securely delete the file:
       shred -u $PWFILE
EOF
    ;;
esac
