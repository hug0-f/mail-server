#!/usr/bin/env bash
set -Eeuo pipefail
umask 0022

# === Argument parsing ===
START_STEP=0
PURGE=0
ASSUME_YES=0
usage() {
  cat <<EOF
Usage: $0 [--start-step N | -s N | N] [--purge] [--yes|-y]
  --start-step N   Resume from step N (0..6).
  --purge          Force purge in step 0 without prompting.
  --yes, -y        Skip confirmation prompts (purges without asking).
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --start-step|-s) START_STEP="${2:-0}"; shift 2 ;;
    --purge)         PURGE=1; shift ;;
    --yes|-y)        ASSUME_YES=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    [0-9]*)          START_STEP="$1"; shift ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
if ! [[ "$START_STEP" =~ ^[0-6]$ ]]; then
  echo "Invalid start step. Must be an integer 0..6."
  exit 2
fi

trap 'echo "ERROR: Script aborted at step ${CURRENT_STEP}. You can resume with: ./mail-server.sh --start-step ${CURRENT_STEP}"' ERR

# === Helpers ===
has_unit() { systemctl list-unit-files --type=service --no-pager 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }
enable_now_if_exists() { if has_unit "$1"; then systemctl enable --now "$1"; else echo "Note: service $1 not found, skipping enable."; fi; }
restart_if_exists() { systemctl restart "$1" 2>/dev/null || true; }
ufw_allow() { command -v ufw >/dev/null 2>&1 && ufw allow "$1" 2>/dev/null || true; }

write_postfix_ldap_cf() {
  local out="$1" filter="$2" attr="$3"
  local tls_req=no
  case "${LDAP_TLS_REQUIRE_CERT:-}" in demand|hard) tls_req=yes ;; esac
  local tmp="$out.tmp"
  (umask 0027 && {
    printf 'server_host = %s\n'      "$LDAP_URI"
    printf 'version = 3\n'
    printf 'search_base = %s\n'      "$LDAP_BASE_DN"
    printf 'query_filter = %s\n'     "$filter"
    printf 'result_attribute = %s\n' "$attr"
    printf 'bind = yes\n'
    printf 'bind_dn = %s\n'          "$LDAP_BIND_DN"
    printf 'bind_pw = %s\n'          "$LDAP_BIND_PW"
    printf 'tls_ca_cert_file = %s\n' "$LDAP_TLS_CA"
    printf 'tls_require_cert = %s\n' "$tls_req"
  } > "$tmp")
  chown root:postfix "$tmp"
  mv "$tmp" "$out"
}

# === Environment ===
ENV_FILE="${ENV_FILE:-./mail-server.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

domain="$(cat /etc/mailname)"
subdom="${MAIL_SUBDOM:-mail}"
maildomain="${MAIL_FQDN:-$subdom.$domain}"

cert_domains="${CERT_DOMAINS:-$maildomain}"
cert_primary="${cert_domains%% *}"
certdir="/etc/letsencrypt/live/${cert_primary}"

dns_provider="${DNS_PROVIDER:-cloudflare}"
dns_credentials_file="${DNS_CREDENTIALS_FILE:-/root/.secrets/certbot/cloudflare.ini}"
dns_propagation_seconds="${DNS_PROPAGATION_SECONDS:-180}"
certbot_email="${CERTBOT_EMAIL:-}"

trusted_nets="${TRUSTED_NETS:-}"
dns_out="${DNS_OUTPUT_FILE:-/root/dns_mail}"

# === LDAP integration (loaded from ldap-server.sh output if present) ===
LDAP_SHARED_CONF="/etc/mail-server/ldap.conf"
LDAP_ENABLED=0
if [ -f "$LDAP_SHARED_CONF" ]; then
  # shellcheck disable=SC1090
  . "$LDAP_SHARED_CONF"
fi

