#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.2.3"

cleanup_on_error() {
  local exit_code=$?
  if (( exit_code != 0 )); then
    echo "" >&2
    echo "========================================" >&2
    echo "SCRIPT FAILED (exit code $exit_code)" >&2
    echo "========================================" >&2
    echo "The script exited before completing. Config files that were modified" >&2
    echo "have timestamped .bak-* backups alongside the originals." >&2
    echo "" >&2
    echo "To find all backups created during this run:" >&2
    echo "  find /etc -name '*.bak-*' -newer /tmp/.adjoin-start-marker 2>/dev/null" >&2
    echo "" >&2
    echo "If SSH is broken, use console/IPMI access to restore:" >&2
    echo "  cp /etc/ssh/sshd_config.bak-<timestamp> /etc/ssh/sshd_config" >&2
    echo "  systemctl restart ssh" >&2
    echo "" >&2
    echo "To undo a partial domain join:" >&2
    echo "  realm leave ${DOMAIN_LOWER:-<your-domain>} 2>/dev/null" >&2
    echo "========================================" >&2
  fi
  rm -f /tmp/.adjoin-start-marker
}
trap cleanup_on_error EXIT
touch /tmp/.adjoin-start-marker

# Variables - can be set via CLI
DOMAIN=""                 # e.g. ric.org
COMPUTER_NAME=""          # default: current hostname
ALLOWED_GROUPS_RAW=""     # comma/semicolon-separated list
SUDO_AD_GROUP=""          # optional; AD group to grant sudo
SUDO_APPS_RAW=""          # optional; comma/semicolon-separated list of apps
ADMIN_USER=""             # optional; if empty, prompt
FEDERATED_DOMAINS_RAW=""  # optional; extra kerberos domains, comma/semicolon-separated
SET_FQDN="no"             # optional; set system hostname to FQDN before join
FQDN_OVERRIDE=""          # optional; explicit FQDN to set
CONFIGURE_ONLY="no"       # optional; skip realm join, just apply post-join config

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  --domain <domain>                 e.g. ric.org
  --computer-name <name>            default: current hostname; AD limit is 15 chars
  --allowed-groups <list>           comma/semicolon-separated AD groups; gates login
                                    via SSSD simple_allow_groups (the access control)
  --sudo-group <group>              AD group to grant sudo
  --sudo-apps <list>                comma/semicolon-separated list of apps
  --admin-user <user>               domain admin user (skip prompt)
  --federated-domains <list>        extra kerberos domains, e.g. "smpp.local"
  --set-fqdn                        set system hostname to FQDN before join
                                    (omit on Kubernetes nodes — renames the node)
  --fqdn <host.domain>              explicit FQDN (used with --set-fqdn)
  --configure-only                  skip realm join; re-apply post-join config
                                    (SSSD, krb5, PAM, sshd, autofs) on an
                                    already-joined host. No admin password needed.
  -V, --version                     show script version
  -h, --help                        show this help
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local ts bak
  ts="$(date +%Y%m%d%H%M%S)"
  bak="${f}.bak-${ts}"
  [[ -e "$bak" ]] || cp "$f" "$bak" || true
}

trim_ws() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

parse_list() {
  local raw="$1"
  local -n out="$2"
  local cleaned
  local -a parts
  cleaned="${raw//;/,}"
  IFS=',' read -r -a parts <<< "$cleaned"
  for part in "${parts[@]}"; do
    local trimmed
    trimmed="$(trim_ws "$part")"
    [[ -n "$trimmed" ]] && out+=("$trimmed")
  done
}

ensure_nss_token() {
  local key="$1" token="$2" f="/etc/nsswitch.conf"
  [[ -f "$f" ]] || die "Missing $f"
  backup_file "$f"

  if grep -qE "^[[:space:]]*${key}:" "$f"; then
    local line
    line="$(grep -E "^[[:space:]]*${key}:" "$f" | head -n1)"
    if ! echo "$line" | grep -qw "$token"; then
      sed -i -E "s|^[[:space:]]*${key}:[[:space:]]*(.*)$|${key}: \1 ${token}|" "$f"
    fi
  else
    echo "${key}: ${token}" >>"$f"
  fi
}

