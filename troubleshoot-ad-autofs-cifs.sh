#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

SERVER_HOST=""
SHARE=""
MAP_NAME=""
DO_FIX="no"
VERBOSE="no"

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME --server-host <hostname> [--share <//host/share>] [--autofs-map-name <name>] [--fix] [--verbose]

Examples:
  $SCRIPT_NAME --server-host hostname.mydomain.local --share //hostname.mydomain.local/MyShare
  sudo $SCRIPT_NAME --server-host hostname.mydomain.local --autofs-map-name MyShare --fix
EOF
}

while (($# > 0)); do
  case "$1" in
    --server-host) SERVER_HOST="$2"; shift 2;;
    --share) SHARE="$2"; shift 2;;
    --autofs-map-name) MAP_NAME="$2"; shift 2;;
    --fix) DO_FIX="yes"; shift 1;;
    --verbose) VERBOSE="yes"; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if [[ -z "$SERVER_HOST" ]]; then
  echo "ERROR: --server-host is required" >&2
  usage
  exit 1
fi

IS_ROOT="no"
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  IS_ROOT="yes"
fi

have_cmd() { command -v "$1" >/dev/null 2>&1; }

if have_cmd tput && [[ -n "${TERM:-}" ]]; then
  C_RESET="$(tput sgr0 || true)"
  C_RED="$(tput setaf 1 || true)"
  C_GREEN="$(tput setaf 2 || true)"
  C_YELLOW="$(tput setaf 3 || true)"
  C_BLUE="$(tput setaf 4 || true)"
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
fi

status_line() {
  local status="$1"; shift
  local msg="$*"
  case "$status" in
    PASS) echo "${C_GREEN}PASS${C_RESET} - $msg";;
    WARN) echo "${C_YELLOW}WARN${C_RESET} - $msg";;
    FAIL) echo "${C_RED}FAIL${C_RESET} - $msg";;
    SKIP) echo "${C_BLUE}SKIP${C_RESET} - $msg";;
    *) echo "$status - $msg";;
  esac
}

section() {
  echo
  echo "== $* =="
}

mask_sssd_value() {
  local key="$1" value="$2"
  case "$key" in
    ldap_default_authtok*|ldap_default_authtok_type*|krb5_server*|ldap_uri*|ad_server*|ldap_sasl_authid*)
      echo "<redacted>"
      ;;
    *)
      echo "$value"
      ;;
  esac
}

pkg_check() {
  local pkg="$1"
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    local ver
    ver="$(dpkg -s "$pkg" | awk -F': ' '$1=="Version"{print $2}')"
    status_line PASS "$pkg installed ($ver)"
  else
    status_line FAIL "$pkg not installed (install: sudo apt-get install -y $pkg)"
  fi
}

svc_check() {
  local svc="$1"
  if systemctl list-unit-files --type=service | grep -qE "^${svc}\\.service"; then
    if systemctl is-active --quiet "$svc"; then
      status_line PASS "$svc active"
    else
      status_line WARN "$svc not active (check: systemctl status $svc)"
    fi
    if [[ "$VERBOSE" == "yes" ]]; then
      echo "-- journalctl -u $svc (last 30 lines) --"
      journalctl -u "$svc" -n 30 --no-pager 2>/dev/null || true
    fi
  else
    status_line WARN "$svc service not found"
  fi
}

fix_nsswitch_automount() {
  local f="/etc/nsswitch.conf"
  [[ -f "$f" ]] || { status_line FAIL "Missing $f"; return; }

  local line
  line="$(grep -E '^[[:space:]]*automount:' "$f" | head -n1 || true)"
  if [[ -z "$line" ]]; then
    status_line WARN "No automount line in $f"
    if [[ "$DO_FIX" == "yes" && "$IS_ROOT" == "yes" ]]; then
      echo "automount: files" >>"$f"
      status_line PASS "Added 'automount: files' to $f"
    else
      echo "Fix: echo 'automount: files' | sudo tee -a $f"
    fi
    return
  fi

  if echo "$line" | grep -qw files; then
    status_line PASS "automount line includes files"
  else
    status_line WARN "automount line missing files: $line"
    if [[ "$DO_FIX" == "yes" && "$IS_ROOT" == "yes" ]]; then
      if echo "$line" | grep -qw sss; then
        sed -i -E 's/^[[:space:]]*automount:.*/automount: files sss/' "$f"
      else
        sed -i -E 's/^[[:space:]]*automount:.*/automount: files/' "$f"
      fi
      status_line PASS "Updated automount line to include files"
    else
      echo "Fix: sudo sed -i -E 's/^[[:space:]]*automount:.*/automount: files sss/' $f"
    fi
  fi
}