install_packages="postfix postfix-pcre dovecot-imapd dovecot-pop3d dovecot-sieve \
opendkim opendkim-tools spamassassin spamc spamd fail2ban bind9-host ufw \
certbot python3-certbot-dns-cloudflare"
if [ "$LDAP_ENABLED" = "1" ]; then
  install_packages="$install_packages dovecot-ldap dovecot-lmtpd dovecot-managesieved postfix-ldap"
fi

# === Step 0: system preparation ===
step0() {
  CURRENT_STEP=0
  echo "[0/6] System preparation (update, purge, cleanup)..."

  if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get full-upgrade -y
  apt-get autoremove -y
  apt-get autoclean -y

  if [ "$PURGE" -ne 1 ] && [ "$ASSUME_YES" -ne 1 ]; then
    echo "Step 0 will PURGE postfix/dovecot/opendkim/spamassassin/fail2ban/certbot and wipe their config directories."
    read -rp "Proceed with purge? [y/N] " ans
    case "$ans" in
      y|Y|yes|YES) ;;
      *) echo "Skipping purge (use --purge or --yes to skip this prompt)."; arch=$(uname -m); echo "Architecture: ${arch}"; return ;;
    esac
  fi

  echo "Stopping any running mail-related services..."
  systemctl stop postfix dovecot opendkim spamassassin spamd fail2ban 2>/dev/null || true

  echo "Purging previous mail stack (if any)..."
  apt-get purge -y --auto-remove postfix dovecot-core dovecot-imapd dovecot-pop3d dovecot-sieve \
    dovecot-lmtpd dovecot-managesieved opendkim opendkim-tools spamassassin spamc spamd fail2ban certbot || true
  apt-get clean

  echo "Cleaning legacy configuration directories..."
  rm -rf /etc/dovecot /var/lib/dovecot /etc/postfix /etc/opendkim /var/lib/opendkim \
         /etc/fail2ban/jail.d/mail.local /etc/letsencrypt/renewal-hooks/deploy/reload-mail-services.sh

  arch=$(uname -m)
  echo "Architecture: ${arch}"
}

# === Step 1: install packages ===
step1() {
  CURRENT_STEP=1
  echo "[1/6] Installing required packages..."
  apt-get update -y
  systemctl -q stop dovecot postfix || true
  # shellcheck disable=SC2086
  apt-get install -y $install_packages
}

# === Step 2: Let's Encrypt certificate (DNS-01) ===
step2() {
  CURRENT_STEP=2
  echo "[2/6] Issuing/renewing Let's Encrypt certificate (DNS-${dns_provider})..."

  mkdir -p "$(dirname "$dns_credentials_file")"
  chmod 700 "$(dirname "$dns_credentials_file")"
  [ -f "$dns_credentials_file" ] || { echo "Error: Cloudflare credentials file not found: $dns_credentials_file" >&2; exit 1; }
  chmod 600 "$dns_credentials_file"

  [ -n "$certbot_email" ] || { echo "Error: CERTBOT_EMAIL is required in $ENV_FILE (used by Let's Encrypt for expiration notices)." >&2; exit 1; }

  local domain_flags=""
  for d in $cert_domains; do domain_flags="$domain_flags -d $d"; done

  # Suppress non-blocking PendingDeprecationWarning from python 'cloudflare' 2.20.* (see README §10).
  if [ ! -s "$certdir/fullchain.pem" ] || [ ! -s "$certdir/privkey.pem" ]; then
    PYTHONWARNINGS="${PYTHONWARNINGS:-ignore:PendingDeprecationWarning}" \
    certbot certonly --non-interactive --agree-tos \
      --cert-name "${cert_primary}" \
      --dns-cloudflare --dns-cloudflare-credentials "$dns_credentials_file" \
      --dns-cloudflare-propagation-seconds "$dns_propagation_seconds" \
      --email "$certbot_email" $domain_flags
  fi

  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/reload-mail-services.sh <<'EOF'
#!/bin/sh
systemctl reload postfix 2>/dev/null || systemctl restart postfix
systemctl reload dovecot 2>/dev/null || systemctl restart dovecot
EOF
  chmod 700 /etc/letsencrypt/renewal-hooks/deploy/reload-mail-services.sh
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true

  [ -s "$certdir/fullchain.pem" ] || { echo "Certificate missing: $certdir/fullchain.pem"; exit 1; }
  [ -s "$certdir/privkey.pem" ]   || { echo "Private key missing: $certdir/privkey.pem"; exit 1; }
}