ensure_automount_line() {
  local f="/etc/nsswitch.conf"
  [[ -f "$f" ]] || die "Missing $f"
  backup_file "$f"
  if grep -qE '^[[:space:]]*automount:' "$f"; then
    local line
    line="$(grep -E '^[[:space:]]*automount:' "$f" | head -n1)"
    if [[ "$line" != "automount: files" ]]; then
      sed -i -E 's|^[[:space:]]*automount:.*|automount: files|' "$f"
    fi
  else
    echo "automount: files" >>"$f"
  fi
}

ensure_auto_master_include() {
  local f="/etc/auto.master"
  [[ -f "$f" ]] || die "Missing $f"
  backup_file "$f"
  if ! grep -Eq '^[[:space:]]*(\+dir:/etc/auto\.master\.d|/\. /etc/auto\.master\.d|/etc/auto\.master\.d)' "$f"; then
    echo "+dir:/etc/auto.master.d" >>"$f"
  fi
}

ensure_autofs_options() {
  local f="/etc/default/autofs"
  if [[ ! -f "$f" ]]; then
    echo 'OPTIONS=""' >"$f"
    return
  fi
  backup_file "$f"
  if ! grep -qE '^[[:space:]]*OPTIONS=' "$f"; then
    echo 'OPTIONS=""' >>"$f"
  fi
}

upsert_ini_option() {
  local file="$1" section="$2" key="$3" value="$4"
  local tmp
  tmp="${file}.tmp"

  awk -v section="$section" -v key="$key" -v value="$value" '
    BEGIN { in_target=0; section_seen=0; key_done=0 }
    {
      if ($0 ~ /^\[.*\]/) {
        if (in_target && !key_done) {
          print key " = " value
          key_done=1
        }
        if ($0 == section) {
          in_target=1
          section_seen=1
        } else {
          in_target=0
        }
        print
        next
      }

      if (in_target && $0 ~ "^[[:space:]]*" key "[[:space:]]*=") {
        print key " = " value
        key_done=1
        next
      }

      print
    }
    END {
      if (in_target && !key_done) {
        print key " = " value
        key_done=1
      }
      if (!section_seen) {
        print ""
        print section
        print key " = " value
      }
    }
  ' "$file" >"$tmp" && mv "$tmp" "$file"
}

ensure_krb5_default_ccache() {
  local f="/etc/krb5.conf"
  [[ -f "$f" ]] || die "Missing $f"
  backup_file "$f"
  upsert_ini_option "$f" "[libdefaults]" "default_ccache_name" "KEYRING:persistent:%{uid}"
}

ensure_krb5_domain_realm() {
  local domain="$1" f="/etc/krb5.conf"
  [[ -n "$domain" ]] || return 0
  [[ -f "$f" ]] || die "Missing $f"
  local realm
  realm="${domain^^}"
  backup_file "$f"
  upsert_ini_option "$f" "[domain_realm]" ".${domain}" "$realm"
  upsert_ini_option "$f" "[domain_realm]" "${domain}" "$realm"
}