fix_autofs_default_options() {
  local f="/etc/default/autofs"
  if [[ -f "$f" ]]; then
    if grep -qE '^[[:space:]]*OPTIONS=' "$f"; then
      status_line PASS "$f has OPTIONS defined"
    else
      status_line WARN "$f missing OPTIONS (systemd warning likely)"
      if [[ "$DO_FIX" == "yes" && "$IS_ROOT" == "yes" ]]; then
        echo 'OPTIONS=""' >>"$f"
        status_line PASS "Added OPTIONS=\"\" to $f"
      else
        echo "Fix: echo 'OPTIONS=\"\"' | sudo tee -a $f"
      fi
    fi
  else
    status_line WARN "$f missing"
    if [[ "$DO_FIX" == "yes" && "$IS_ROOT" == "yes" ]]; then
      echo 'OPTIONS=""' >"$f"
      status_line PASS "Created $f with OPTIONS=\"\""
    else
      echo "Fix: echo 'OPTIONS=\"\"' | sudo tee $f"
    fi
  fi
}

fix_auto_master_include() {
  local f="/etc/auto.master"
  [[ -f "$f" ]] || { status_line FAIL "Missing $f"; return; }
  if grep -Eq '^[[:space:]]*(\+dir:/etc/auto\.master\.d|/\. /etc/auto\.master\.d|/etc/auto\.master\.d)' "$f"; then
    status_line PASS "$f includes /etc/auto.master.d"
  else
    status_line WARN "$f missing include for /etc/auto.master.d"
    if [[ "$DO_FIX" == "yes" && "$IS_ROOT" == "yes" ]]; then
      echo "+dir:/etc/auto.master.d" >>"$f"
      status_line PASS "Added +dir:/etc/auto.master.d to $f"
    else
      echo "Fix: echo '+dir:/etc/auto.master.d' | sudo tee -a $f"
    fi
  fi
}

get_share_host() {
  local share="$1"
  echo "$share" | sed -E 's|^//||; s|/.*||'
}

get_short_host() {
  local host="$1"
  echo "$host" | cut -d. -f1
}

section "Package checks"
for p in sssd realmd adcli krb5-user cifs-utils keyutils autofs; do
  pkg_check "$p"
done

section "Service checks"
svc_check sssd
svc_check ssh
svc_check sshd
svc_check autofs

section "SSH config checks"
SSHD_CFG="/etc/ssh/sshd_config"
if [[ -f "$SSHD_CFG" ]]; then
  local_usepam="$(grep -Ei '^[[:space:]]*UsePAM' "$SSHD_CFG" | tail -n1 || true)"
  local_gssapi="$(grep -Ei '^[[:space:]]*GSSAPIAuthentication' "$SSHD_CFG" | tail -n1 || true)"
  local_gsscleanup="$(grep -Ei '^[[:space:]]*GSSAPICleanupCredentials' "$SSHD_CFG" | tail -n1 || true)"
  local_allowgroups="$(grep -Ei '^[[:space:]]*AllowGroups' "$SSHD_CFG" | tail -n1 || true)"

  [[ -n "$local_usepam" ]] && status_line PASS "UsePAM: $local_usepam" || status_line WARN "UsePAM not set (recommend: UsePAM yes)"
  [[ -n "$local_gssapi" ]] && status_line PASS "GSSAPIAuthentication: $local_gssapi" || status_line WARN "GSSAPIAuthentication not set"
  [[ -n "$local_gsscleanup" ]] && status_line PASS "GSSAPICleanupCredentials: $local_gsscleanup" || status_line WARN "GSSAPICleanupCredentials not set"
  [[ -n "$local_allowgroups" ]] && status_line PASS "AllowGroups: $local_allowgroups" || status_line WARN "AllowGroups not set"

  if [[ -n "$local_usepam" ]] && ! echo "$local_usepam" | grep -qiE 'UsePAM[[:space:]]+yes'; then
    status_line WARN "UsePAM is not yes (Kerberos/PAM session handling may fail)"
    echo "Suggestion: set 'UsePAM yes' and restart sshd"
  fi
else
  status_line FAIL "Missing $SSHD_CFG"
fi