# === Step 3: Postfix ===
step3() {
  CURRENT_STEP=3
  echo "[3/6] Configuring Postfix (LDAP=$LDAP_ENABLED)..."

  postconf -e "myhostname = $maildomain"
  postconf -e "mail_name = $domain"
  postconf -e "mydomain = $domain"

  if [ "$LDAP_ENABLED" = "1" ]; then
    postconf -e 'mydestination = $myhostname, localhost.localdomain, localhost'
  else
    postconf -e 'mydestination = $myhostname, $mydomain, mail, localhost.localdomain, localhost, localhost.$mydomain'
  fi

  postconf -e "smtpd_tls_cert_file = $certdir/fullchain.pem"
  postconf -e "smtpd_tls_key_file  = $certdir/privkey.pem"
  postconf -e 'smtpd_tls_security_level = may'
  postconf -e 'smtp_tls_security_level  = may'
  postconf -e 'smtpd_tls_auth_only = yes'

  postconf -e 'smtpd_sasl_auth_enable = yes'
  postconf -e 'smtpd_sasl_type = dovecot'
  postconf -e 'smtpd_sasl_path = private/auth'
  postconf -e 'smtpd_sasl_security_options = noanonymous, noplaintext'
  postconf -e 'smtpd_sasl_tls_security_options = noanonymous'

  local sender_login_map_ref
  if [ "$LDAP_ENABLED" = "1" ]; then
    write_postfix_ldap_cf /etc/postfix/ldap-sender-login.cf    "$LDAP_USER_FILTER" "$LDAP_USER_ATTR"
    write_postfix_ldap_cf /etc/postfix/ldap-virtual-mailbox.cf "$LDAP_USER_FILTER" "$LDAP_USER_ATTR"
    sender_login_map_ref="ldap:/etc/postfix/ldap-sender-login.cf"
    postconf -e "smtpd_sender_login_maps = $sender_login_map_ref"
    postconf -e 'virtual_mailbox_domains = $mydomain'
    postconf -e "virtual_mailbox_maps = ldap:/etc/postfix/ldap-virtual-mailbox.cf"
    postconf -e "virtual_mailbox_base = /var/vmail"
    postconf -e "virtual_uid_maps = static:$LDAP_VMAIL_UID"
    postconf -e "virtual_gid_maps = static:$LDAP_VMAIL_UID"
    postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"
    postconf -X home_mailbox 2>/dev/null || true
  else
    sender_login_map_ref="pcre:/etc/postfix/login_maps.pcre"
    postconf -e "smtpd_sender_login_maps = $sender_login_map_ref"
    postconf -e 'home_mailbox = Mail/Inbox/'
    echo "/^(.*)@$(printf '%s' "$domain" | sed 's/\./\\./g')$/   \${1}" > /etc/postfix/login_maps.pcre
  fi

  postconf -e 'smtpd_sender_restrictions = reject_sender_login_mismatch, permit_sasl_authenticated, permit_mynetworks, reject_unknown_reverse_client_hostname, reject_unknown_sender_domain'
  postconf -e 'smtpd_recipient_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination, reject_unknown_recipient_domain'
  postconf -e 'smtpd_relay_restrictions = permit_sasl_authenticated, reject_unauth_destination'
  postconf -e 'smtpd_helo_required = yes'
  postconf -e 'smtpd_helo_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_invalid_helo_hostname, reject_non_fqdn_helo_hostname, reject_unknown_helo_hostname'

  echo "/^Received:.*/     IGNORE
/^X-Originating-IP:/    IGNORE" > /etc/postfix/header_checks
  postconf -e "header_checks = regexp:/etc/postfix/header_checks"

  awk '
    /^[a-zA-Z]/ {
      skip = ($1 == "smtp" || $1 == "smtps" || $1 == "submission" || $1 == "spamassassin") ? 1 : 0
    }
    !skip { print }
  ' /etc/postfix/master.cf > /etc/postfix/master.cf.new && mv /etc/postfix/master.cf.new /etc/postfix/master.cf
  cat >>/etc/postfix/master.cf <<EOF
smtp      inet  n       -       y       -       -       smtpd
  -o content_filter=spamassassin
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_tls_auth_only=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_sender_restrictions=reject_sender_login_mismatch
  -o smtpd_sender_login_maps=$sender_login_map_ref
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject_unauth_destination
smtps     inet  n       -       y       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes

spamassassin unix -     n       n       -       -       pipe
  user=debian-spamd argv=/usr/bin/spamc -f -e /usr/sbin/sendmail -oi -f \${sender} \${recipient}
EOF

  postconf -e 'smtpd_forbid_bare_newline = normalize'
  postconf -e 'smtpd_forbid_bare_newline_exclusions = $mynetworks'
}

