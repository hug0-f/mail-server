# Email Server — Postfix + Dovecot 2.4.x + Let’s Encrypt (DNS‑01 via Cloudflare)

Based on documentation **"Make Your Own Raspberry Pi Email Server""**: https://www.makeuseof.com/make-your-own-raspberry-pi-email-server/

---

This project installs and configures:

- **Postfix** (SMTP: 25/465/587)
- **Dovecot 2.4.x** (IMAP/POP3: 993/995, optional POP3 110)
- **OpenDKIM**, **SpamAssassin** (spamd), **Fail2ban**
- **Let’s Encrypt** certificates via **Certbot** using **Cloudflare** (DNS‑01)

> **Why 2.4 matters:** Dovecot **2.4** is *not* configuration‑compatible with 2.3.  
> Your `dovecot.conf` **must** begin with:
> ```
> dovecot_config_version = 2.4.x
> dovecot_storage_version = 2.4.x
> ```
> Dovecot 2.4 also introduces a new settings/variables syntax (e.g., `%n` → `%{user | username}`) and removes several legacy blocks like the old `plugin {}` usage for protocol‑scoped plugins.

---

## 0) What the script does (and how to resume)

The installer runs in 7 idempotent steps and can **resume** from any step:

- **0**: system prep (upgrade, purge old mail stack, clean configs)  
- **1**: install packages  
- **2**: issue/renew Let’s Encrypt certificate (DNS‑01 via Cloudflare)  
- **3**: configure Postfix  
- **4**: configure Dovecot 2.4  
- **5**: configure OpenDKIM and emit DNS records (SPF/DKIM/DMARC/MX)  
- **6**: enable services and Fail2ban

Run from the beginning:
```bash
sudo ./mail-server.sh
# or explicitly
sudo ./mail-server.sh --start-step 0
```

Resume (for example, only step 6):
```bash
sudo ./mail-server.sh --start-step 6
# or:
sudo ./mail-server.sh 6
```

If the script aborts, it prints which step you can resume from.

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

> After installation, the script writes the exact strings you need to `~/dns_mail`.

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

## 4) Environment file (`mail.env`)

Create this next to `mail-server.sh`:

```bash
# mail.env
DNS_PROVIDER=cloudflare
DNS_CREDENTIALS_FILE=/root/.secrets/certbot/cloudflare.ini
CERTBOT_EMAIL=admin@domain.tld
CERT_DOMAINS="mail.domain.tld"
DNS_PROPAGATION_SECONDS=180

# Optional overrides:
# MAIL_SUBDOM=mail
# MAIL_FQDN=mail.domain.tld
```

- `CERT_DOMAINS` can include multiple names (space‑separated).
- `DNS_PROPAGATION_SECONDS` waits for TXT record propagation before validation.

---

## 5) Install / run

On a fresh Debian 13 / Raspberry Pi:

```bash
chmod +x mail-server.sh
sudo ./mail-server.sh
```

The script:
1. Upgrades packages, purges any previous Postfix/Dovecot/OpenDKIM/SpamAssassin/Fail2ban/Certbot, and clears old configs.
2. Installs **Postfix, Dovecot 2.4.x, OpenDKIM, SpamAssassin (spamd), Fail2ban, Certbot, certbot‑dns‑cloudflare**.
3. Issues or renews a Let’s Encrypt certificate using Cloudflare DNS‑01 and installs a renewal hook that reloads Postfix/Dovecot.
4. Writes **Dovecot 2.4** config (single file).
5. Wires **Postfix↔Dovecot SASL**, **OpenDKIM** (milter), **SpamAssassin** filter.
6. Emits **SPF/DKIM/DMARC/MX** records into `~/dns_mail`.
7. Supports **resuming** from any step with `--start-step N` (0..6).

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
- Writes the publishable DKIM TXT into `~/dns_mail` (copy `p=` into `mail._domainkey.domain.tld`).

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
# expect: "protocols = imap pop3" (or more if you enable others)
```

---

## 12) Add mail users (system accounts)

This setup authenticates via **PAM** with **system users**. Example:
```bash
sudo adduser alice
# IMAP:  mail.domain.tld:993  (SSL/TLS)
# SMTP:  mail.domain.tld:587  (STARTTLS, auth required)
# User:  alice   (system account)
```
Mailbox will live under `~alice/Mail/Inbox/…` (Maildir) because `mail_driver`, `mail_path`, and `mail_inbox_path` are set explicitly for Dovecot 2.4.

**Postmaster alias** (recommended):
```bash
echo "postmaster: alice" | sudo tee -a /etc/aliases
sudo newaliases
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

```bash
sudo systemctl stop postfix dovecot opendkim spamd spamassassin fail2ban || true
sudo apt-get purge -y --auto-remove postfix dovecot-* opendkim* spamassassin spamc spamd fail2ban certbot
sudo rm -rf /etc/dovecot /var/lib/dovecot /etc/postfix /etc/opendkim /var/lib/opendkim \
            /etc/fail2ban/jail.d/mail.local /etc/letsencrypt/renewal-hooks/deploy/reload-mail-services.sh
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
**Dovecot 2.3 → 2.4 upgrade guide (required dovecot_config_version, new variables, no plugin {})**: https://doc.dovecot.org/main/installation/upgrade/2.3-to-2.4.html

**Dovecot TLS settings (ssl = yes, ssl_server_cert_file, ssl_server_key_file)**: https://doc.dovecot.org/main/core/config/ssl.html

**2.4 Mail location (mail_driver, mail_path, mail_inbox_path; autodetection exists but explicit recommended)**: https://doc.dovecot.org/2.4.0/core/config/mailbox/mail_location.html

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
