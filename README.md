# Automount Manager for AD/Kerberos CIFS

A single script (`automount-manager.sh`) to add/list/delete/check CIFS autofs mounts that use per-user Kerberos tickets. It handles the system plumbing (packages, autofs includes, krb5 keyring config) and emits program maps so autofs mounts with the triggering user’s UID.

## What it sets up
- Autofs master include in `/etc/auto.master` pointing at `/etc/auto.master.d`.
- Program map per share: `program:/etc/auto.<name>` generates `-fstype=cifs,sec=krb5,multiuser,cruid=<uid>,vers=3.0,noperm ://server/share` so CIFS uses the caller’s ticket.
- Kerberos defaults: `default_ccache_name = KEYRING:persistent:%{uid}` plus domain→realm mapping for the host/share domain.
- `nsswitch.conf` ensures `automount: files`.
- Packages: `autofs`, `cifs-utils`, `keyutils`, `krb5-user`.
- Global linker: `/etc/profile.d/automount-links.sh` creates `~/<share>` symlinks to `/autofs/<share>/$USER`.

## Prereqs
- Ubuntu/Debian host already joined to AD/SSSD and able to `kinit` AD users.
- DNS for the CIFS host resolves; SPN exists for `cifs/<host>` (and `:445` if needed).
- Users log in via SSH (pam_keyinit recommended) and can obtain a Kerberos ticket.

## Standardized Procedure: New Server Setup

This is the full end-to-end process for joining a new Ubuntu machine to the ric.org domain and setting up CottonLab automounting. These steps work on both Ubuntu Server and Ubuntu Desktop images.

### Step 1: Join to AD

```bash
sudo ./ubuntu-ad-join.sh \
  --domain ric.org \
  --allowed-groups "FS_CottonLab_Read_Write,domain admins,_svc_CottonLab" \
  --sudo-group "domain admins" \
  --admin-user Administrator \
  --set-fqdn
```

This handles: package installation, realm join, SSSD config (`access_provider=simple` + `simple_allow_groups` from `--allowed-groups`, which is what gates login), krb5.conf (keyring + domain_realm), nsswitch, PAM session lines (mkhomedir + keyinit), sshd config (GSSAPI + UsePAM), and autofs prerequisites.

**Notes:**
- **Computer name ≤ 15 chars.** AD caps the computer (NetBIOS) name at 15 characters. If the hostname is longer, pass a short one with `--computer-name <name>` (e.g. `--computer-name jc-aurora`) — the script preflights this and fails fast with a clear message otherwise.
- **`--federated-domains` is optional** and only needed when a share lives in a *different* Kerberos realm than the client. As of the May 2026 maintenance, `fs2` authenticates under **RIC.ORG**, so the CottonLab mount uses `//fs2.ric.org/CottonLab` and needs no federated config. (`fs2.smpp.local` still resolves for legacy mounts; use `--federated-domains "smpp.local"` only if you specifically need the SMPP.LOCAL realm.)
- **Access control is via SSSD, not sshd.** The script does not write an sshd `AllowGroups` line (sshd matches it case-sensitively, but SSSD lowercases AD group names — a mismatch that silently locks out AD users). Login is gated by `simple_allow_groups` instead. Local accounts (e.g. an `itadmin` in `sudo`) authenticate via local PAM and keep SSH access without being listed anywhere.

**Interactive prompts during this step:**

During package installation, two dialog boxes will appear:

1. **Configuring krb5-user** — "Default Kerberos version 5 realm": enter **`RIC.ORG`** (must be uppercase).
2. **Configuring samba-common** — "Workgroup/Domain Name": enter **`RIC`** (the NetBIOS/short name of the domain).

Then during the domain join itself:

