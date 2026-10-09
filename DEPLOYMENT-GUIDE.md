# AD Domain Join & CIFS Automount Deployment Guide

Full procedure for joining an Ubuntu server to the ric.org AD domain, migrating local user home directories to AD ownership, and setting up Kerberos-authenticated CIFS automounts.

Developed and tested on jc-compute03 and jc-aurora. Applies to any Ubuntu server in the ric.org environment.

> **fs2 auth domain (May 2026):** the `fs2` NAS now authenticates under **RIC.ORG** (was SMPP.LOCAL). New mounts should use `//fs2.ric.org/CottonLab` and do **not** need `--federated-domains`. `//fs2.smpp.local/...` still resolves for legacy mounts.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Create a local admin fallback account](#2-create-a-local-admin-fallback-account)
3. [Pre-join backup](#3-pre-join-backup)
4. [Join the domain](#4-join-the-domain)
5. [Verify the join](#5-verify-the-join)
6. [Check AD/local user overlap](#6-check-adlocal-user-overlap)
7. [Chown home directories to AD ownership](#7-chown-home-directories-to-ad-ownership)
8. [Remove orphaned local accounts](#8-remove-orphaned-local-accounts)
9. [SSH in as AD user and verify](#9-ssh-in-as-ad-user-and-verify)
10. [Install automount-manager and add mounts](#10-install-automount-manager-and-add-mounts)
11. [Enable Kerberos ticket renewal](#11-enable-kerberos-ticket-renewal)
12. [Restart Docker containers](#12-restart-docker-containers)
13. [Backup working config](#13-backup-working-config)
14. [Rollback procedure](#14-rollback-procedure)

---

## 1. Prerequisites

- Ubuntu server with SSH access and sudo
- DNS resolving ric.org (verify: `host ric.org`)
- Network access to domain controllers (10.60.30.14, 10.60.30.15)
- AD admin credentials (e.g. Administrator)
- All scripts from this repo available on the target machine

## 2. Create a local admin fallback account

Before touching anything, create a local account that is guaranteed to work even if AD/SSSD breaks. **Do not skip this.**

```bash
sudo adduser itadmin
sudo usermod -aG sudo itadmin
```

Verify you can SSH in as `itadmin` and run `sudo` before proceeding. Keep this session open throughout the entire process.

## 3. Pre-join backup

Snapshot all system config files that the AD join script will modify:

```bash
sudo ./pre-join-backup.sh
```

Saves to `/var/backups/pre-ad-join-<timestamp>/` with a symlink at `/var/backups/pre-ad-join-latest`.

## 4. Join the domain

**Interactive prompts during this step:**

1. **Configuring krb5-user** — "Default Kerberos version 5 realm": enter **`RIC.ORG`** (uppercase)
2. **Configuring samba-common** — "Workgroup/Domain Name": enter **`RIC`**
3. **realm join password prompt** — enter the Administrator password

```bash
sudo ./ubuntu-ad-join.sh \
  --domain ric.org \
  --allowed-groups "FS_CottonLab_Read_Write,domain admins,_svc_CottonLab" \
  --sudo-group "domain admins" \
  --admin-user Administrator \
  --set-fqdn
```

**Note on the computer name:** AD caps the computer (NetBIOS) name at **15 characters**. If the hostname is longer (e.g. `jcotton-Alienware-Aurora-R7`), pass a short one: `--computer-name jc-aurora`. The script preflights this and fails fast with a clear message rather than letting `adcli` fail cryptically (`00000523 / ERROR_INVALID_ACCOUNTNAME`) partway through.

**Note on access control:** SSH/login access is gated by SSSD's `simple_allow_groups` (configured from `--allowed-groups`), which matches AD group names case-insensitively. The script does **not** write an sshd `AllowGroups` line. Local accounts (e.g. `itadmin`) authenticate via local PAM and are unaffected, so they keep SSH access without needing to be listed anywhere.

**Note on `--set-fqdn`:** If the hostname is already an FQDN (e.g. `jc-compute03.ric.org`), this flag has no effect. On Kubernetes nodes, omit it to avoid re-registering the node under a different name.

### Safety features in the join script

- DNS preflight check — fails fast if ric.org doesn't resolve
- Already-joined detection — warns and prompts before re-joining
- `sshd -t` validation — won't restart SSH with a bad config
- Sudoers validation — writes to temp file, validates, then moves into place
- Error trap — prints recovery instructions if the script fails mid-way
- `.bak-*` copies of every file modified

## 5. Verify the join

```bash
realm list
id kshah@ric.org
sudo systemctl status sssd
```

`id kshah@ric.org` should return an AD uid (e.g. 268060844). `id kshah` (without domain) may still return the local uid if the local account exists — this is expected and handled in the next steps.

**Validate DNS and config with the troubleshooter.** This is the single most useful post-join check — it validates each configured DNS server individually (catching a stale/non-AD server the join's aggregate preflight can miss), plus krb5/sssd/PAM/autofs:

```bash
sudo ./troubleshoot-ad-autofs-cifs.sh --server-host fs2.ric.org
```

Pay attention to the **"DNS server validation"** section: every configured server should `PASS`. A `WARN` (e.g. a `10.60.91.x` SMPP.LOCAL KDC handed out by DHCP) means SSSD's backend discovery will be flaky — fix the DNS source (DHCP scope) or pin AD DNS before relying on the host. See "Stale DNS server" under Known behaviors.

## 6. Check AD/local user overlap

See which local users have matching AD accounts:

```bash
sudo ./check-ad-overlap.sh
```

Output shows MATCH (needs chown), NONE (no AD account, safe to ignore), and current ownership status.

## 7. Chown home directories to AD ownership

Preview first:

```bash
sudo ./post-join-chown-homes.sh --dry-run
```

Then apply:

```bash
sudo ./post-join-chown-homes.sh
```

This uses `id <user>@ric.org` to resolve the AD uid and chowns `/home/<user>` recursively. Local-only users are skipped automatically.

### Impact on running services

- **Running processes** — unaffected (kernel tracks by uid number)
- **Docker containers with bind mounts from /home** — containers running as root are fine. Containers running as a non-root uid that matched the old local uid may lose access. Check before chowning:
  ```bash
  docker ps -q | xargs -I{} docker inspect {} --format '{{.Name}} uid={{.Config.User}}' 2>/dev/null
  ```
- **Files with world-readable permissions** (e.g. `rw-rw-r--`) remain accessible regardless of ownership change

### Reverting the chown

The dry-run output shows old uid:gid values. To revert:
```bash
sudo chown -R <old_uid>:<old_gid> /home/<user>
```

## 8. Remove orphaned local accounts

After chowning, `id <user>` still returns the local uid because `/etc/passwd` is checked before SSSD. Remove the local account so the short name resolves to AD:

```bash
# Check for important files owned by the local uid outside /home
sudo find / -uid <local_uid> -not -path '/proc/*' -not -path '/sys/*' -not -path '/home/<user>/*' 2>/dev/null | head -20
```

Expect to see only ephemeral files (`/dev/pts/*`, `/run/user/*`, `/run/screen/*`). These are harmless.

If the user has active processes (VSCode, screen, etc.), use `-f` to force:

```bash
sudo userdel -f <user>
sudo groupdel <user> 2>/dev/null
```

Running processes continue working — the kernel tracks them by uid number, not by `/etc/passwd` entries.

If the user was in any local-only groups (check `grep <user> /etc/group`), re-add the AD user:

```bash
sudo usermod -aG fs2_mount <user>
```

### Cleaning up orphaned ssh-agents

VSCode leaves orphaned ssh-agent processes. Clean them up:

```bash
sudo pkill -u <old_local_uid> ssh-agent
```

## 9. SSH in as AD user and verify

Open a **new** session (keep itadmin open):

```bash
ssh kshah@jc-compute03
```

Should now resolve to the AD account. Verify:

```bash
id          # uid should be the AD uid (e.g. 268060844)
pwd         # /home/kshah
ls ~/       # all files intact
```

## 10. Install automount-manager and add mounts

```bash
kinit
klist
sudo automount-manager.sh install
sudo automount-manager.sh add CottonLab //fs2.ric.org/CottonLab
sudo automount-manager.sh check CottonLab
ls /autofs/CottonLab/$USER
ls ~/CottonLab
```

## 11. Enable Kerberos ticket renewal

CIFS mounts use `sec=krb5`, so each user needs a valid Kerberos ticket. Without renewal, tickets expire after ~10 hours and mounts stop working — including inside Docker containers that bind-mount host CIFS paths.

Add these two lines to `/etc/sssd/sssd.conf` under `[domain/ric.org]`:

```ini
krb5_renewable_lifetime = 7d
krb5_renew_interval = 60m
```

```bash
sudo systemctl restart sssd
```

**New joins already include these settings** as of the update to `ubuntu-ad-join.sh`. This step is only needed for hosts joined before that change.

### How it works

SSSD automatically renews tickets it obtained via password login (`pam_sss`). With these settings, a single password login gives the user up to 7 days of uninterrupted CIFS access with no manual `kinit`.

### What counts as a password login

| Method | Triggers SSSD renewal? |
|---|---|
| `ssh user@host` with AD password | Yes |
| `ssh -o PreferredAuthentications=password user@host` | Yes (forces password) |
| `su - user` with AD password | Yes |
| `sudo` (when it prompts for your AD password) | Yes |
| Graphical login / lock screen unlock | Yes |
| SSH with public key (`Accepted publickey`) | **No** |
| SSH with GSSAPI (`Accepted gssapi-with-mic`) | **No** |
| Manual `kinit` on the command line | **No** |

SSSD renews at approximately the half-life of the ticket (e.g. ~5 hours into a 10-hour ticket), checking at the `krb5_renew_interval` frequency. Renewal produces a new `Valid starting` / `Expires` while `renew until` stays fixed at the original 7-day ceiling.

### Verification

After restarting SSSD, log in **with a password** (or trigger a `sudo` password prompt), then:

```bash
klist    # should show "renew until" ~7 days out
```

Check the auth log to confirm the login method:

```bash
sudo grep "$USER" /var/log/auth.log | grep 'Accepted' | tail -5
# Want: "Accepted password"
```

To confirm automatic renewal is working, wait past the ticket half-life and run `klist` again. `Valid starting` and `Expires` should have advanced while `renew until` stays the same. Do not type your password or `sudo` during the wait — that would obtain a fresh ticket rather than renewing.

### Docker containers and Kerberos tickets

Containers that bind-mount a host directory under a CIFS share (e.g. `source=/home/user/CottonLab/...,target=/mnt/...,type=bind`) inherit the host's CIFS authentication. The container has no Kerberos tools — the ticket belongs to the host user. When the host ticket expires, the bind mount inside the container shows `Permission denied` / `d?????????`.

The fix is always host-side: ensure the host user has a valid, auto-renewed ticket. SSSD renewal (via password login) handles this automatically. For users who only SSH with keys, they need one password login per week.

### Fallback: keytab + cron (SSH-key-only users with long jobs)

If a user cannot password-login (e.g. automated pipelines), a per-user keytab provides fully unattended renewal:

```bash
# Create keytab (as the user, requires their AD password once)
ktutil
addent -password -p user@RIC.ORG -k 1 -e aes256-cts-hmac-sha1-96
wkt /home/user/.krb5.keytab
quit
chmod 600 /home/user/.krb5.keytab

# Automate via cron
crontab -e
# 0 * * * * /usr/bin/kinit -kt /home/user/.krb5.keytab user@RIC.ORG 2>/dev/null
```

The keytab breaks on password change and must be regenerated. Treat it like a password (`chmod 600`, user-owned).

## 12. Restart Docker containers

Restart any containers that bind-mount from chowned home directories:

```bash
docker restart isr_dev_kshah grafana-c prometheus-c dcgm-exporter-c beautiful_perlman
docker ps
```

## 13. Backup working config

```bash
sudo automount-manager.sh backup
```

## 14. Rollback procedure

### If SSH breaks (from console/IPMI)

```bash
sudo cp /var/backups/pre-ad-join-latest/etc/ssh/sshd_config /etc/ssh/sshd_config
sudo systemctl restart ssh
```

### Full rollback

```bash
sudo realm leave ric.org
sudo ./pre-join-backup.sh --restore
sudo systemctl restart ssh
sudo systemctl stop sssd
```

### Revert chown only

Use the old uid:gid from the dry-run output:
```bash
sudo chown -R 1002:1002 /home/kshah
```

---

## Scripts reference

| Script | Purpose | When to run |
|---|---|---|
| `pre-join-backup.sh` | Snapshot configs before join | Before step 4 |
| `pre-join-backup.sh --restore` | Restore configs from snapshot | Rollback |
| `ubuntu-ad-join.sh` | Join machine to AD domain | Step 4 |
| `check-ad-overlap.sh` | Show local/AD username collisions | After join, before chown |
| `post-join-chown-homes.sh` | Chown home dirs to AD uids | After join |
| `pre-join-migrate-homes.sh` | Alternative: rename home dirs (for complex cases) | Before join |
| `automount-manager.sh` | Add/manage CIFS automounts | After join |
| `troubleshoot-ad-autofs-cifs.sh` | Diagnose AD/CIFS/autofs issues | Anytime |

## PAM safety reminders

- **Never copy** `/etc/pam.d/common-auth`, `common-account`, or `common-session` between machines
- **Do not install `libpam-krb5`** — SSSD handles Kerberos via `pam_sss.so`
- Files safe to reference across machines: `krb5.conf`, `nsswitch.conf`, `auto.master`, `/etc/default/autofs`, `sshd_config`

## Known behaviors

- **First login:** Use `user@ric.org` for the first SSH. SSSD hasn't cached the user yet, so short names may be slow to resolve. After the cache populates, the short name (`ssh user@host`) works.
- **Kerberos ticket on login:** Password login (`pam_sss`) obtains and caches the TGT automatically, so the automount works with no `kinit`. Login methods without a password (SSH key, or GSSAPI without credential delegation) leave the server keyring empty — those users must `kinit`, or enable GSSAPI delegation client-side. Tickets last ~10 h; the mount goes stale until the next login/`kinit`.
- **Automount delay on first access:** `getent passwd` in the program map may be slow until SSSD caches the user. Retry after a few seconds.
- **Kerberos ticket expiry (~10 h):** AD grants 10-hour tickets. Without SSSD renewal, CIFS mounts die after ~10 h (or immediately on SSH logout for GSSAPI-delegated tickets). See [step 11](#11-enable-kerberos-ticket-renewal). Users need one password-based action per week (SSH password login, `sudo` prompt, or graphical login) to keep SSSD renewing their ticket, or use a keytab for fully unattended work.
- **GSSAPI delegation is unsuitable for unattended work:** `GSSAPICleanupCredentials yes` destroys the delegated ticket on logout. A long-running job's mount dies the moment the user disconnects. Delegation is fine for interactive VS Code sessions; never for background jobs.
- **Docker bind mounts from CIFS paths:** The container has no Kerberos — the host ticket authenticates the mount. If autofs unmounts the underlying path on idle timeout, Docker's bind stays pinned to the detached mount and won't recover without a container restart, even after `kinit`. See [step 11](#11-enable-kerberos-ticket-renewal) for the full explanation.
- **Computer name ≤ 15 chars:** AD rejects computer names longer than 15 characters. Long hostnames need `--computer-name <short>`; the join preflight catches this up front.
- **Stale DNS server → "first attempt fails, retry works":** if the resolver lists a dead/stale/non-AD DNS server, SSSD's KDC/DC discovery tries it first, times out, then falls back to a working server on retry — producing intermittent first-attempt SSH/sudo failures (seen on jc-compute03; fixed by correcting the DNS server IPs). Such a server resolves plain A records but can't answer `_ldap._tcp.<domain>` SRV. **Checks:** `ubuntu-ad-join.sh` preflights AD SRV records before joining, and `troubleshoot-ad-autofs-cifs.sh` validates **each configured DNS server individually** (via `resolvectl`/`dig @<server> SRV _ldap._tcp.<domain>`) and flags any that don't serve AD. Fix by pointing the resolver only at the domain controllers, then `sudo systemctl restart systemd-resolved sssd`.
- **Legacy smpp.local SRV warnings:** if a host still mounts `//fs2.smpp.local/...`, the troubleshooter may report `WARN - No SRV records for _kerberos._udp.smpp.local` — cosmetic, because krb5.conf has explicit KDC entries for SMPP.LOCAL. Mounts that use `//fs2.ric.org/...` (the current default) don't hit this at all.
- **SSSD ≤ 2.6.x first-attempt SSH/sudo failure** (binds as `host/<fqdn>`, succeeds on retry): a genuine SSSD 2.6.3 bug, *not* a config/keytab/DNS problem — fix is to upgrade to Ubuntu 24.04 / SSSD 2.9.x. Full diagnosis and the 5-minute confirmation in [KNOWN-ISSUES.md](KNOWN-ISSUES.md). (Don't confuse it with the stale-DNS item above, which has the same surface symptom but a different cause.)