# === Step 4: Dovecot 2.4 ===
dovecot_system_conf() {
  cat > /etc/dovecot/dovecot.conf <<EOF
dovecot_config_version = 2.4.1
dovecot_storage_version = 2.4.1

ssl = yes
ssl_server_cert_file = $certdir/fullchain.pem
ssl_server_key_file  = $certdir/privkey.pem
ssl_min_protocol = TLSv1.2
ssl_server_prefer_ciphers = server

auth_mechanisms = plain login
auth_allow_cleartext = no
auth_username_format = %{user | username}

protocols = imap pop3

userdb system { driver = passwd }
passdb default { driver = pam }

mail_driver = maildir
mail_path = %{home}/Mail
mail_inbox_path = %{home}/Mail/Inbox
mailbox_list_layout = fs

namespace inbox {
  inbox = yes
  mailbox Drafts  { special_use = \Drafts  ; auto = subscribe }
  mailbox Junk    { special_use = \Junk    ; auto = subscribe ; autoexpunge = 30d }
  mailbox Sent    { special_use = \Sent    ; auto = subscribe }
  mailbox Trash   { special_use = \Trash   ; auto = subscribe }
  mailbox Archive { special_use = \Archive ; auto = create    }
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}

protocol lda  { mail_plugins { sieve = yes } }
protocol lmtp { mail_plugins { sieve = yes } }

protocol pop3 {
  pop3_uidl_format = %{uid | hex(8)}%{uidvalidity | hex(8)}
  pop3_no_flag_updates = yes
}
EOF
}

dovecot_ldap_conf() {
  local tls_req=no
  case "${LDAP_TLS_REQUIRE_CERT:-}" in demand|hard) tls_req=hard ;; esac
  local tmp=/etc/dovecot/dovecot-ldap.conf.ext.tmp
  (umask 0027 && cat > "$tmp" <<EOF
uris = $LDAP_URI
auth_bind = yes
dn = $LDAP_BIND_DN
dnpass = $LDAP_BIND_PW
base = $LDAP_BASE_DN
user_filter = $LDAP_USER_FILTER
pass_filter = $LDAP_USER_FILTER
tls_ca_cert_file = $LDAP_TLS_CA
tls_require_cert = $tls_req
EOF
)
  chown root:dovecot "$tmp"
  mv "$tmp" /etc/dovecot/dovecot-ldap.conf.ext

  cat > /etc/dovecot/dovecot.conf <<EOF
dovecot_config_version = 2.4.1
dovecot_storage_version = 2.4.1

ssl = yes
ssl_server_cert_file = $certdir/fullchain.pem
ssl_server_key_file  = $certdir/privkey.pem
ssl_min_protocol = TLSv1.2
ssl_server_prefer_ciphers = server