3. **realm join password prompt** — enter the password for the `--admin-user` account (e.g. Administrator's password).

### Step 2: Verify the join

```bash
realm list
id <your-ad-username>
sudo systemctl status sssd
```

### Step 3: Install automount-manager

```bash
sudo ./automount-manager.sh install
```

### Step 4: Add the CottonLab mount

```bash
sudo automount-manager.sh add CottonLab //fs2.ric.org/CottonLab
```

### Step 5: Verify

```bash
sudo automount-manager.sh check CottonLab
sudo automount-manager.sh list
```

Then as an AD user with a Kerberos ticket:
```bash
klist
ls /autofs/CottonLab/$USER
ls ~/CottonLab
```

**Kerberos tickets and login method.** The CIFS mount is `sec=krb5`, so the user needs a ticket in their keyring (`KEYRING:persistent:<uid>`). Whether a ticket is obtained automatically depends on how they log in:

- **Password login** (`pam_sss`) → SSSD does the `kinit` for you and caches the ticket → the automount works with **no manual step**. This is the recommended default for users.
- **SSH key, or GSSAPI without delegation** → identity is proven but no ticket is placed on the server → the user must run `kinit`, or enable **GSSAPI credential delegation** client-side (`GSSAPIDelegateCredentials yes`, connecting by FQDN) to forward their ticket automatically.

Tickets expire (~10 h); the mount goes stale until the next login/`kinit`.

### Step 6: Backup the working config

```bash
sudo automount-manager.sh backup
```

### Important: Do NOT copy PAM files between machines

**Never copy `/etc/pam.d/common-auth`, `common-account`, or `common-session` from one machine to another.** These files contain `success=N` jump counts generated by `pam-auth-update` based on which PAM modules are installed on that specific machine. Copying them to a machine with different packages installed will break the jump arithmetic and lock out SSH.

Files that ARE safe to use as reference across machines: `krb5.conf`, `nsswitch.conf`, `auto.master`, `/etc/default/autofs`, `sshd_config`. For `sssd.conf`, the `ldap_sasl_authid` line is machine-specific (set by `realm join`) — do not copy it verbatim.

**Do not install `libpam-krb5`** (`pam_krb5.so`). SSSD already handles Kerberos authentication through `pam_sss.so`. Adding `pam_krb5` to the PAM stack is redundant and makes the `success=N` jump counts fragile — if it's present on one machine but not another, copying PAM configs between them will break authentication.

## Usage (as root)
Add a mount (example Lab1):
```bash
sudo ./automount-manager.sh add Lab1 //adhost.mydomain.local/Lab1
```
This creates:
- Master: `/etc/auto.master.d/amgr-Lab1.autofs` -> `program:/etc/auto.Lab1`
- Map script: `/etc/auto.Lab1` (executable, per-user `cruid`)
- Root dir: `/autofs/Lab1`
- Global linker already in place to make `~/Lab1`

List mounts:
```bash
sudo ./automount-manager.sh list
```

Check config and mounts:
```bash
sudo ./automount-manager.sh check         # all
sudo ./automount-manager.sh check Lab1    # specific
```

Deeper diagnostics for a specific mount:
```bash
sudo ./automount-manager.sh troubleshoot Lab1
sudo ./automount-manager.sh troubleshoot Lab1 --user alice --key alice
```

Run integrated debug (passes through to `troubleshoot-ad-autofs-cifs.sh`):
```bash
sudo ./automount-manager.sh --debug --server-host hostname.mydomain.local --share //hostname.mydomain.local/Lab1
```

Delete:
```bash
sudo ./automount-manager.sh del Lab1
```
(Attempts to unmount, removes master/map, restarts autofs, cleans root dir if empty.)

Backup configs (archive):
```bash
sudo ./automount-manager.sh backup
sudo ./automount-manager.sh backup --out /var/backups/automount-manager/custom-amgr-backup.tar.gz
```
Default output is a timestamped archive:
`/var/backups/automount-manager/backup-YYYYmmddHHMMSS.tar.gz`

Restore from backup archive:
```bash
sudo ./automount-manager.sh --restore /var/backups/automount-manager/backup-20260306120000.tar.gz
```
Legacy folder-style backups are also accepted by `--restore`.

## Per-user mount flow
1) User SSHes in, gets a ticket: `kdestroy; kinit`.
2) Access triggers autofs: `ls /autofs/Lab1/$USER`.
3) autofs runs `/etc/auto.Lab1`, resolves `cruid=<user_uid>`, mounts CIFS with `multiuser`.
4) Symlink `~/Lab1` appears via `/etc/profile.d/automount-links.sh`.

## Troubleshooting
- “Required key not available”: ensure tickets go to keyring (`default_ccache_name = KEYRING:persistent:%{uid}`) and user has a fresh `kinit`.
- “Invalid character … location …”: map must return only options/location (no key) and be executable.
- Logs: `journalctl -u autofs -n 50` and `journalctl -k | grep -i cifs`.
- Run `sudo ./automount-manager.sh troubleshoot <name>` to dump autofs maps, service logs, CIFS kernel info, and manual test commands.

