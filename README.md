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
- Users log in via SSH (pam_keyinit/pam_krb5 recommended) and can obtain a Kerberos ticket.

## Usage (as root)
Add a mount (example Lab1):
```bash
sudo ./automount-manager.sh add Lab1 //adfs1.itcraftworks.com/Lab1
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

Delete:
```bash
sudo ./automount-manager.sh del Lab1
```
(Attempts to unmount, removes master/map, restarts autofs, cleans root dir if empty.)

## Per-user mount flow
1) User SSHes in, gets a ticket: `kdestroy; kinit`.
2) Access triggers autofs: `ls /autofs/Lab1/$USER`.
3) autofs runs `/etc/auto.Lab1`, resolves `cruid=<user_uid>`, mounts CIFS with `multiuser`.
4) Symlink `~/Lab1` appears via `/etc/profile.d/automount-links.sh`.

## Troubleshooting
- “Required key not available”: ensure tickets go to keyring (`default_ccache_name = KEYRING:persistent:%{uid}`) and user has a fresh `kinit`.
- “Invalid character … location …”: map must return only options/location (no key) and be executable.
- Logs: `journalctl -u autofs -n 50` and `journalctl -k | grep -i cifs`.

## Notes
- Run the script with sudo/root; system file edits and autofs restart require it.
- If your autofs version lacks program map support, update autofs or adjust to static maps (less ideal for per-user Kerberos).***

## Author: Evgeny Samorokov <team@itcraftworks.com>
