# Known Issues

## SSSD ≤ 2.6.x: first-attempt SSH/sudo failure after idle (binds as `host/<fqdn>`)

**Affected:** Ubuntu 22.04 / SSSD 2.6.3 (observed on **jc-compute03**). Boxes on SSSD 2.9.x (Ubuntu 24.04 — jc-app01, jc-app02, jc-aurora) are **not** affected by the same config.

> **Two separate bugs, one symptom.** The "first attempt fails, retry works" behavior can come from *either* of two unrelated causes, both of which knock SSSD's backend offline:
> 1. **Stale/flaky DNS server** (e.g. a non-AD KDC handed out by DHCP) — backend's DC discovery times out. See DEPLOYMENT-GUIDE → "Stale DNS server".
> 2. **This SSSD 2.6.3 keytab bug** — backend's GSSAPI LDAP bind is rejected by AD.
>
> They look identical at the login/auth-log level. **The tell is in the SSSD backend log** (`/var/log/sssd/sssd_<domain>.log`): a DNS problem shows discovery timeouts, while this bug shows `Client 'host/<fqdn>@REALM' not found ... Unable to create GSSAPI-encrypted LDAP connection`. On jc-compute03, DNS was a real but *coincidental* problem (fixed at the DHCP source); the residual failures are this SSSD bug — confirmed because they persist with clean DNS, and because the same bad DNS on the 2.9.x boxes did **not** produce the symptom.

### Symptom
The **first** SSH login or `sudo` after a period of inactivity fails; an **immediate retry succeeds**. Auth log:
```
sshd: Authorized to <user>, krb5 principal <user>@RIC.ORG (krb5_kuserok)
sshd: pam_sss(sshd:account): Access denied for user <user>: 4 (System error)
sshd: fatal: Access denied for user <user> by PAM account configuration [preauth]
# retry a few seconds later → Accepted gssapi-with-mic ... (works)
```
SSSD backend log (`/var/log/sssd/sssd_<domain>.log`) at the moment of failure:
```
ldap_child: Failed to initialize credentials using keytab [MEMORY:/etc/krb5.keytab]:
  Client 'host/<fqdn>@RIC.ORG' not found in Kerberos database.
  Unable to create GSSAPI-encrypted LDAP connection.
```

### Root cause
SSSD's backend can't establish its GSSAPI-encrypted LDAP connection because it authenticates as the **host SPN** `host/<fqdn>@REALM` — and AD will not issue a TGT to a host SPN (only to the machine account `<HOSTNAME>$@REALM`). With the backend offline, the first account-stage group lookup (`access_provider = simple` / `simple_allow_groups`) errors out (`System error`); the retry works once SSSD recovers / serves from cache.

Why it picks the host SPN — from `debug_level = 9`:
```
select_principal_from_keytab: trying to select the most appropriate principal
find_principal_in_keytab: Trying <fqdn>@REALM       → No match
find_principal_in_keytab: Trying <HOSTNAME>$@REALM  → No match   ← UPPERCASE
find_principal_in_keytab: Trying host/<fqdn>@REALM  → matched
select_principal_from_keytab: Selected primary: host/<fqdn>
```
The keytab stores the machine account **lowercase** (`<hostname>$`, matching the OS hostname), but SSSD's auto-selection derives it **UPPERCASE** (`<HOSTNAME>$`). **SSSD 2.6.3 matches keytab principals case-sensitively**, so it misses the real entry and falls back to `host/<fqdn>`. The explicit `ldap_sasl_authid = <hostname>$` is honored on *some* connections but **not inherited to all of them** (`dp_option_inherit ... not set up to be inherited`), so those connections hit the broken fallback. SSSD 2.9.x matches case-insensitively → newer boxes are unaffected.

### What is NOT the cause (all ruled out)
- **Keytab** — healthy: `sudo kinit -k '<hostname>$@REALM'` succeeds. (`kinit -k host/<fqdn>@REALM` fails on **every** AD box — that's expected, not a fault.)
- **DNS** — clean (`resolvectl dns <iface>` shows only AD DNS). A *separate* DHCP problem had handed out stale SMPP.LOCAL KDCs as DNS (see DEPLOYMENT-GUIDE → "Stale DNS server"); that was fixed at the DHCP source and is unrelated to this bug.
- **`ldap_sasl_authid`** — correctly set to `<hostname>$` under `[domain/<realm>]`, no conf.d override.
- **AllowGroups / access control**, and the **old smpp.local federation** — not involved.

### Workarounds that do NOT fix it
- `ad_enable_gc = False`
- `subdomain_inherit = ldap_sasl_authid`

Both leave at least one non-inheriting connection still hitting the broken fallback. Remove them again if you tried them.

### Fix
**Upgrade the host to Ubuntu 24.04 / SSSD 2.9.x** (matching jc-app01/02 and jc-aurora). That resolves the case-sensitive keytab matching at the source.

**Interim:** the box is fully functional — this is the cosmetic "fails once, retry works" on SSH/sudo. Users retry; the CIFS automount works once logged in.

### 5-minute confirmation on a suspect box
```bash
# 1. keytab is fine (machine account works). Note: host/<fqdn> "fails" on ALL AD boxes — ignore that one.
sudo kinit -k 'jc-compute03$@RIC.ORG' && sudo klist && sudo kdestroy

# 2. DNS is clean
resolvectl dns ens8f0np0          # only AD DNS, no stray 10.60.91.x

# 3. catch SSSD selecting host/ instead of the machine account
sudo sss_debuglevel 9
#   reproduce a cold sudo/login after idle, then:
sudo grep -iE 'find_principal_in_keytab|Selected primary' /var/log/sssd/sssd_ric.org.log | tail
sudo sss_debuglevel 0
```
If the log shows `Selected primary: host/<fqdn>` while `ldap_sasl_authid` is set to `<hostname>$`, it's this issue → **upgrade SSSD/Ubuntu.**