## Troubleshooting script (AD/SSSD + Kerberos CIFS)
Use `troubleshoot-ad-autofs-cifs.sh` for a structured, read-only diagnosis of common AD/SSSD + autofs + CIFS problems.

Run (no changes):
```bash
./troubleshoot-ad-autofs-cifs.sh --server-host hostname.mydomain.local --share //hostname.mydomain.local/CottonLab
```

Apply safe fixes (only nsswitch/auto.master/autofs OPTIONS):
```bash
sudo ./troubleshoot-ad-autofs-cifs.sh --server-host hostname.mydomain.local --fix
```

The script also prints a directed troubleshooting path for federated domain / Isilon cases:
- Validate CIFS SPN for the exact hostname used in the share (`kvno cifs/<host>`).
- Detect CNAMEs (Kerberos does not follow CNAMEs; mount using the SPN-bound hostname).
- Confirm cross-domain Kerberos resolution.
- Verify CIFS uses `sec=krb5` and the user’s KEYRING cache is populated.

## Federated domain / Isilon notes
If the client is in one AD domain and the share is hosted in a federated domain, failures are usually SPN/DNS-related (not script-related). The hostname used in the share must match the SPN in AD; CNAME aliases will break Kerberos unless a matching SPN exists for the alias.

## Notes
- Run the script with sudo/root; system file edits and autofs restart require it.
- If your autofs version lacks program map support, update autofs or adjust to static maps (less ideal for per-user Kerberos).
- All scripts support `--version` (or `-V` where noted) to print the script version.

## Script Help (All `.sh` Files In This Repo)

### `automount-manager.sh`
```bash
Usage:
  automount-manager.sh add <name> <cifs_share> [--root <path>] [--timeout <sec>] [--no-ghost]
  automount-manager.sh del <name>
  automount-manager.sh list
  automount-manager.sh --version
  automount-manager.sh backup [--out <path>]
  automount-manager.sh --restore <backup_archive_or_dir>
  automount-manager.sh --debug <troubleshooter_args...>
  automount-manager.sh check [<name>]
  automount-manager.sh troubleshoot <name> [--user <user>] [--key <key>]
  automount-manager.sh install [--target <path>]

Arguments:
  <name>       Short name for the mount (letters/numbers/_/-), e.g. cottonlab
  <cifs_share> CIFS share in the form //server.domain.local/Share or //server/Share

Options for 'add':
  --root <path>     Autofs root directory for this mount (default: /autofs/<name>)
  --timeout <sec>   Autofs timeout in seconds (default: 43200)
  --no-ghost        Do not use --ghost (default: ghost enabled)

Command 'backup':
  Creates a timestamped .tar.gz backup under /var/backups/automount-manager by default.
  --out can be either a directory or a full archive filename (*.tar.gz or *.tgz).

Flag '--restore':
  Restores from a backup archive (.tar.gz), or from a legacy backup directory.

Flag '--debug':
  Runs troubleshoot-ad-autofs-cifs.sh from the same directory as automount-manager.sh.
  All additional arguments are passed through as-is.
```

### `troubleshoot-ad-autofs-cifs.sh`
```bash
Usage:
  troubleshoot-ad-autofs-cifs.sh --server-host <hostname> [--share <//host/share>] [--autofs-map-name <name>] [--fix] [--verbose]
  troubleshoot-ad-autofs-cifs.sh --version

Examples:
  troubleshoot-ad-autofs-cifs.sh --server-host hostname.mydomain.local --share //hostname.mydomain.local/MyShare
  sudo troubleshoot-ad-autofs-cifs.sh --server-host hostname.mydomain.local --autofs-map-name MyShare --fix
```

### `ubuntu-ad-join.sh`
Note: this script requires root and currently checks that before running `--help`.

```bash
Usage: ubuntu-ad-join.sh [options]

Options:
  --domain <domain>                 e.g. ric.org
  --computer-name <name>            default: current hostname; AD limit is 15 chars
  --allowed-groups <list>           comma/semicolon-separated AD groups (gates login)
  --sudo-group <group>              AD group to grant sudo
  --sudo-apps <list>                comma/semicolon-separated list of apps
  --admin-user <user>               domain admin user (skip prompt)
  --federated-domains <list>        extra kerberos domains, e.g. "smpp.local"
  --set-fqdn                        set system hostname to FQDN before join
  --fqdn <host.domain>              explicit FQDN (used with --set-fqdn)
  -V, --version                     show script version
  -h, --help                        show this help
```

## Author: Evgeny Samorokov <evgeny_samorokov@questsys.com>