auth_mechanisms = plain login
auth_allow_cleartext = no

protocols = imap pop3 lmtp sieve

passdb ldap {
  driver = ldap
  args = /etc/dovecot/dovecot-ldap.conf.ext
}
userdb ldap {
  driver = ldap
  args = /etc/dovecot/dovecot-ldap.conf.ext
}

mail_driver = maildir
mail_uid = vmail
mail_gid = vmail
mail_home = /var/vmail/%{user | domain}/%{user | username}
mail_path = ~/Mail
mail_inbox_path = ~/Mail/Inbox
mailbox_list_layout = fs

namespace inbox {
  inbox = yes
  mailbox Drafts  { special_use = \Drafts  ; auto = subscribe }
  mailbox Junk    { special_use = \Junk    ; auto = subscribe ; autoexpunge = 30d }
  mailbox Sent    { special_use = \Sent    ; auto = subscribe }
  mailbox Trash   { special_use = \Trash   ; auto = subscribe }
  mailbox Archive { special_use = \Archive ; auto = create    }
}

mail_plugins = \$mail_plugins quota

plugin {
  quota = count:User quota
  quota_status_success = DUNNO
  quota_status_nouser = DUNNO
  quota_status_overquota = "552 5.2.2 Mailbox full"
  quota_grace = 10%%
  quota_rule = *:storage=$LDAP_QUOTA_DEFAULT

  sieve = file:~/sieve;active=~/.dovecot.sieve
  sieve_default = /var/lib/dovecot/sieve/default.sieve
  sieve_default_name = default
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}

service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}

service managesieve-login {
  inet_listener sieve {
    port = 4190
  }
}

protocol lmtp { mail_plugins { sieve = yes ; quota = yes } }
protocol imap { mail_plugins { quota = yes ; imap_quota = yes } }

protocol pop3 {
  pop3_uidl_format = %{uid | hex(8)}%{uidvalidity | hex(8)}
  pop3_no_flag_updates = yes
}
EOF
}

step4() {
  CURRENT_STEP=4
  echo "[4/6] Configuring Dovecot 2.4 (LDAP=$LDAP_ENABLED)..."
  if [ -f /etc/dovecot/dovecot.conf ]; then
    mv /etc/dovecot/dovecot.conf /etc/dovecot/dovecot.conf.bak
  fi

  if [ "$LDAP_ENABLED" = "1" ]; then
    dovecot_ldap_conf
  else
    dovecot_system_conf
  fi

  mkdir -p /var/lib/dovecot/sieve
  cat >/var/lib/dovecot/sieve/default.sieve <<'EOF'
require ["fileinto", "mailbox"];
if header :contains "X-Spam-Flag" "YES" {
  fileinto "Junk";
  stop;
}
EOF
  sievec /var/lib/dovecot/sieve/default.sieve || true
}