ensure_sssd_config() {
  local domain="$1" realm="$2" f="/etc/sssd/sssd.conf"
  local dsection="[domain/${domain}]"

  if [[ ! -f "$f" ]]; then
    cat >"$f" <<EOF
[sssd]
domains = ${domain}
services = nss, pam

[domain/${domain}]
id_provider = ad
ad_domain = ${domain}
krb5_realm = ${realm}
cache_credentials = True
use_fully_qualified_names = False
fallback_homedir = /home/%u
default_shell = /bin/bash
EOF
  fi

  backup_file "$f"
  upsert_ini_option "$f" "[sssd]" "domains" "$domain"
  upsert_ini_option "$f" "[sssd]" "services" "nss, pam"
  upsert_ini_option "$f" "$dsection" "ad_domain" "$domain"
  upsert_ini_option "$f" "$dsection" "krb5_realm" "$realm"
  upsert_ini_option "$f" "$dsection" "id_provider" "ad"
  upsert_ini_option "$f" "$dsection" "cache_credentials" "True"
  upsert_ini_option "$f" "$dsection" "use_fully_qualified_names" "False"
  upsert_ini_option "$f" "$dsection" "fallback_homedir" "/home/%u"
  upsert_ini_option "$f" "$dsection" "default_shell" "/bin/bash"
  upsert_ini_option "$f" "$dsection" "krb5_ccname_template" "KEYRING:persistent:%U"
  upsert_ini_option "$f" "$dsection" "krb5_renewable_lifetime" "7d"
  upsert_ini_option "$f" "$dsection" "krb5_renew_interval" "60m"

  chown root:root "$f"
  chmod 600 "$f"
}

ensure_pam_session_lines() {
  # pam_mkhomedir goes in common-session (applies to all login methods).
  local cs="/etc/pam.d/common-session"
  [[ -f "$cs" ]] || die "Missing $cs"
  backup_file "$cs"

  grep -qE '^[[:space:]]*session[[:space:]]+.*pam_mkhomedir\.so' "$cs" || \
    echo "session required pam_mkhomedir.so skel=/etc/skel/ umask=0022" >>"$cs"

  # pam_sss.so and pam_keyinit.so go in the sshd PAM file, inserted before
  # @include common-session so SSSD's session handler fires early.  Placing
  # them here (rather than in common-session) avoids a race where SSSD's
  # cache has expired and the PAM account check returns "error 4" on the
  # first SSH connection after a period of inactivity.
  local sshd="/etc/pam.d/sshd"
  [[ -f "$sshd" ]] || die "Missing $sshd"
  backup_file "$sshd"

  if ! grep -qE '^[[:space:]]*session[[:space:]]+.*pam_sss\.so' "$sshd"; then
    sed -i '/@include common-session/i session    optional     pam_sss.so' "$sshd"
  fi

  if ! grep -qE '^[[:space:]]*session[[:space:]]+.*pam_keyinit\.so' "$sshd"; then
    sed -i '/@include common-session/i session    optional     pam_keyinit.so force revoke' "$sshd"
  fi
}

upsert_sshd_setting() {
  local key="$1" value="$2" f="/etc/ssh/sshd_config"
  if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+" "$f"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "$f"
  else
    echo "${key} ${value}" >>"$f"
  fi
}

restart_ssh_service() {
  # Validate config BEFORE restarting — a bad config kills sshd and locks you out.
  if have_cmd sshd; then
    echo "Validating sshd config..."
    if ! sshd -t 2>&1; then
      echo "ERROR: sshd config validation failed. SSH was NOT restarted." >&2
      echo "Fix /etc/ssh/sshd_config and restart manually: systemctl restart ssh" >&2
      echo "Your current SSH session is still active — do not disconnect." >&2
      return 1
    fi
  fi

  # Resolve the SSH unit robustly. Parsing `list-unit-files` output is fragile
  # (column formatting, socket activation). `systemctl cat` succeeds for real
  # units and aliases alike. Ubuntu 22.04+ may drive SSH via ssh.socket rather
  # than a long-running ssh.service, so detect and prefer the socket when active.
  local ssh_unit="" u
  for u in ssh.service sshd.service ssh.socket; do
    if systemctl cat "$u" >/dev/null 2>&1; then ssh_unit="$u"; break; fi
  done
  [[ -n "$ssh_unit" ]] || die "No ssh/sshd systemd unit found (is openssh-server installed?)"
  if systemctl cat ssh.socket >/dev/null 2>&1 && systemctl is-active --quiet ssh.socket; then
    systemctl restart ssh.socket
  else
    systemctl restart "$ssh_unit"
  fi
}

