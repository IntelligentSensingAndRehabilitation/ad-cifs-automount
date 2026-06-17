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
11. [Restart Docker containers](#11-restart-docker-containers)
12. [Backup working config](#12-backup-working-config)
13. [Rollback procedure](#13-rollback-procedure)

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

> If a user logs in with their **AD password**, `pam_sss` obtains the Kerberos ticket automatically and the `kinit` above isn't needed. A manual `kinit` is only required for logins that don't carry a password (SSH key, or GSSAPI without delegation). See "Known behaviors" below.

## 11. Restart Docker containers

Restart any containers that bind-mount from chowned home directories:

```bash
docker restart isr_dev_kshah grafana-c prometheus-c dcgm-exporter-c beautiful_perlman
docker ps
```

## 12. Backup working config

```bash
sudo automount-manager.sh backup
```

## 13. Rollback procedure

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
- **Computer name ≤ 15 chars:** AD rejects computer names longer than 15 characters. Long hostnames need `--computer-name <short>`; the join preflight catches this up front.
- **Stale DNS server → "first attempt fails, retry works":** if the resolver lists a dead/stale/non-AD DNS server, SSSD's KDC/DC discovery tries it first, times out, then falls back to a working server on retry — producing intermittent first-attempt SSH/sudo failures (seen on jc-compute03; fixed by correcting the DNS server IPs). Such a server resolves plain A records but can't answer `_ldap._tcp.<domain>` SRV. **Checks:** `ubuntu-ad-join.sh` preflights AD SRV records before joining, and `troubleshoot-ad-autofs-cifs.sh` validates **each configured DNS server individually** (via `resolvectl`/`dig @<server> SRV _ldap._tcp.<domain>`) and flags any that don't serve AD. Fix by pointing the resolver only at the domain controllers, then `sudo systemctl restart systemd-resolved sssd`.
- **Legacy smpp.local SRV warnings:** if a host still mounts `//fs2.smpp.local/...`, the troubleshooter may report `WARN - No SRV records for _kerberos._udp.smpp.local` — cosmetic, because krb5.conf has explicit KDC entries for SMPP.LOCAL. Mounts that use `//fs2.ric.org/...` (the current default) don't hit this at all.
