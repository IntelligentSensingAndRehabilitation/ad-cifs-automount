#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# Variables - can be set via CLI
DOMAIN=""                 # e.g. ric.org
COMPUTER_NAME=""          # default: current hostname
ALLOWED_GROUPS_RAW=""     # comma/semicolon-separated list
SSH_ALLOWED_GROUPS_RAW="" # optional; defaults to ALLOWED_GROUPS_RAW
SUDO_AD_GROUP=""          # optional; AD group to grant sudo
SUDO_APPS_RAW=""          # optional; comma/semicolon-separated list of apps
ADMIN_USER=""             # optional; if empty, prompt
FEDERATED_DOMAINS_RAW=""  # optional; extra kerberos domains, comma/semicolon-separated
SET_FQDN="no"             # optional; set system hostname to FQDN before join
FQDN_OVERRIDE=""          # optional; explicit FQDN to set

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  --domain <domain>                 e.g. ric.org
  --computer-name <name>            default: current hostname
  --allowed-groups <list>           comma/semicolon-separated list
  --ssh-allowed-groups <list>       comma/semicolon-separated list
  --sudo-group <group>              AD group to grant sudo
  --sudo-apps <list>                comma/semicolon-separated list of apps
  --admin-user <user>               domain admin user (skip prompt)
  --federated-domains <list>        extra kerberos domains, e.g. "smpp.local"
  --set-fqdn                        set system hostname to FQDN before join
  --fqdn <host.domain>              explicit FQDN (used with --set-fqdn)
  -h, --help                        show this help
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local ts
  ts="$(date +%Y%m%d%H%M%S)"
  cp -n "$f" "${f}.bak-${ts}" || true
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

escape_allowgroup() {
  local s="$1"
  s="${s// /\\ }"
  printf '%s' "$s"
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
    if ! echo "$line" | grep -qw files; then
      if echo "$line" | grep -qw sss; then
        sed -i -E 's|^[[:space:]]*automount:.*|automount: files sss|' "$f"
      else
        sed -i -E 's|^[[:space:]]*automount:.*|automount: files|' "$f"
      fi
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

  chown root:root "$f"
  chmod 600 "$f"
}

ensure_pam_session_lines() {
  local cs="/etc/pam.d/common-session"
  [[ -f "$cs" ]] || die "Missing $cs"
  backup_file "$cs"

  grep -qE '^[[:space:]]*session[[:space:]]+.*pam_mkhomedir\.so' "$cs" || \
    echo "session required pam_mkhomedir.so skel=/etc/skel/ umask=0022" >>"$cs"

  grep -qE '^[[:space:]]*session[[:space:]]+.*pam_sss\.so' "$cs" || \
    echo "session required pam_sss.so" >>"$cs"

  grep -qE '^[[:space:]]*session[[:space:]]+.*pam_keyinit\.so' "$cs" || \
    echo "session optional pam_keyinit.so force revoke" >>"$cs"
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
  if systemctl list-unit-files --type=service | grep -q '^ssh\.service'; then
    systemctl restart ssh
  elif systemctl list-unit-files --type=service | grep -q '^sshd\.service'; then
    systemctl restart sshd
  else
    die "Neither ssh.service nor sshd.service found"
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

# Root check
[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Please run this script as root."

# Parse CLI args
while (($# > 0)); do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --computer-name) COMPUTER_NAME="${2:-}"; shift 2 ;;
    --allowed-groups) ALLOWED_GROUPS_RAW="${2:-}"; shift 2 ;;
    --ssh-allowed-groups) SSH_ALLOWED_GROUPS_RAW="${2:-}"; shift 2 ;;
    --sudo-group) SUDO_AD_GROUP="${2:-}"; shift 2 ;;
    --sudo-apps) SUDO_APPS_RAW="${2:-}"; shift 2 ;;
    --admin-user) ADMIN_USER="${2:-}"; shift 2 ;;
    --federated-domains) FEDERATED_DOMAINS_RAW="${2:-}"; shift 2 ;;
    --set-fqdn) SET_FQDN="yes"; shift 1 ;;
    --fqdn) FQDN_OVERRIDE="${2:-}"; shift 2 ;;
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
SSH_ALLOWED_GROUPS=()
SUDO_APPS=("/usr/bin/systemctl" "/usr/bin/journalctl")
FEDERATED_DOMAINS=()

[[ -n "$ALLOWED_GROUPS_RAW" ]] && parse_list "$ALLOWED_GROUPS_RAW" ALLOWED_GROUPS
[[ -n "$SSH_ALLOWED_GROUPS_RAW" ]] && parse_list "$SSH_ALLOWED_GROUPS_RAW" SSH_ALLOWED_GROUPS
[[ -n "$SUDO_APPS_RAW" ]] && SUDO_APPS=() && parse_list "$SUDO_APPS_RAW" SUDO_APPS
[[ -n "$FEDERATED_DOMAINS_RAW" ]] && parse_list "$FEDERATED_DOMAINS_RAW" FEDERATED_DOMAINS

if ((${#SSH_ALLOWED_GROUPS[@]} == 0)); then
  SSH_ALLOWED_GROUPS=("${ALLOWED_GROUPS[@]}")
fi
(( ${#ALLOWED_GROUPS[@]} > 0 )) || die "Please provide --allowed-groups with at least one AD group."

echo "Domain: $DOMAIN_LOWER"
echo "Realm: $REALM"
echo "Computer Name: $COMPUTER_NAME"
echo "Allowed login groups: ${ALLOWED_GROUPS[*]}"
echo "SSH allowed groups: ${SSH_ALLOWED_GROUPS[*]}"

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

if ((${#SSH_ALLOWED_GROUPS[@]} > 0)); then
  ALLOW_GROUP_TOKENS=()
  for grp in "${SSH_ALLOWED_GROUPS[@]}"; do
    ALLOW_GROUP_TOKENS+=("$(escape_allowgroup "$grp")")
  done
  ALLOW_GROUP_LINE="AllowGroups ${ALLOW_GROUP_TOKENS[*]}"
  if grep -qE '^[[:space:]]*AllowGroups[[:space:]]+' "$SSHD_CONFIG"; then
    sed -i -E "s|^[[:space:]]*AllowGroups[[:space:]]+.*|${ALLOW_GROUP_LINE}|" "$SSHD_CONFIG"
  else
    echo "$ALLOW_GROUP_LINE" >>"$SSHD_CONFIG"
  fi
fi

restart_ssh_service

if [[ -n "$SUDO_AD_GROUP" ]]; then
  SUDOERS_FILE="/etc/sudoers.d/$SUDO_AD_GROUP"
  echo "%$SUDO_AD_GROUP ALL=(ALL) NOPASSWD: ${SUDO_APPS[*]}" >"$SUDOERS_FILE"
  chmod 440 "$SUDOERS_FILE"
  if have_cmd visudo; then
    visudo -cf "$SUDOERS_FILE" >/dev/null
  fi
fi

echo "=============================="
echo "Active Directory join complete."
echo "Domain: $DOMAIN_LOWER"
echo "Realm: $REALM"
echo "Configured NSS: passwd/group/shadow + sss, automount: files"
echo "Configured Kerberos cache: KEYRING:persistent:%{uid}"
if ((${#FEDERATED_DOMAINS[@]} > 0)); then
  echo "Configured additional krb5 domain_realm mappings: ${FEDERATED_DOMAINS[*]}"
fi
echo "Login access restricted to groups: ${ALLOWED_GROUPS[*]}"
echo "You can test as an AD user:"
echo "  klist"
echo "  id <ad-user>"
echo "=============================="
