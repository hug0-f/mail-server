#!/usr/bin/env bash
set -uo pipefail

EXIT=0
FAIL() { echo "[FAIL] $*"; EXIT=1; }
WARN() { echo "[WARN] $*"; }
OK()   { echo "[ OK ] $*"; }

# === Environment ===
DOMAIN=$(cat /etc/mailname 2>/dev/null || echo "")
[ -n "$DOMAIN" ] || { FAIL "/etc/mailname is missing or empty"; }

LDAP_SHARED_CONF="/etc/mail-server/ldap.conf"
LDAP_ENABLED=0
if [ -f "$LDAP_SHARED_CONF" ]; then
  # shellcheck disable=SC1090
  . "$LDAP_SHARED_CONF"
fi

# === Services ===
SERVICES=(postfix dovecot opendkim fail2ban)
if systemctl list-unit-files spamd.service >/dev/null 2>&1; then SERVICES+=(spamd); else SERVICES+=(spamassassin); fi
[ "${LDAP_ENABLED:-0}" = "1" ] && [ "${LDAP_MODE:-}" = "local" ] && SERVICES+=(lldap)

for svc in "${SERVICES[@]}"; do
  if systemctl is-active --quiet "$svc"; then OK "service $svc active"; else FAIL "service $svc not active"; fi
done

# === Configs ===
if postconf -n >/dev/null 2>&1; then OK "postconf -n parses"; else FAIL "postconf -n errors"; fi
if doveconf -n >/dev/null 2>&1; then OK "doveconf -n parses"; else FAIL "doveconf -n errors"; fi

# === Certificate ===
CERT=$(postconf -h smtpd_tls_cert_file 2>/dev/null || echo "")
if [ -n "$CERT" ] && [ -s "$CERT" ]; then
  expiry_epoch=$(date -d "$(openssl x509 -enddate -noout -in "$CERT" | cut -d= -f2)" +%s 2>/dev/null || echo 0)
  now=$(date +%s)
  days_left=$(( (expiry_epoch - now) / 86400 ))
  if   [ "$days_left" -lt 0 ];   then FAIL "certificate expired ($CERT)"
  elif [ "$days_left" -lt 14 ];  then WARN "certificate expires in $days_left days ($CERT)"
  else OK "certificate valid for $days_left days"
  fi
else
  FAIL "certificate file missing: $CERT"
fi

# === Listening ports ===
EXPECTED_PORTS=(25 465 587 993 995)
[ "${LDAP_ENABLED:-0}" = "1" ] && EXPECTED_PORTS+=(4190)
for port in "${EXPECTED_PORTS[@]}"; do
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":${port}\$"; then
    OK "port $port listening"
  else
    FAIL "port $port not listening"
  fi
done

# === LDAP ===
if [ "${LDAP_ENABLED:-0}" = "1" ]; then
  if LDAPTLS_CACERT="${LDAP_TLS_CA:-/etc/ssl/certs/ca-certificates.crt}" \
       ldapsearch -x -H "$LDAP_URI" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PW" \
         -b "$LDAP_BASE_DN" -s base >/dev/null 2>&1; then
    OK "LDAP bind+search works ($LDAP_URI)"
  else
    FAIL "LDAP bind/search failed ($LDAP_URI)"
  fi

  if [ -d /var/vmail ]; then
    owner=$(stat -c '%U:%G' /var/vmail)
    mode=$(stat -c '%a' /var/vmail)
    [ "$owner" = "vmail:vmail" ] || FAIL "/var/vmail owner is $owner (expected vmail:vmail)"
    [ "$mode" = "770" ]          || WARN "/var/vmail mode is $mode (expected 770)"
    [ "$owner" = "vmail:vmail" ] && [ "$mode" = "770" ] && OK "/var/vmail layout OK"
  else
    FAIL "/var/vmail missing"
  fi
fi

# === Reverse DNS (PTR) ===
MAILDOMAIN=$(postconf -h myhostname 2>/dev/null || echo "")
if [ -n "$MAILDOMAIN" ]; then
  for ip in $(host "$MAILDOMAIN" 2>/dev/null | awk '/has (IPv6 )?address/ {print $NF}'); do
    ptr=$(host "$ip" 2>/dev/null | awk '/pointer/ {sub(/\.$/,"",$NF); print $NF}' | head -1)
    if [ -z "$ptr" ]; then
      WARN "no PTR record for $ip (deliverability may suffer)"
    elif [ "$ptr" = "$MAILDOMAIN" ]; then
      OK "PTR for $ip -> $ptr"
    else
      WARN "PTR for $ip is $ptr (expected $MAILDOMAIN)"
    fi
  done
fi

# === Summary ===
echo
[ "$EXIT" -eq 0 ] && echo "All checks passed." || echo "One or more checks failed."
exit "$EXIT"
