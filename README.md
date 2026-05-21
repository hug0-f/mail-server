# Email Server — Postfix + Dovecot 2.4.x + Let’s Encrypt (DNS‑01 via Cloudflare)

Based on documentation **"Make Your Own Raspberry Pi Email Server"**
https://www.makeuseof.com/make-your-own-raspberry-pi-email-server/

---

This project installs and configures:

- **Postfix** (SMTP: 25/465/587)
- **Dovecot 2.4.x** (IMAP/POP3: 993/995, optional POP3 110, ManageSieve 4190 in LDAP mode)
- **OpenDKIM**, **SpamAssassin** (spamd), **Fail2ban**
- **Let’s Encrypt** certificates via **Certbot** using **Cloudflare** (DNS‑01)
- **Optional LDAP backend** for virtual users — either an existing LDAP/LDAPS server, or a bundled **LLDAP** instance installed locally

Three operating modes are available, chosen via `ldap.env`:

| Mode       | Auth                          | Mailbox path                            | User provisioning              |
|------------|-------------------------------|-----------------------------------------|--------------------------------|
| *(empty)*  | PAM + system users            | `~user/Mail/Inbox/`                     | `adduser <name>`               |
| `external` | Existing LDAP/LDAPS           | `/var/vmail/<domain>/<user>/Mail/`      | In your existing directory     |
| `local`    | Bundled LLDAP (installed here)| `/var/vmail/<domain>/<user>/Mail/`      | LLDAP web UI on `:17170`       |