section "PAM checks"
PAM_FILES=(/etc/pam.d/common-auth /etc/pam.d/common-account /etc/pam.d/common-session)
for f in "${PAM_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    if grep -qE '^[[:space:]]*auth.*pam_sss.so' "$f" || grep -qE '^[[:space:]]*account.*pam_sss.so' "$f" || grep -qE '^[[:space:]]*session.*pam_sss.so' "$f"; then
      status_line PASS "pam_sss.so present in $f"
    else
      status_line WARN "pam_sss.so not found in $f"
    fi
  else
    status_line WARN "Missing $f"
  fi
done

if [[ -f /etc/pam.d/common-session ]]; then
  if grep -qE '^[[:space:]]*session[[:space:]]+optional[[:space:]]+pam_sss\.so' /etc/pam.d/common-session; then
    status_line WARN "common-session uses 'session optional pam_sss.so' (Kerberos keyring may not populate)"
    echo "Suggestion: use 'session required pam_sss.so' or add to sshd PAM"
  fi
fi

section "SSSD checks"
SSSD_CONF="/etc/sssd/sssd.conf"
if [[ -f "$SSSD_CONF" ]]; then
  perms="$(stat -c '%a %U:%G' "$SSSD_CONF" 2>/dev/null || true)"
  if [[ "$perms" == "600 root:root" ]]; then
    status_line PASS "$SSSD_CONF perms $perms"
  else
    status_line WARN "$SSSD_CONF perms $perms (recommend 600 root:root)"
  fi

  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([a-zA-Z0-9_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      case "$key" in
        id_provider|auth_provider|access_provider|use_fully_qualified_names|fallback_homedir|krb5_realm|ad_domain|krb5_ccname_template|ldap_use_tokengroups)
          safe_val="$(mask_sssd_value "$key" "$val")"
          echo "  $key = $safe_val"
          ;;
      esac
    fi
  done < "$SSSD_CONF"

  if grep -qiE '^[[:space:]]*krb5_ccname_template[[:space:]]*=[[:space:]]*KEYRING:persistent:%U' "$SSSD_CONF"; then
    status_line PASS "krb5_ccname_template uses KEYRING:persistent:%U"
  else
    status_line WARN "krb5_ccname_template not set to KEYRING:persistent:%U"
    echo "Suggest: krb5_ccname_template = KEYRING:persistent:%U"
  fi
else
  status_line FAIL "Missing $SSSD_CONF"
fi

section "Kerberos checks (user-level)"
if have_cmd klist; then
  if klist >/dev/null 2>&1; then
    cache_line="$(klist | grep -E '^Ticket cache:' || true)"
    principal_line="$(klist | grep -E '^Default principal:' || true)"
    [[ -n "$cache_line" ]] && status_line PASS "$cache_line" || status_line WARN "No ticket cache line from klist"
    [[ -n "$principal_line" ]] && status_line PASS "$principal_line" || status_line WARN "No default principal line from klist"

    if echo "$cache_line" | grep -qi 'KEYRING'; then
      status_line PASS "Ticket cache is KEYRING"
    else
      status_line WARN "Ticket cache not KEYRING (CIFS multiuser may fail)"
      echo "Fix: set krb5_ccname_template = KEYRING:persistent:%U in sssd.conf"
      echo "Fix: ensure PAM session uses pam_sss.so (required)"
      echo "Then log out and back in"
    fi
  else
    status_line WARN "klist failed (no ticket?)"
  fi
else
  status_line WARN "klist not found"
fi

if have_cmd keyctl; then
  if keyctl list @u >/dev/null 2>&1; then
    if keyctl list @u | grep -q 'keyring'; then
      status_line PASS "keyctl user keyring non-empty"
    else
      status_line WARN "keyctl user keyring empty"
    fi
  else
    status_line WARN "keyctl list @u failed (run as logged-in user)"
  fi
else
  status_line WARN "keyctl not found"
fi

section "SPN/DNS checks"
SHORT_HOST="$(get_short_host "$SERVER_HOST")"
if have_cmd kvno; then
  if kvno "cifs/${SERVER_HOST}" >/dev/null 2>&1; then
    status_line PASS "kvno cifs/$SERVER_HOST succeeded"
  else
    status_line WARN "kvno cifs/$SERVER_HOST failed (SPN missing or wrong hostname)"
  fi
  if kvno "cifs/${SHORT_HOST}" >/dev/null 2>&1; then
    status_line PASS "kvno cifs/$SHORT_HOST succeeded"
  else
    status_line WARN "kvno cifs/$SHORT_HOST failed (SPN missing or wrong hostname)"
  fi
else
  status_line WARN "kvno not found (install krb5-user)"
fi

if have_cmd dig; then
  dns_out="$(dig +short "$SERVER_HOST" | head -n1 || true)"
  if [[ "$dns_out" == CNAME* ]]; then
    status_line WARN "$SERVER_HOST is a CNAME ($dns_out); Kerberos does not follow CNAME"
  else
    status_line PASS "$SERVER_HOST resolves to: $dns_out"
  fi
else
  status_line WARN "dig not found (install dnsutils)"
fi

if [[ -n "$SHARE" ]]; then
  share_host="$(get_share_host "$SHARE")"
  if [[ "$share_host" != "$SERVER_HOST" ]]; then
    status_line WARN "Share host ($share_host) != server-host ($SERVER_HOST)"
  else
    status_line PASS "Share host matches server-host"
  fi
fi

section "autofs checks"
fix_nsswitch_automount
fix_auto_master_include

if [[ -f /etc/auto.master ]]; then
  map_file=""
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue
    if echo "$line" | grep -qw "$MAP_NAME"; then
      map_file="$(echo "$line" | awk '{print $2}')"
      break
    fi
  done < /etc/auto.master

  if [[ -n "$map_file" ]]; then
    status_line PASS "Found map entry referencing $MAP_NAME ($map_file)"
    if [[ "$map_file" =~ ^program: ]]; then
      prog_path="${map_file#program:}"
      if [[ -x "$prog_path" ]]; then
        status_line PASS "Program map executable: $prog_path"
      else
        status_line WARN "Program map not executable: $prog_path (chmod +x)"
      fi
    fi
  else
    status_line WARN "No /etc/auto.master entry for $MAP_NAME"
  fi
fi

if mount | grep -q ' type autofs '; then
  status_line PASS "autofs mounts present"
  mount | grep ' type autofs ' || true
else
  status_line WARN "No autofs mounts found"
fi

section "CIFS runtime checks"
if [[ "$IS_ROOT" == "yes" ]]; then
  if [[ -r /proc/fs/cifs/DebugData ]]; then
    status_line PASS "Read /proc/fs/cifs/DebugData"
    sed -n '1,120p' /proc/fs/cifs/DebugData
  else
    status_line WARN "/proc/fs/cifs/DebugData missing"
  fi

  if have_cmd dmesg; then
    cifs_err="$(dmesg -T 2>/dev/null | grep -Ei 'cifs_mount failed|SessSetup = -126|SessSetup = -5' | tail -n 10 || true)"
    if [[ -n "$cifs_err" ]]; then
      status_line WARN "Recent CIFS errors in dmesg"
      echo "$cifs_err"
      echo "Interpretation: -126 often means missing Kerberos ticket or keyutils; -5 can indicate auth/session setup failure."
    else
      status_line PASS "No recent CIFS errors in dmesg"
    fi
  else
    status_line WARN "dmesg not found"
  fi

  if [[ -r /proc/fs/cifs/SupportedDialects ]]; then
    status_line PASS "SupportedDialects available"
    cat /proc/fs/cifs/SupportedDialects
  else
    status_line WARN "SupportedDialects missing"
  fi
else
  status_line SKIP "CIFS runtime checks require root"
  echo "Run with sudo for /proc/fs/cifs and dmesg parsing."
fi

section "Systemd autofs OPTIONS warning"
fix_autofs_default_options

section "Result summary"
echo "Top likely root causes and next steps:"
echo "1) Kerberos ticket cache not in KEYRING or empty user keyring -> set krb5_ccname_template, ensure PAM session uses pam_sss.so, re-login."
echo "2) autofs maps resolving via SSSD only -> ensure /etc/nsswitch.conf has 'automount: files' and /etc/auto.master includes /etc/auto.master.d."
echo "3) SPN/DNS mismatch (CNAME or wrong host in share) -> use the hostname with a matching cifs/<host> SPN."

section "Directed troubleshooting path (federated domain / Isilon)"
echo "1) Validate CIFS SPN for the exact hostname used in the share:"
echo "   kvno cifs/${SERVER_HOST}"
echo "2) If ${SERVER_HOST} is a CNAME, Kerberos will NOT follow it:"
echo "   dig +short ${SERVER_HOST}"
echo "   kvno cifs/<canonical-hostname-from-dig>"
echo "3) Verify cross-domain Kerberos resolution:"
echo "   klist"
echo "   kvno cifs/${SERVER_HOST}"
echo "4) Validate the mount really uses Kerberos (no NTLM):"
echo "   mount -t cifs -o sec=krb5,cruid=\$(id -u),vers=3.0 //${SERVER_HOST}/<Share> /mnt/test"
echo "5) Confirm KEYRING cache for CIFS multiuser:"
echo "   klist | head -n1"
echo "   keyctl list @u"
