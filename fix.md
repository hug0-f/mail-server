# Dovecot / RainLoop "Sent folder not saved" Fix

## Symptoms

RainLoop shows:

```text
The message was sent but was not saved in the Sent folder.
```

But:

* SMTP/Postfix works
* The recipient receives the email
* IMAP saving fails

---

# Root Cause

Dovecot cannot create or write mailbox folders because of bad filesystem permissions.

Typical error:

```text
missing +w perm: /var/vmail/domain.tld
dir owned by 0:0 mode=0755
```

This means:

* Dovecot runs as `vmail:vmail`
* Mail directory belongs to `root:root`
* `vmail` cannot write inside it

---

# Diagnosis

Check mailboxes:

```bash
doveadm mailbox list -u user@domain.tld
```

Check permissions:

```bash
ls -la /var/vmail/domain.tld
```

Test write access:

```bash
sudo -u vmail mkdir /var/vmail/domain.tld/test
```

If it fails → permissions issue.

---

# Fix

Set proper ownership:

```bash
chown -R vmail:vmail /var/vmail
```

Recommended permissions:

```bash
find /var/vmail -type d -exec chmod 770 {} \;
find /var/vmail -type f -exec chmod 660 {} \;
```

---

# Recreate Mailboxes

```bash
doveadm mailbox create -u user@domain.tld Sent
doveadm mailbox create -u user@domain.tld Drafts
doveadm mailbox create -u user@domain.tld Trash
doveadm mailbox create -u user@domain.tld Junk
```

---

# Restart Services

```bash
systemctl restart dovecot
systemctl restart postfix
```

---

# Verify

```bash
doveadm mailbox list -u user@domain.tld
```

Expected:

```text
INBOX
Sent
Drafts
Trash
Junk
Archive
```

RainLoop should now save sent messages correctly.