See [§4b LDAP integration](#4b-ldap-integration) for details.

> **Why 2.4 matters:** Dovecot **2.4** is *not* configuration‑compatible with 2.3.  
> Your `dovecot.conf` **must** begin with:
> ```
> dovecot_config_version = 2.4.x
> dovecot_storage_version = 2.4.x
> ```
> Dovecot 2.4 also introduces a new settings/variables syntax (e.g., `%n` → `%{user | username}`) and removes several legacy blocks like the old `plugin {}` usage for protocol‑scoped plugins.

---

## 0) What the scripts do (and how to resume)

The repo ships **four** scripts:

| Script                | Role                                                                                              |
|-----------------------|---------------------------------------------------------------------------------------------------|
| `install.sh`          | Orchestrator. Runs `ldap-server.sh` (if `LDAP_MODE` set) then `mail-server.sh`.                   |
| `ldap-server.sh`      | LDAP backend setup. 4 steps (0..3). Writes `/etc/mail-server/ldap.conf` consumed by mail-server.  |
| `mail-server.sh`      | Mail stack installer. 7 steps (0..6). Branches on `/etc/mail-server/ldap.conf` (system vs LDAP).  |
| `migrate-to-ldap.sh`  | One-shot migration of existing system-mode mailboxes to LDAP virtual users.                       |

All scripts are idempotent and resumable.

### `mail-server.sh` steps

- **0**: system prep (upgrade, optional purge, clean configs)
- **1**: install packages (adds LDAP packages when `/etc/mail-server/ldap.conf` says so)
- **2**: issue/renew Let’s Encrypt certificate (DNS‑01 via Cloudflare)
- **3**: configure Postfix (virtual users + LMTP if LDAP active)
- **4**: configure Dovecot 2.4 (LDAP passdb/userdb + ManageSieve + quota if LDAP active)
- **5**: configure OpenDKIM, UFW, emit DNS records (SPF/DKIM/DMARC/MX)
- **6**: enable services and Fail2ban

### `ldap-server.sh` steps

- **0**: validate `LDAP_MODE`, install packages (`ldap-utils`, `curl`, `openssl`)
- **1**: configure backend — `external` smoke-tests the connection; `local` downloads and starts LLDAP
- **2**: write the shared `/etc/mail-server/ldap.conf` (mode 640 root:root)
- **3**: create the `vmail` Unix user and `/var/vmail`

### Running the stack

Recommended path — let the orchestrator handle everything:
```bash
sudo ./install.sh
```

Force system mode (no LDAP, even if `ldap.env` has `LDAP_MODE` set):
```bash
sudo ./install.sh --skip-ldap
```

Non-interactive (CI/automation), force purge:
```bash
sudo ./install.sh --purge --yes
```

Resume from a specific step in a specific script:
```bash
sudo ./install.sh --start mail:6        # only mail-server step 6 onward
sudo ./install.sh --start ldap:2        # only ldap-server step 2 onward
```

You can also run any sub-script directly (handy after an abort):
```bash
sudo ./mail-server.sh --start-step 4
sudo ./ldap-server.sh --start-step 2
```

### Orchestrator flags

| Flag              | Effect                                                                       |
|-------------------|------------------------------------------------------------------------------|
| `--skip-ldap`     | Skip `ldap-server.sh` entirely (system mode).                                |
| `--skip-mail`     | Run `ldap-server.sh` only.                                                   |
| `--start ldap:N`  | Resume `ldap-server.sh` at step N.                                           |
| `--start mail:N`  | Resume `mail-server.sh` at step N.                                           |
| `--purge`         | Force the destructive purge in `mail-server.sh` step 0 without prompting.   |
| `--yes`, `-y`     | Skip all confirmation prompts.                                               |

> By default, `mail-server.sh` step 0 **prompts** before purging the existing mail stack. Answering "no" (or running non-interactively without `--purge`/`--yes`) skips the purge and proceeds to package install.

If a script aborts, it prints which step you can resume from.

---

## 1) Network & Host prerequisites

1. **Static public IPv4/IPv6** on the host (or static NAT with port‑forwarding).
2. **Open inbound ports** on your firewall/router: **25, 465, 587, 993** (and **110/995** if you will use POP3).
3. **Reverse DNS (PTR)** for both IPv4/IPv6 → your mail hostname (e.g., `mail.domain.tld`). Ask your provider to set PTR records.
4. **FQDN & mailname** on the host:
   ```bash
   sudo hostnamectl set-hostname mail.domain.tld
   echo "domain.tld" | sudo tee /etc/mailname
   ```
5. If you use Cloudflare DNS, ensure mail‑related hostnames (like `mail.domain.tld`) are **DNS only** (grey cloud). Proxied (orange cloud) must **not** be used for SMTP/IMAP/POP services.

---

## 2) DNS records (what you need)

Create the following at your DNS provider (Cloudflare if you follow this guide). Keep the **mail** host set to **DNS only** (not proxied).

| Type            | Name                         | Target / Value                                                 |
|-----------------|------------------------------|----------------------------------------------------------------|
| **A / AAAA**    | `mail.domain.tld`            | `<IPv4>` / `<IPv6>`                                            | 
| **MX**          | `domain.tld`                 | `mail.domain.tld` (priority 10)                                | 
| **SPF (TXT)**   | `domain.tld`                 | `"v=spf1 mx a:mail.domain.tld ip4:<IPv4> ip6:<IPv6> -all"`     | 
| **DKIM (TXT)**  | `mail._domainkey.domain.tld` | `"v=DKIM1; k=rsa; p=<your-public-DKIM-key>"`                   | 
| **DMARC (TXT)** | `_dmarc.domain.tld`          | `"v=DMARC1; p=reject; rua=mailto:postmaster@domain.tld; fo=1"` |

**Notes**
- **A / AAAA**: Point your mail subdomain to the IPv4 and IPv6 addresses of your mail server.
- **MX**: Defines the mail exchanger (destination host) for your domain.
- **SPF (TXT)**: Authorizes which hosts or IPs can send mail on behalf of your domain.
- **DKIM (TXT)**: Publishes your public DKIM key (generated on your mail server).
- **DMARC (TXT)**: Defines your DMARC policy for handling failed SPF/DKIM messages.

> After installation, the script writes the exact strings you need to `/root/dns_mail` (override with `DNS_OUTPUT_FILE`).

### Optional DNS records (SRV, TLS-RPT, CAA)

The following DNS records are **not required** for a working mail server,  
but are recommended to improve **client auto-configuration**, **security**,  
and **TLS monitoring**.

#### 1. SRV records — automatic client configuration

These allow mail clients (Thunderbird, Outlook, iOS Mail, etc.) to automatically  
detect your mail server hostname and ports (IMAP, SMTP, POP3).

| Type | Name                          | Priority | Weight | Port | Target          | Comment         |
|------|-------------------------------|----------|--------|------|-----------------|-----------------|
| SRV  | `_imap._tcp.domain.tld`       | 0        | 1      | 993  | mail.domain.tld | IMAPS           |
| SRV  | `_submission._tcp.domain.tld` | 0        | 1      | 587  | mail.domain.tld | SMTP submission |
| SRV  | `_pop3._tcp.domain.tld`       | 0        | 1      | 995  | mail.domain.tld | POP3S           |

> Set these to **DNS only** (no proxy) if you use Cloudflare.

#### 2. TLS-RPT (SMTP TLS Reporting)

TLS Reporting (TLS-RPT) helps you receive diagnostic reports about  
failed encrypted SMTP deliveries to your domain.

Create this TXT record:

| Type | Name                    | Value                                       | Comment                        |
|------|-------------------------|---------------------------------------------|--------------------------------|
| TXT  | `_smtp._tls.domain.tld` | `"v=TLSRPTv1; rua=mailto:admin@domain.tld"` | Receives TLS reports via email |

> Optional but recommended if you want visibility into mail delivery security.

#### 3. CAA records — certificate authority restriction

CAA (Certification Authority Authorization) records specify which CAs  
are allowed to issue certificates for your domain.  
They also let you define an email address to receive incident reports.

| Type | Name         | Value                               | Comment                                  |
|------|--------------|-------------------------------------|------------------------------------------|
| CAA  | `domain.tld` | `0 issue "letsencrypt.org"`         | Allow Let’s Encrypt only                 |
| CAA  | `domain.tld` | `0 iodef "mailto:admin@domain.tld"` | Send CA incident reports to this address |

> Strongly recommended for better certificate issuance control.

---

## 3) Cloudflare API token & credentials (`cloudflare.ini`)

**Create a scoped API token** in the Cloudflare Dashboard:
- Go to **My Profile → API Tokens → Create Token**.
- Use the **“Edit zone DNS”** template (or custom token).
- Permissions: **Zone → DNS → Edit** (limit to the specific zone).

**Credentials file** (default path used by the script):
```
/root/.secrets/certbot/cloudflare.ini
```
Contents:
```ini
dns_cloudflare_api_token = <YOUR_API_TOKEN>
```
Permissions:
```bash
sudo mkdir -p /root/.secrets/certbot
sudo chmod 700 /root/.secrets/certbot
sudo chmod 600 /root/.secrets/certbot/cloudflare.ini
```

> The Certbot Cloudflare plugin requires this file and enforces strict permissions.

---

## 4a) Mail environment file (`mail.env`)

Create this next to `mail-server.sh`:

```bash
# mail.env
DNS_PROVIDER=cloudflare
DNS_CREDENTIALS_FILE=/root/.secrets/certbot/cloudflare.ini
CERTBOT_EMAIL=admin@domain.tld          # required
CERT_DOMAINS="mail.domain.tld"
DNS_PROPAGATION_SECONDS=180

# Optional overrides:
# MAIL_SUBDOM=mail
# MAIL_FQDN=mail.domain.tld
# TRUSTED_NETS="10.1.0.0/16 192.168.0.0/16"
# DNS_OUTPUT_FILE=/root/dns_mail
```

### Required variables

- **`DNS_PROVIDER`** — DNS provider used by Certbot for DNS-01 challenge. Only `cloudflare` is wired today.
- **`DNS_CREDENTIALS_FILE`** — Path to the Certbot DNS plugin credentials (see §3). The script enforces `chmod 600`.
- **`CERTBOT_EMAIL`** — Email registered with Let's Encrypt for expiration notices. **Step 2 aborts if empty.** Use a real mailbox you read.
- **`CERT_DOMAINS`** — Space-separated list of hostnames included in the certificate (SAN). The first entry is used as Certbot `--cert-name` and as the canonical mail FQDN unless `MAIL_FQDN` overrides it. Example: `"mail.domain.tld autodiscover.domain.tld"`.
- **`DNS_PROPAGATION_SECONDS`** — Seconds Certbot waits for the TXT challenge record to propagate before validation. `180` is safe for Cloudflare.

### Optional overrides (commented in `mail.env.example`)

Uncomment only the variables whose defaults you want to change.

- **`MAIL_SUBDOM`** (default `mail`) — Subdomain part of the mail server FQDN **and** the DKIM selector. The DKIM DNS record is published at `${MAIL_SUBDOM}._domainkey.${domain}`. Change it only if you want a non-default selector (e.g. `k1`, `s1`) or a non-`mail` hostname.
- **`MAIL_FQDN`** (default `${MAIL_SUBDOM}.${domain}`, where `${domain}` is the content of `/etc/mailname`) — Fully-qualified hostname of the mail server. Used for Postfix `myhostname`, TLS banners, and the certificate CN. Override only if your FQDN does not follow the `<subdomain>.<domain>` pattern (rare — e.g. `mx1.eu.domain.tld`).
- **`TRUSTED_NETS`** (default empty) — Space-separated CIDR list added to OpenDKIM `TrustedHosts` alongside `127.0.0.1`. Hosts in these networks can relay mail through your server **without DKIM signing**. Leave empty unless you want to relay from your LAN. Typical home value: `"192.168.1.0/24"`.
- **`DNS_OUTPUT_FILE`** (default `/root/dns_mail`) — File where step 5 writes the SPF/DKIM/DMARC/MX records you must publish. Change only if you want the summary elsewhere.

> The package list also includes `ufw`; it is installed automatically if missing so the firewall rules added in step 5 actually take effect.

---

## 4b) LDAP integration

Even if you don't want LDAP, `ldap.env` **must exist** next to the scripts — `install.sh` errors out if it's missing. Copy the template:
```bash
cp ldap.env.example ldap.env
```

The single decision is `LDAP_MODE`:

| Value      | What happens                                                                                             |
|------------|----------------------------------------------------------------------------------------------------------|
| *(empty)*  | `install.sh` prompts you to confirm **system mode** (PAM + system users). Skipped with `--yes`.          |
| `external` | `ldap-server.sh` validates a connection to an existing LDAP/LDAPS server.                                 |
| `local`    | `ldap-server.sh` downloads and installs **LLDAP** on this host, generates an admin password.             |

### `ldap.env` variables

```bash
LDAP_MODE=external

# External LDAP
LDAP_URI=ldaps://ldap.example.com:636
LDAP_BASE_DN=dc=example,dc=com
LDAP_BIND_DN=cn=mail-reader,ou=services,dc=example,dc=com
LDAP_BIND_PW=                                    # prompted if empty
LDAP_USER_FILTER=(&(objectClass=inetOrgPerson)(mail=%u))
LDAP_USER_ATTR=mail
LDAP_TLS_CA=/etc/ssl/certs/ca-certificates.crt
LDAP_TLS_REQUIRE_CERT=demand

# Local LLDAP (only used when LDAP_MODE=local)
# LLDAP_VERSION=v0.6.3
# LLDAP_ADMIN_PASSWORD=                          # generated if empty
# LLDAP_HTTP_HOST=127.0.0.1                      # set to 0.0.0.0 to expose UI on LAN
# LLDAP_HTTP_PORT=17170
# LLDAP_LDAP_PORT=3890

# Common
# LDAP_VMAIL_UID=5000
# LDAP_QUOTA_DEFAULT=1G
```

### What changes when LDAP is active

| Aspect              | System mode              | LDAP mode                                                |
|---------------------|--------------------------|----------------------------------------------------------|
| Authentication      | PAM, system users        | LDAP bind (auth_bind), full email as login                |
| Mailbox path        | `~user/Mail/Inbox/`      | `/var/vmail/<domain>/<user>/Mail/Inbox/`                  |
| Mail owner          | each user's UID          | `vmail:vmail` (UID 5000 by default)                       |
| Local delivery      | Dovecot LDA              | Dovecot LMTP (`private/dovecot-lmtp`)                     |
| Sieve filters       | one global `default.sieve` | per-user under `~/sieve/`, global as fallback           |
| ManageSieve         | not enabled              | enabled on port 4190 (UFW opened automatically)           |
| Quota               | none                     | `1G` default (`LDAP_QUOTA_DEFAULT`); per-user override via LDAP attribute (`LDAP_QUOTA_ATTR`) |
| Sender login map    | PCRE `user@domain → user`| LDAP query on `mail` attribute                             |
| Packages added      | —                        | `dovecot-ldap`, `dovecot-lmtpd`, `dovecot-managesieved`, `postfix-ldap` |

### Local LLDAP specifics

When `LDAP_MODE=local`:

- The LLDAP `.deb` is downloaded from the official GitHub release pinned by `LLDAP_VERSION`.
- The LDAP service listens on `127.0.0.1:3890` (plain LDAP, loopback only). The web UI listens on `$LLDAP_HTTP_HOST:17170` (default `127.0.0.1`). Set `LLDAP_HTTP_HOST=0.0.0.0` in `ldap.env` to expose the UI on the LAN — the script then opens UFW port 17170 automatically. LDAPS is not enabled by default.
- The admin credentials are written to **`/root/lldap_admin`** (mode 600).
- Dovecot/Postfix bind as `uid=admin,ou=people,dc=mail,dc=local` (LLDAP's built-in admin). LLDAP does not support group-membership management via the LDAP protocol — only via GraphQL or the web UI — so a least-privilege service account would require GraphQL provisioning. Kept on the to-do list; for now the admin account is the bind identity.
- To reach the web UI from your workstation, SSH-tunnel it:
  ```bash
  ssh -L 17170:127.0.0.1:17170 youruser@mailserver
  # then open http://localhost:17170 in your browser
  ```
- Create users in the UI; the **`mail`** attribute is what Dovecot/Postfix query.

### Shared config file

`ldap-server.sh` writes **`/etc/mail-server/ldap.conf`** (mode 640 root:root) after configuring the backend. `mail-server.sh` sources this file at startup and switches to LDAP mode if `LDAP_ENABLED=1`. Do not edit it manually — re-run `ldap-server.sh` instead.

---

## 5) Install / run

On a fresh Debian 13 / Raspberry Pi, after creating `mail.env` and `ldap.env`:

```bash
chmod +x install.sh mail-server.sh ldap-server.sh migrate-to-ldap.sh
sudo ./install.sh
```

`install.sh`:
1. Verifies `ldap.env` exists; reads `LDAP_MODE`.
2. If `LDAP_MODE` is set → runs `ldap-server.sh` (creates `vmail` user, writes `/etc/mail-server/ldap.conf`, optionally installs LLDAP).
3. Runs `mail-server.sh`:
   - Upgrades packages, purges previous Postfix/Dovecot/OpenDKIM/SpamAssassin/Fail2ban/Certbot (optional, gated by a prompt).
   - Installs **Postfix, Dovecot 2.4.x, OpenDKIM, SpamAssassin, Fail2ban, Certbot, certbot‑dns‑cloudflare** (+ LDAP/LMTP/ManageSieve packages in LDAP mode).
   - Issues or renews a Let’s Encrypt certificate via Cloudflare DNS‑01 and installs a renewal hook that reloads Postfix/Dovecot.
   - Writes **Dovecot 2.4** config (single file, branched by mode).
   - Wires **Postfix↔Dovecot SASL**, **OpenDKIM** (milter), **SpamAssassin** filter. In LDAP mode: also virtual maps, LMTP transport, quota, ManageSieve.
   - Emits **SPF/DKIM/DMARC/MX** records into `/root/dns_mail` (configurable via `DNS_OUTPUT_FILE`).
4. Each sub-script can resume from any step independently — see [§0](#0-what-the-scripts-do-and-how-to-resume).

---

## 6) Dovecot 2.4 configuration — what’s different and why it’s set this way

**Required** at the top of `/etc/dovecot/dovecot.conf`:
```ini
dovecot_config_version = 2.4.1
dovecot_storage_version = 2.4.1
```
These guardrails prevent silent behavior changes and ensure storage compatibility.

**TLS / SSL** (top‑level):
```ini
ssl = yes
ssl_server_cert_file = /etc/letsencrypt/live/mail.domain.tld/fullchain.pem
ssl_server_key_file  = /etc/letsencrypt/live/mail.domain.tld/privkey.pem
ssl_min_protocol = TLSv1.2
ssl_server_prefer_ciphers = server
```
Use `ssl_server_cert_file` / `ssl_server_key_file` in Dovecot **2.4** (names differ from 2.3).

**Protocols** — keep it explicit:
```ini
protocols = imap pop3
```
You can confirm enabled protocols with:
```bash
doveconf protocols
```

**Mailbox location** — the 2.4 way:
```ini
mail_driver = maildir
mail_path = %{home}/Mail
mail_inbox_path = %{home}/Mail/Inbox
mailbox_list_layout = fs
```
In 2.4, `mail_driver`/`mail_path` are separate (replacing the old single `mail_location`). Explicit values are recommended for predictable mailbox autocreation.

**Sieve (Pigeonhole)** — enable for LDA/LMTP:
```ini
protocol lda  { mail_plugins { sieve = yes } }
protocol lmtp { mail_plugins { sieve = yes } }
```
Sieve is used to filter incoming mail (e.g., move spam to Junk).

**POP3 UIDLs** — stable format for new installs:
```ini
protocol pop3 {
  pop3_uidl_format = %{uid | hex(8)}%{uidvalidity | hex(8)}
  pop3_no_flag_updates = yes
}
```

---

## 7) Postfix highlights (what the script configures)

- **TLS** (`smtpd_tls_cert_file` / `smtpd_tls_key_file`) using the LE certs.
- **SASL** via Dovecot (`smtpd_sasl_type = dovecot`, socket at `/var/spool/postfix/private/auth`).
- **Submission (587)** and **SMTPS (465)** with authentication required.
- Basic anti‑abuse checks (HELO/sender/recipient restrictions) and SMTP smuggling hardening:
  ```ini
  smtpd_forbid_bare_newline = normalize
  smtpd_forbid_bare_newline_exclusions = $mynetworks
  ```
- **SpamAssassin** content filter path (spamc → sendmail).
- **Header hiding** (optional) to avoid leaking client IPs.

---

## 8) OpenDKIM (milter)

The script:
- Generates a selector (default: `mail`) and keys at `/etc/postfix/dkim/<domain>/`.
- Populates **KeyTable**, **SigningTable**, **TrustedHosts**.
- Adds the milter to Postfix (`smtpd_milters`, `non_smtpd_milters`).
- Writes the publishable DKIM TXT into `/root/dns_mail` (copy the full value into `<selector>._domainkey.domain.tld`).

---

## 9) SpamAssassin service name on Debian 13

Debian 12/13 commonly ship a **`spamd`** systemd unit (package `spamd`), not `spamassassin.service`.  
The script prefers enabling **`spamd.service`**, falling back to `spamassassin.service` if `spamd` is unavailable.

Check status:
```bash
systemctl status spamd || systemctl status spamassassin
```

---

## 10) Cloudflare Python library 2.20 warning (non‑blocking)

You may see a **PendingDeprecationWarning** originating from the legacy `cloudflare` Python 2.x library (version **2.20.***). Functionality is unaffected; it’s a notice ahead of a future **3.x** rewrite. The script suppresses that warning during `certbot` runs. You can:

- **Ignore** it (safe).  
- **Pin** to `cloudflare==2.19.*` if you manage a venv yourself.  
- **Upgrade** to the new **cloudflare‑python 3.x** SDK when your stack supports it.

---

## 11) Verify your installation

**Dovecot**
```bash
dovecot --version
doveconf -n
```

**Postfix**
```bash
postconf -n
```

**TLS**
```bash
openssl s_client -connect mail.domain.tld:993 -servername mail.domain.tld </dev/null | head -n2
openssl s_client -starttls smtp -connect mail.domain.tld:587 -servername mail.domain.tld </dev/null | head -n2
```

**Logs**
```bash
journalctl -u postfix -u dovecot -f
fail2ban-client status
```

**Protocols check**
```bash
doveconf protocols
# system mode: "protocols = imap pop3"
# LDAP mode:   "protocols = imap pop3 lmtp sieve"
```

**LDAP mode — verify the backend**
```bash
cat /etc/mail-server/ldap.conf | grep ^LDAP_ENABLED          # expect LDAP_ENABLED=1
doveadm user -u alice@domain.tld                              # should resolve via LDAP
postmap -q alice@domain.tld ldap:/etc/postfix/ldap-virtual-mailbox.cf
```

---

## 12) Add mail users

User provisioning depends on the mode you chose in `ldap.env`.

### 12a) System mode (no LDAP)

PAM authenticates against system users:
```bash
sudo adduser alice
# IMAP:  mail.domain.tld:993  (SSL/TLS)
# SMTP:  mail.domain.tld:587  (STARTTLS, auth required)
# User:  alice   (system account)
```
Mailbox lives under `~alice/Mail/Inbox/…` (Maildir).

**Postmaster alias** (recommended):
```bash
echo "postmaster: alice" | sudo tee -a /etc/aliases
sudo newaliases
```

### 12b) `LDAP_MODE=external`

Create the user in your existing LDAP directory. The user must have the **`mail`** attribute (matching what `LDAP_USER_FILTER` queries — `mail=%u` by default). The login is the **full email address**.

Minimal LDIF example:
```ldif
dn: uid=alice,ou=people,dc=example,dc=com
objectClass: inetOrgPerson
objectClass: person
uid: alice
cn: alice
sn: alice
mail: alice@domain.tld
userPassword: <plain or hashed>
```

The mailbox directory is auto-created on first delivery under `/var/vmail/<domain>/<user>/`.

### 12c) `LDAP_MODE=local` (LLDAP)

1. Tunnel the LLDAP UI:
   ```bash
   ssh -L 17170:127.0.0.1:17170 root@mailserver
   ```
2. Open `http://localhost:17170` and log in with the credentials in `/root/lldap_admin`.
3. **Create User** → fill `User ID`, `Email`, `Display Name`, set a password.
4. The mailbox is auto-created on first delivery.

### Migrating an existing system-mode install to LDAP

If you already have system users with mailboxes and want to switch to LDAP without losing mail:

```bash
sudo ./migrate-to-ldap.sh --dry-run    # preview
sudo ./migrate-to-ldap.sh              # apply
```

This:
- Discovers users with `~/Mail/` directories (UID 1000–60000).
- Moves their maildirs to `/var/vmail/<domain>/<user>/Mail/` and chowns `vmail:vmail`.
- Generates `/root/ldap-migration/users.ldif` and `/root/ldap-migration/passwords.txt` (both mode 600).
- Prints the import command (`ldapadd` for `external`, UI instructions for `local`).

After importing the LDIF and distributing temporary passwords, shred the file:
```bash
sudo shred -u /root/ldap-migration/passwords.txt
```

---

## 13) Client settings (examples)

- **IMAP**: `mail.domain.tld`, **993**, SSL/TLS, authentication: normal password, username = system user.  
- **SMTP (submission)**: `mail.domain.tld`, **587**, STARTTLS, authentication required.  
- **POP3** (if used): `mail.domain.tld`, **995**, SSL/TLS.

---

## 14) Troubleshooting

**Dovecot starts but config errors appear**  
Confirm the first two lines in `dovecot.conf` are set (2.4.x) and that you are using the new setting/variable names (e.g., `ssl_server_cert_file`, `%{…}` variables).

**No Inbox appears after upgrade from 2.3**  
2.4 split the old `mail_location` into driver/path settings. Set explicit:
```ini
mail_driver = maildir
mail_path = %{home}/Mail
mail_inbox_path = %{home}/Mail/Inbox
```
Then reload Dovecot.

**Mail via Cloudflare not working**  
Ensure the `mail` host is **DNS only** (not proxied).

**Cloudflare 2.20 warning during Certbot** 
It’s informational; issuance still works. Options: ignore, pin 2.19.*, or adopt the 3.x SDK later.

**SpamAssassin service errors** 
On Debian 13, prefer `spamd.service` (package `spamd`). If it’s missing, install it; otherwise fall back to `spamassassin.service`.

---

## 15) Uninstall / purge (optional)

Mail stack:
```bash
sudo systemctl stop postfix dovecot opendkim spamd spamassassin fail2ban || true
sudo apt-get purge -y --auto-remove postfix dovecot-* opendkim* spamassassin spamc spamd fail2ban certbot
sudo rm -rf /etc/dovecot /var/lib/dovecot /etc/postfix /etc/opendkim /var/lib/opendkim \
            /etc/fail2ban/jail.d/mail.local /etc/letsencrypt/renewal-hooks/deploy/reload-mail-services.sh
```

LDAP integration (if installed):
```bash
sudo systemctl disable --now lldap 2>/dev/null || true
sudo rm -f /etc/systemd/system/lldap.service
sudo rm -f /usr/local/sbin/lldap /usr/local/sbin/lldap_set_password /usr/local/sbin/lldap_migration_tool
sudo rm -rf /usr/local/share/lldap /etc/lldap /var/lib/lldap /etc/mail-server /var/vmail \
            /root/lldap_admin /root/ldap-migration
sudo userdel -r vmail  2>/dev/null || true
sudo userdel    lldap  2>/dev/null || true
sudo systemctl daemon-reload
```
## 16) SMTP Relay Configuration Guide (Postfix / Dovecot)

### 1. Overview
By default, Postfix tries to deliver mail directly to recipients' mail servers (via their MX records).  
If your IP is on a residential connection, these direct deliveries are usually blocked or marked as spam.

Using a **relay (smart host)** means Postfix sends all outgoing mail through another SMTP server that already has a good reputation.

**Flow example:**

```
Your Postfix → [Authenticated SMTP Relay] → Internet → Recipient MX
```

---

### 2. Postfix Configuration

Edit `/etc/postfix/main.cf` and add the following lines near the end of the file:

```bash
# SMTP relay configuration
relayhost = [smtp.relay.domain.com]:587

# Enable SMTP authentication for outgoing relay
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_sasl_mechanism_filter = plain, login
smtp_tls_security_level = encrypt
```

#### 2.1 Credentials file

Create the file `/etc/postfix/sasl_passwd` with your relay’s credentials:

```
[smtp.relay.domain.com]:587    username:password
```

> **Important:**  
> - Do **not** use quotes around username or password.  
> - Special characters like `@`, `!`, `#`, `$`, `%` are fine.  
> - Only avoid spaces.

Then secure and compile the file:

```bash
sudo chmod 600 /etc/postfix/sasl_passwd
sudo postmap /etc/postfix/sasl_passwd
sudo systemctl reload postfix
```

#### 2.2 Verification

Send a test email:

```bash
echo "SMTP relay test message" | mail -s "SMTP relay test" you@domain.tld
```

Check the logs:

```bash
sudo journalctl -u postfix -f
```

You should see:

```
relay=smtp.relay.domain.com[xxx.xxx.xxx.xxx]:587, status=sent (250 2.0.0 Ok: queued)
```

---

### 3. SPF considerations when using an SMTP relay

When you use an external SMTP relay to send outgoing mail, the relay’s servers deliver messages **on behalf of your domain**.
To ensure SPF and DMARC validation succeed, your domain’s SPF record must **authorize your relay’s servers**.

You may need to **add an `include:` directive** or the relay’s IP ranges to your SPF record.

#### Example syntax
```txt
v=spf1 mx a:<your-mail-server> include:<relay-provider-SPF-record> -all
```

#### Notes
- Always check your relay provider’s documentation for the correct SPF include (for example, `_spf.relaydomain.com`).
- If you use multiple relays, add each one in order:
  ```txt
  v=spf1 mx include:_spf.provider1.com include:_spf.provider2.com -all
  ```
- If you enforce a strict DMARC policy (`p=reject`), adding your relay to SPF is **mandatory**, otherwise remote mail servers will reject your messages.
- You can verify any SPF include record with:
  ```bash
  dig TXT _spf.relaydomain.com +short
  ```

---

### 4. Summary

| Purpose           | File                               | Setting                            |
|-------------------|------------------------------------|------------------------------------|
| Define relay host | `/etc/postfix/main.cf`             | `relayhost = [smtp.relay.com]:587` |
| Store credentials | `/etc/postfix/sasl_passwd`         | `[smtp.relay.com]:587 user:pass`   |
| Compile DB        | `postmap /etc/postfix/sasl_passwd` | Creates `.db` file                 |
| Reload Postfix    | `systemctl reload postfix`         | Apply config                       |
| Test delivery     | `mail -s test you@domain.tld`      | Check logs                         |

---

## References (key docs) 
**Dovecot 2.3 → 2.4 upgrade guide (required dovecot_config_version, new variables, no plugin {})**
https://doc.dovecot.org/main/installation/upgrade/2.3-to-2.4.html

**Dovecot TLS settings (ssl = yes, ssl_server_cert_file, ssl_server_key_file)**
https://doc.dovecot.org/main/core/config/ssl.html

**2.4 Mail location (mail_driver, mail_path, mail_inbox_path; autodetection exists but explicit recommended)**
https://doc.dovecot.org/2.4.0/core/config/mailbox/mail_location.html

**Sieve/Pigeonhole (plugin for LDA/LMTP)**
https://doc.dovecot.org/2.4.0/core/config/sieve/

**Protocols check (doveconf protocols)**
https://doc.dovecot.org/2.3/admin_manual/test_installation/

**Certbot Cloudflare plugin (credentials file, security)**
https://certbot-dns-cloudflare.readthedocs.io/_/downloads/en/stable/pdf/

**Cloudflare API token — Edit zone DNS template / permissions**
https://developers.cloudflare.com/fundamentals/api/get-started/create-token/

**Cloudflare mail DNS — DNS only**
https://developers.cloudflare.com/dns/manage-dns-records/how-to/email-records/

**Cloudflare Python library warning (2.20) and 3.x SDK**
https://github.com/cloudflare/python-cloudflare/releases

**Debian Trixie spamd package (service)**
https://packages.debian.org/trixie/spamd 