set_system_fqdn() {
  local fqdn="$1"
  [[ -n "$fqdn" && "$fqdn" == *.* ]] || die "FQDN must contain a domain part (example: host.example.com)"
  have_cmd hostnamectl || die "hostnamectl not found"

  local short
  short="${fqdn%%.*}"

  backup_file /etc/hosts
  if grep -qE '^[[:space:]]*127\.0\.1\.1[[:space:]]+' /etc/hosts; then
    sed -i -E "s|^[[:space:]]*127\.0\.1\.1[[:space:]]+.*|127.0.1.1 ${fqdn} ${short}|" /etc/hosts
  else
    echo "127.0.1.1 ${fqdn} ${short}" >> /etc/hosts
  fi

  hostnamectl set-hostname "$fqdn"
}

# Allow version output without requiring root.
for arg in "$@"; do
  case "$arg" in
    -V|--version)
      echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"
      exit 0
      ;;
  esac
done

# Root check
[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Please run this script as root."

# Parse CLI args
while (($# > 0)); do
  # Normalize common Unicode non-breaking spaces that can appear when pasting commands.
  opt="$1"
  opt="${opt#"$'\u00A0'"}"
  opt="${opt#"$'\u2007'"}"
  opt="${opt#"$'\u202F'"}"
  case "$opt" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --computer-name) COMPUTER_NAME="${2:-}"; shift 2 ;;
    --allowed-groups) ALLOWED_GROUPS_RAW="${2:-}"; shift 2 ;;
    --sudo-group) SUDO_AD_GROUP="${2:-}"; shift 2 ;;
    --sudo-apps) SUDO_APPS_RAW="${2:-}"; shift 2 ;;
    --admin-user) ADMIN_USER="${2:-}"; shift 2 ;;
    --federated-domains) FEDERATED_DOMAINS_RAW="${2:-}"; shift 2 ;;
    --set-fqdn) SET_FQDN="yes"; shift 1 ;;
    --fqdn) FQDN_OVERRIDE="${2:-}"; shift 2 ;;
    --configure-only) CONFIGURE_ONLY="yes"; shift 1 ;;
    -V|--version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -n "$DOMAIN" ]] || die "Please provide --domain (e.g. ric.org)."

DOMAIN_LOWER="$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')"
DOMAIN_UPPER="$(echo "$DOMAIN" | tr '[:lower:]' '[:upper:]')"
REALM="$DOMAIN_UPPER"
COMPUTER_NAME="${COMPUTER_NAME:-$(hostname)}"
JOIN_COMPUTER_NAME="$COMPUTER_NAME"

ALLOWED_GROUPS=()
SUDO_APPS=("/usr/bin/systemctl" "/usr/bin/journalctl")
FEDERATED_DOMAINS=()

[[ -n "$ALLOWED_GROUPS_RAW" ]] && parse_list "$ALLOWED_GROUPS_RAW" ALLOWED_GROUPS
[[ -n "$SUDO_APPS_RAW" ]] && SUDO_APPS=() && parse_list "$SUDO_APPS_RAW" SUDO_APPS
[[ -n "$FEDERATED_DOMAINS_RAW" ]] && parse_list "$FEDERATED_DOMAINS_RAW" FEDERATED_DOMAINS