# === Step 5: OpenDKIM and DNS records ===
step5() {
  CURRENT_STEP=5
  echo "[5/6] Configuring OpenDKIM and generating DNS records..."

  mkdir -p "/etc/postfix/dkim/$domain"
  if [ ! -f "/etc/postfix/dkim/$domain/$subdom.private" ]; then
    opendkim-genkey -D "/etc/postfix/dkim/$domain" -d "$domain" -s "$subdom"
    chgrp -R opendkim /etc/postfix/dkim/*
    chmod -R g+r /etc/postfix/dkim/*
  fi

  grep -q "$domain" /etc/postfix/dkim/keytable 2>/dev/null || \
    echo "$subdom._domainkey.$domain $domain:$subdom:/etc/postfix/dkim/$domain/$subdom.private" >> /etc/postfix/dkim/keytable
  grep -q "$domain" /etc/postfix/dkim/signingtable 2>/dev/null || \
    echo "*@$domain $subdom._domainkey.$domain" >> /etc/postfix/dkim/signingtable
  if [ ! -f /etc/postfix/dkim/trustedhosts ] || ! grep -q '127.0.0.1' /etc/postfix/dkim/trustedhosts; then
    {
      echo "127.0.0.1"
      for net in $trusted_nets; do echo "$net"; done
    } >> /etc/postfix/dkim/trustedhosts
  fi

  grep -q '^KeyTable' /etc/opendkim.conf 2>/dev/null || cat >>/etc/opendkim.conf <<'EOF'
KeyTable           file:/etc/postfix/dkim/keytable
SigningTable       refile:/etc/postfix/dkim/signingtable
InternalHosts      refile:/etc/postfix/dkim/trustedhosts
Socket             inet:12301@localhost
EOF
  sed -i '/^SOCKET/d' /etc/default/opendkim && echo 'SOCKET="inet:12301@localhost"' >> /etc/default/opendkim

  postconf -e 'milter_default_action = accept'
  postconf -e 'milter_protocol = 6'
  postconf -e 'smtpd_milters = inet:localhost:12301'
  postconf -e 'non_smtpd_milters = inet:localhost:12301'

  if [ "$LDAP_ENABLED" = "1" ]; then
    postconf -X mailbox_command 2>/dev/null || true
  else
    postconf -e 'mailbox_command = /usr/lib/dovecot/dovecot-lda'
  fi

  for port in 25 465 587 993 110 995 4190; do ufw_allow "$port"; done

  ipv4=$(host "$domain" | grep -m1 -Eo '([0-9]+\.){3}[0-9]+') || true
  ipv6=$(host "$domain" | awk '/IPv6/{print $NF; exit}') || true

  # Concatenate all double-quoted segments from opendkim-genkey output to get the full TXT value.
  dkim_value=$(awk -F'"' '{for(i=2;i<=NF;i+=2) printf "%s", $i}' "/etc/postfix/dkim/$domain/$subdom.txt")

  dkim="$subdom._domainkey.$domain	TXT	$dkim_value"
  dmarc="_dmarc.$domain	        TXT	v=DMARC1; p=reject; rua=mailto:postmaster@$domain; fo=1"
  spf="$domain	                TXT	v=spf1 mx a:$maildomain ${ipv4:+ip4:$ipv4} ${ipv6:+ip6:$ipv6} -all"
  mx="$domain	                MX	10	$maildomain	300"

  printf "NOTE: Add the following DNS records (order may vary):\n%s\n%s\n%s\n%s\n" \
    "$dkim" "$dmarc" "$spf" "$mx" > "$dns_out"
  echo "DNS records written to $dns_out"
}

# === Step 6: services and Fail2ban ===
step6() {
  CURRENT_STEP=6
  echo "[6/6] Enabling services and Fail2ban..."

  [ ! -f /etc/fail2ban/jail.d/mail.local ] && cat >/etc/fail2ban/jail.d/mail.local <<'EOF'
[postfix]
enabled = true
[postfix-sasl]
enabled = true
[sieve]
enabled = true
[dovecot]
enabled = true
EOF
  sed -i 's/^backend = auto$/backend = systemd/' /etc/fail2ban/jail.conf || true

  systemctl daemon-reload

  enable_now_if_exists opendkim.service

  if has_unit spamd.service; then
    enable_now_if_exists spamd.service
  else
    enable_now_if_exists spamassassin.service
  fi

  enable_now_if_exists dovecot.service
  enable_now_if_exists postfix.service
  enable_now_if_exists fail2ban.service

  echo "Installation complete.

Quick checks:
  doveconf -n
  postconf -n
  openssl s_client -connect $maildomain:993 -servername $cert_primary </dev/null | head -n2
  journalctl -u dovecot -u postfix -f

  sudo systemctl restart dovecot postfix
"
}

# === Run selected steps ===
for n in 0 1 2 3 4 5 6; do
  [ "$n" -lt "$START_STEP" ] && continue
  "step${n}"
done