if [[ "$CONFIGURE_ONLY" != "yes" ]]; then
  (( ${#ALLOWED_GROUPS[@]} > 0 )) || die "Please provide --allowed-groups with at least one AD group."
fi

echo "Domain: $DOMAIN_LOWER"
echo "Realm: $REALM"
echo "Computer Name: $COMPUTER_NAME"
if (( ${#ALLOWED_GROUPS[@]} > 0 )); then
  echo "Allowed login groups: ${ALLOWED_GROUPS[*]}"
fi

if [[ "$CONFIGURE_ONLY" != "yes" ]]; then
# ── Preflight checks ─────────────────────────────────────────────

# DNS check: can we resolve the domain?
echo ""
echo "Preflight: checking DNS for $DOMAIN_LOWER..."
if ! host "$DOMAIN_LOWER" >/dev/null 2>&1 && ! nslookup "$DOMAIN_LOWER" >/dev/null 2>&1; then
  die "Cannot resolve $DOMAIN_LOWER via DNS. Fix name resolution before joining."
fi
echo "  OK  DNS resolves $DOMAIN_LOWER"

# AD DNS sanity: the resolver must serve the domain's SRV records, not just A
# records. A stale or non-AD DNS server resolves the domain name fine but can't
# answer _ldap._tcp.<domain> — which makes SSSD's KDC/DC discovery time out, the
# classic "first SSH/sudo fails, retry works" symptom. Warn (don't block) so a
# bad resolver is caught before it causes flaky logins post-join.
if have_cmd dig; then
  if dig +short +time=3 +tries=2 SRV "_ldap._tcp.${DOMAIN_LOWER}" 2>/dev/null | grep -q .; then
    echo "  OK  DNS serves AD SRV records (_ldap._tcp.${DOMAIN_LOWER})"
  else
    echo "  WARN  DNS resolves ${DOMAIN_LOWER} but returns no _ldap._tcp SRV records." >&2
    echo "        Your DNS server(s) may be stale or not AD DNS. Point the resolver" >&2
    echo "        at the domain controllers (check 'resolvectl status') before relying" >&2
    echo "        on this host — otherwise SSSD/Kerberos discovery may be flaky." >&2
  fi

  # Per-server check: the aggregate query above passes if ANY server answers, so
  # it misses a single stale/non-AD DNS server mixed in with good ones (e.g. a
  # DHCP scope handing out non-AD KDCs as DNS). Query each configured server
  # directly to pinpoint a bad one that would cause flaky first-attempt logins.
  ad_dns_servers=$( { resolvectl status 2>/dev/null | grep -iE 'DNS Server'; \
                      have_cmd nmcli && nmcli -t dev show 2>/dev/null | grep -i '^IP4.DNS'; } 2>/dev/null \
                    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -vE '^127\.' | sort -u || true )
  ad_dns_bad=0
  for dsrv in $ad_dns_servers; do
    if ! dig +short +time=2 +tries=1 @"$dsrv" SRV "_ldap._tcp.${DOMAIN_LOWER}" 2>/dev/null | grep -q .; then
      echo "  WARN  DNS server ${dsrv} does not serve AD records for ${DOMAIN_LOWER} (stale/non-AD?)." >&2
      ad_dns_bad=$((ad_dns_bad + 1))
    fi
  done
  if (( ad_dns_bad > 0 )); then
    echo "        ${ad_dns_bad} configured DNS server(s) don't serve AD — often a DHCP scope handing" >&2
    echo "        out non-AD DNS. Remove them (or pin AD DNS) or SSSD discovery may be flaky." >&2
  elif [[ -n "$ad_dns_servers" ]]; then
    echo "  OK  every configured DNS server serves AD records"
  fi
else
  echo "  INFO 'dig' not present; skipping AD SRV-record check (install dnsutils to enable)."
fi

# Computer (NetBIOS) name length/charset. AD caps the computer sAMAccountName at
# 15 characters; otherwise adcli fails late and cryptically when it tries to
# create the account (00000523 / ERROR_INVALID_ACCOUNTNAME). Catch it up front,
# before we touch packages or the hostname.
echo ""
echo "Preflight: validating computer name..."
NETBIOS_NAME="${JOIN_COMPUTER_NAME%%.*}"
if (( ${#NETBIOS_NAME} > 15 )); then
  die "Computer name '$NETBIOS_NAME' is ${#NETBIOS_NAME} characters; Active Directory allows at most 15. Re-run with a shorter name, e.g. --computer-name ${NETBIOS_NAME:0:15}"
fi
if [[ ! "$NETBIOS_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || [[ "$NETBIOS_NAME" =~ ^[0-9]+$ ]]; then
  die "Computer name '$NETBIOS_NAME' is not a valid AD computer name; use letters, digits, and hyphens, not starting/ending with a hyphen and not all-numeric. Set one with --computer-name <name>."
fi
echo "  OK  computer name '$NETBIOS_NAME' (${#NETBIOS_NAME} chars)"

fi  # end preflight (skipped in --configure-only mode)

if [[ "$CONFIGURE_ONLY" == "yes" ]]; then
  # Verify the machine is already joined before applying config.
  if ! have_cmd realm || ! realm list 2>/dev/null | grep -qi "$DOMAIN_LOWER"; then
    die "Machine is not joined to $DOMAIN_LOWER. Run without --configure-only to join first."
  fi
  echo ""
  echo "-- configure-only: skipping realm join, applying post-join configuration --"
else
  # Already joined? Warn before proceeding.
  if have_cmd realm && realm list 2>/dev/null | grep -qi "$DOMAIN_LOWER"; then
    echo ""
    echo "WARNING: This machine appears to already be joined to $DOMAIN_LOWER."
    echo "Re-running realm join will reset the machine account password in AD."
    echo "This is usually safe, but if it fails mid-way the existing trust may break."
    echo ""
    echo "If you only need to re-apply configuration (SSSD, PAM, sshd, krb5, autofs),"
    echo "re-run with --configure-only instead — no admin password needed."
    echo ""
    read -r -p "Continue with realm join anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
  fi

  echo ""
  echo "Installing required packages..."
  apt-get update -y
  DEPS=(
    realmd sssd sssd-tools libnss-sss libpam-sss adcli
    samba-common samba-common-bin krb5-user packagekit
    oddjob oddjob-mkhomedir cifs-utils keyutils autofs
  )
  apt-get install -y "${DEPS[@]}"

  have_cmd realm || die "'realm' command not found after installation."

  echo "Discovering realm: $DOMAIN_LOWER"
  realm discover "$DOMAIN_LOWER"

  if [[ "$SET_FQDN" == "yes" ]]; then
    TARGET_FQDN="$FQDN_OVERRIDE"
    if [[ -z "$TARGET_FQDN" ]]; then
      if [[ "$COMPUTER_NAME" == *.* ]]; then
        TARGET_FQDN="$COMPUTER_NAME"
      else
        TARGET_FQDN="${COMPUTER_NAME}.${DOMAIN_LOWER}"
      fi
    fi
    set_system_fqdn "$TARGET_FQDN"
    JOIN_COMPUTER_NAME="${TARGET_FQDN%%.*}"
    COMPUTER_NAME="$TARGET_FQDN"
  else
    if [[ "$COMPUTER_NAME" == *.* ]]; then
      JOIN_COMPUTER_NAME="${COMPUTER_NAME%%.*}"
    fi
  fi

  if [[ -z "$ADMIN_USER" ]]; then
    read -r -p "Enter domain admin username (e.g. Administrator): " ADMIN_USER
  fi
  [[ -n "$ADMIN_USER" ]] || die "Domain admin username cannot be empty."

  echo "Joining $DOMAIN_LOWER as ${JOIN_COMPUTER_NAME} with user $ADMIN_USER..."
  realm join --verbose --computer-name="$JOIN_COMPUTER_NAME" -U "$ADMIN_USER" "$DOMAIN_LOWER"

  echo "Permitting AD groups for login..."
  for grp in "${ALLOWED_GROUPS[@]}"; do
    realm permit -g "$grp@$DOMAIN_LOWER"
  done
fi

echo "Configuring SSSD, Kerberos, NSS, PAM, and autofs prerequisites..."
ensure_sssd_config "$DOMAIN_LOWER" "$DOMAIN_UPPER"
ensure_krb5_default_ccache
ensure_krb5_domain_realm "$DOMAIN_LOWER"
for fdom in "${FEDERATED_DOMAINS[@]}"; do
  ensure_krb5_domain_realm "$(echo "$fdom" | tr '[:upper:]' '[:lower:]')"
done

ensure_nss_token passwd sss
ensure_nss_token group sss
ensure_nss_token shadow sss
ensure_automount_line
ensure_pam_session_lines
ensure_auto_master_include
ensure_autofs_options

systemctl enable sssd
systemctl restart sssd
systemctl enable autofs
systemctl restart autofs

SSHD_CONFIG="/etc/ssh/sshd_config"
[[ -f "$SSHD_CONFIG" ]] || die "Missing $SSHD_CONFIG"
backup_file "$SSHD_CONFIG"

echo "Configuring SSH daemon..."
upsert_sshd_setting UsePAM yes
upsert_sshd_setting GSSAPIAuthentication yes
upsert_sshd_setting GSSAPICleanupCredentials yes
upsert_sshd_setting PasswordAuthentication yes
upsert_sshd_setting ChallengeResponseAuthentication yes

# Login access is gated by SSSD's simple access provider
# (access_provider=simple / simple_allow_groups), which `realm permit -g`
# configured above from --allowed-groups. That matching is case-insensitive.
#
# We intentionally do NOT write an sshd AllowGroups line. sshd matches
# AllowGroups case-sensitively, but SSSD returns AD group names lowercased, so an
# AllowGroups line built from mixed-case group names silently locks out AD users
# (observed in the field). Relying on simple_allow_groups mirrors the known-good
# jc-app01/jc-app02 configuration. Local accounts (e.g. an itadmin in 'sudo')
# authenticate via local PAM and are unaffected by simple_allow_groups.
if grep -qE '^[[:space:]]*AllowGroups[[:space:]]+' "$SSHD_CONFIG"; then
  sed -i -E '/^[[:space:]]*AllowGroups[[:space:]]+/d' "$SSHD_CONFIG"
  echo "Removed an existing sshd AllowGroups line; access is via simple_allow_groups."
fi

restart_ssh_service

if [[ -n "$SUDO_AD_GROUP" ]]; then
  SUDOERS_FILE="/etc/sudoers.d/$SUDO_AD_GROUP"
  SUDOERS_TMP="${SUDOERS_FILE}.tmp"
  echo "%$SUDO_AD_GROUP ALL=(ALL) NOPASSWD: ${SUDO_APPS[*]}" >"$SUDOERS_TMP"
  chmod 440 "$SUDOERS_TMP"
  if have_cmd visudo; then
    if ! visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
      rm -f "$SUDOERS_TMP"
      echo "ERROR: Generated sudoers file failed validation. Skipping sudoers setup." >&2
      echo "You may need to configure /etc/sudoers.d/ manually." >&2
    else
      mv "$SUDOERS_TMP" "$SUDOERS_FILE"
    fi
  else
    mv "$SUDOERS_TMP" "$SUDOERS_FILE"
  fi
fi

# Success — disarm the error trap.
trap - EXIT
rm -f /tmp/.adjoin-start-marker

echo "=============================="
if [[ "$CONFIGURE_ONLY" == "yes" ]]; then
  echo "Post-join configuration applied."
else
  echo "Active Directory join complete."
fi
echo "Domain: $DOMAIN_LOWER"
echo "Realm: $REALM"
echo "Configured NSS: passwd/group/shadow + sss, automount: files"
echo "Configured Kerberos cache: KEYRING:persistent:%{uid}"
if ((${#FEDERATED_DOMAINS[@]} > 0)); then
  echo "Configured additional krb5 domain_realm mappings: ${FEDERATED_DOMAINS[*]}"
fi
if (( ${#ALLOWED_GROUPS[@]} > 0 )); then
  echo "Login access restricted to groups: ${ALLOWED_GROUPS[*]}"
fi
echo "You can test as an AD user:"
echo "  klist"
echo "  id <ad-user>"
echo "=============================="
