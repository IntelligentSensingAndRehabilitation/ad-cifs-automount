#!/usr/bin/env bash
# automount-manager.sh
# Ubuntu-focused helper to add/list/delete Kerberos CIFS autofs mounts.
#
# Creates mounts like:
#   /autofs/<name>/<key>  -> //server/share
# and (optionally) can create a user-friendly symlink profile script, if you want.
#
# Examples:
#   sudo ./automount-manager.sh add cottonlab //fs2.mydomain.local/CottonLab
#   sudo ./automount-manager.sh list
#   sudo ./automount-manager.sh del cottonlab
#
# Notes:
# - This script does NOT join the machine to AD or configure SSSD. It assumes Kerberos/SSSD is already working.
# - Uses autofs maps under /etc/auto.master.d and /etc/auto.<name>

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

AUTOFSD_DIR="/etc/auto.master.d"
AUTOFSD_PREFIX="amgr"
AUTOFS_ROOT_BASE="/autofs"
GLOBAL_LINKER="/etc/profile.d/automount-links.sh"

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME add <name> <cifs_share> [--root <path>] [--timeout <sec>] [--no-ghost]
  $SCRIPT_NAME del <name>
  $SCRIPT_NAME list
  $SCRIPT_NAME check [<name>]

Arguments:
  <name>       Short name for the mount (letters/numbers/_/-), e.g. cottonlab
  <cifs_share> CIFS share in the form //server.domain.local/Share or //server/Share

Options for 'add':
  --root <path>     Autofs root directory for this mount (default: ${AUTOFS_ROOT_BASE}/<name>)
  --timeout <sec>   Autofs timeout in seconds (default: 300)
  --no-ghost        Do not use --ghost (default: ghost enabled)

Command 'check':
  With no <name>, validates overall config and all managed mounts.
  With <name>, validates only that mount.

What it creates (default):
  Master map: ${AUTOFSD_DIR}/${AUTOFSD_PREFIX}-<name>.autofs
  Map file:   /etc/auto.<name>
  Root dir:   ${AUTOFS_ROOT_BASE}/<name>

Default map behavior:
  Any key triggers mount, e.g.:
    ls /autofs/<name>/<your_ad_username>
  This is ideal for per-user access patterns and symlink integration.

EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Must run as root. Try: sudo $SCRIPT_NAME ..."
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local ts
  ts="$(date +%Y%m%d%H%M%S)"
  cp -n "$f" "${f}.bak-${ts}" || true
}

is_ubuntu() {
  [[ -f /etc/os-release ]] && grep -qiE '^ID=ubuntu|^ID_LIKE=.*debian' /etc/os-release
}

validate_name() {
  local name="$1"
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid name '$name'. Use only letters, numbers, underscore, dash."
}

check_cmd() {
  command -v "$1" >/dev/null 2>&1
}

pkg_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

ensure_packages() {
  # Minimal packages for autofs + CIFS + Kerberos-backed mounts
  local pkgs=(autofs cifs-utils keyutils krb5-user)
  local missing=()
  for p in "${pkgs[@]}"; do
    pkg_installed "$p" || missing+=("$p")
  done

  if ((${#missing[@]} > 0)); then
    echo "Installing missing packages: ${missing[*]}"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  fi

  # Basic sanity checks
  check_cmd automount || die "autofs installed but 'automount' not found in PATH"
  check_cmd mount.cifs || die "cifs-utils installed but 'mount.cifs' not found"
  check_cmd klist || echo "WARN: 'klist' not found (krb5-user). Kerberos mounts may fail for users."
}

ensure_nsswitch_automount_files() {
  # autofs commonly fails if automount is only 'sss' and no LDAP map exists.
  # We ensure 'files' is present.
  local f="/etc/nsswitch.conf"
  [[ -f "$f" ]] || die "Missing $f"
  backup_file "$f"

  if ! grep -qE '^[[:space:]]*automount:' "$f"; then
    echo "Adding 'automount: files' to $f"
    echo "automount: files" >>"$f"
    return
  fi

  local line
  line="$(grep -E '^[[:space:]]*automount:' "$f" | head -n1)"
  if ! echo "$line" | grep -qw "files"; then
    echo "Updating $f to include 'files' for automount maps"
    # Replace line with "automount: files sss" if sss was present, else "automount: files"
    if echo "$line" | grep -qw "sss"; then
      sed -i -E 's/^[[:space:]]*automount:.*/automount: files sss/' "$f"
    else
      sed -i -E 's/^[[:space:]]*automount:.*/automount: files/' "$f"
    fi
  fi
}

ensure_master_dir_include() {
  # Make sure /etc/auto.master is including /etc/auto.master.d so our master map is read.
  local master="/etc/auto.master"
  [[ -f "$master" ]] || die "Missing $master"
  backup_file "$master"

  if grep -Eq '^[[:space:]]*(\+dir:/etc/auto\.master\.d|/\. /etc/auto\.master\.d|/etc/auto\.master\.d)' "$master"; then
    return
  fi

  echo "Adding include for ${AUTOFSD_DIR} to $master"
  echo "+dir:${AUTOFSD_DIR}" >>"$master"
}

ensure_host_reachable() {
  local host="$1"
  [[ -n "$host" ]] || die "Cannot check reachability: host is empty"

  if getent hosts "$host" >/dev/null 2>&1; then
    echo "Host reachable (DNS): $host"
  else
    die "Host '$host' not resolvable; fix DNS before adding this mount"
  fi

  # Best-effort TCP 445 probe if nc is available
  if check_cmd nc; then
    if nc -z -w2 "$host" 445 >/dev/null 2>&1; then
      echo "Host reachable (TCP 445): $host"
    else
      echo "WARN: TCP 445 to $host failed (may still work if blocked by firewall)"
    fi
  fi
}

ensure_domain_realm_mapping() {
  # Ensure krb5.conf maps a domain to the uppercase realm so Kerberos CIFS works.
  local domain="${1:-}"
  local krb="/etc/krb5.conf"
  [[ -n "$domain" ]] || domain="$(hostname -d 2>/dev/null || true)"
  [[ -n "$domain" ]] || { echo "WARN: cannot infer domain for krb5 mapping; skipping"; return 0; }
  local realm="${domain^^}"
  [[ -f "$krb" ]] || return 0

  if grep -qiE "^[[:space:]]*\\.${domain}[[:space:]]*=" "$krb" && grep -qiE "^[[:space:]]*${domain}[[:space:]]*=" "$krb"; then
    return
  fi

  backup_file "$krb"
  awk -v domain="$domain" -v realm="$realm" '
    BEGIN { in_dr=0; added=0 }
    /^\[domain_realm\]/ { in_dr=1; print; next }
    /^\[/ { in_dr=0 }
    {
      if (in_dr && !added) {
        print "  ."domain" = "realm
        print "  "domain" = "realm
        added=1
      }
      print
    }
    END {
      if (!added) {
        print "[domain_realm]"
        print "  ."domain" = "realm
        print "  "domain" = "realm
      }
    }
  ' "$krb" > "${krb}.tmp" && mv "${krb}.tmp" "$krb"
}

ensure_ccache_keyring() {
  # Ensure tickets go to the kernel keyring so CIFS multiuser can see them.
  local krb="/etc/krb5.conf"
  [[ -f "$krb" ]] || return 0

  if grep -qiE '^[[:space:]]*default_ccache_name[[:space:]]*=[[:space:]]*KEYRING:persistent:%\{uid\}' "$krb"; then
    return
  fi

  backup_file "$krb"
  awk '
    BEGIN { saw_lib=0; saw_cc=0 }
    /^\[libdefaults\]/ { saw_lib=1; print; next }
    /^\[/ { if (saw_lib && !saw_cc) { print "  default_ccache_name = KEYRING:persistent:%{uid}"; saw_cc=1 } }
    { print }
    END {
      if (!saw_lib) {
        print "[libdefaults]"
        saw_lib=1
      }
      if (!saw_cc) {
        print "  default_ccache_name = KEYRING:persistent:%{uid}"
      }
    }
  ' "$krb" > "${krb}.tmp" && mv "${krb}.tmp" "$krb"
}

restart_autofs() {
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl restart autofs
  systemctl --no-pager --full status autofs | sed -n '1,12p' || true
}

mk_master_map_file() {
  local name="$1" root="$2" timeout="$3" ghost="$4"
  local master="${AUTOFSD_DIR}/${AUTOFSD_PREFIX}-${name}.autofs"
  mkdir -p "$AUTOFSD_DIR"
  local opts="--timeout=${timeout}"
  [[ "$ghost" == "yes" ]] && opts="${opts} --ghost"

  cat >"$master" <<EOF
# Managed by ${SCRIPT_NAME}
${root}  program:/etc/auto.${name}  ${opts}
EOF

  chmod 644 "$master"
}

mk_map_file() {
  local name="$1" cifs_share="$2"
  local map="/etc/auto.${name}"

  # Program map so we can pass the caller UID into cruid for multiuser mounts.
  cat >"$map" <<EOF
#!/bin/sh
# Managed by automount-manager.sh
# Usage: program map called by autofs with key=\$1, UID env set to the requesting uid.
key=\$1
[ -z "\$key" ] && exit 1

cifs_share="${cifs_share}"
uid=\$(getent passwd "\$key" | cut -d: -f3)
[ -z "\$uid" ] && uid=\${UID:-0}

# For program maps, autofs knows the key; return only options/location.
echo "-fstype=cifs,sec=krb5,multiuser,cruid=\$uid,vers=3.0,noperm :\$cifs_share"
EOF

  chmod 755 "$map"
}

install_global_linker() {
  # Install a global profile hook that links each autofs share to ~/<share>
  # for the current user session. Uses POSIX sh, no Bash arrays.
  mkdir -p "$(dirname "$GLOBAL_LINKER")"
  cat >"$GLOBAL_LINKER" <<'EOF'
#!/bin/sh
AUTOHOME="/autofs"

[ -n "$USER" ] && [ -d "$HOME" ] || exit 0
[ -d "$AUTOHOME" ] || exit 0

for path in "$AUTOHOME"/*; do
  [ -d "$path" ] || continue
  share=${path##*/}
  target="$path/$USER"
  link="$HOME/$share"

  # Trigger autofs best-effort
  [ -d "$target" ] || ls "$target" >/dev/null 2>&1 || true

  [ -e "$link" ] && continue
  ln -s "$target" "$link" 2>/dev/null || true
done
EOF
  chmod 644 "$GLOBAL_LINKER"
}

add_mount() {
  need_root
  is_ubuntu || echo "WARN: This script is tuned for Ubuntu/Debian. Proceeding anyway."

  local name="$1"; shift
  local cifs_share="$1"; shift

  validate_name "$name"
  [[ "$cifs_share" =~ ^// ]] || die "CIFS share must start with // (example: //fs2.domain.local/Share)"

  local root="${AUTOFS_ROOT_BASE}/${name}"
  local timeout="300"
  local ghost="yes"

  while (($# > 0)); do
    case "$1" in
      --root) root="$2"; shift 2;;
      --timeout) timeout="$2"; shift 2;;
      --no-ghost) ghost="no"; shift 1;;
      *) die "Unknown option: $1";;
    esac
  done

  # Derive domain from the share host if possible (e.g., //host.domain/share)
  local host domain=""
  host="$(echo "$cifs_share" | sed -E 's|^//||; s|/.*||')"
  if [[ "$host" == *.* ]]; then
    domain="${host#*.}"
    [[ "$domain" == "$host" ]] && domain=""
  fi

  ensure_host_reachable "$host"
  ensure_packages
  ensure_nsswitch_automount_files
  ensure_master_dir_include
  ensure_domain_realm_mapping "$domain"
  ensure_ccache_keyring
  install_global_linker

  mkdir -p "$root"
  chmod 755 "$AUTOFS_ROOT_BASE" "$root" 2>/dev/null || true

  local master="${AUTOFSD_DIR}/${AUTOFSD_PREFIX}-${name}.autofs"
  local map="/etc/auto.${name}"

  if [[ -e "$master" || -e "$map" ]]; then
    die "Mount '${name}' already exists (found ${master} or ${map}). Use 'del' first."
  fi

  mk_master_map_file "$name" "$root" "$timeout" "$ghost"
  mk_map_file "$name" "$cifs_share"

  echo "Added autofs mount '${name}':"
  echo "  Root:   $root"
  echo "  Share:  $cifs_share"
  echo "  Master: $master"
  echo "  Map:    $map"
  echo "Restarting autofs..."
  restart_autofs

  echo
  echo "Test (as an AD user with a Kerberos ticket):"
  echo "  klist"
  echo "  ls ${root}/<your-username-or-key>"
  echo "Then verify:"
  echo "  mount | grep -E 'autofs|cifs'"

  echo
  echo "Tip: Global linker at ${GLOBAL_LINKER} creates ~/Lab1-style links for all autofs shares."
}

del_mount() {
  need_root
  local name="$1"
  validate_name "$name"

  local master="${AUTOFSD_DIR}/${AUTOFSD_PREFIX}-${name}.autofs"
  local map="/etc/auto.${name}"

  [[ -e "$master" || -e "$map" ]] || die "No such mount '${name}' (missing ${master} and ${map})."

  # Try to unmount any active autofs submounts for this root (best-effort).
  # Note: autofs will clean up, but we try to be neat.
  local root
  root="$(awk '{print $1}' "$master" 2>/dev/null | head -n1 || true)"

  if [[ -n "${root:-}" && -d "$root" ]]; then
    echo "Attempting to unmount $root ..."
    umount -l "$root" 2>/dev/null || true
  fi

  echo "Removing autofs mount '${name}'..."
  rm -f "$master" "$map"

  echo "Restarting autofs..."
  restart_autofs

  if [[ -n "${root:-}" && -d "$root" ]]; then
    if rmdir "$root" 2>/dev/null; then
      echo "Removed root directory: $root"
    else
      echo "NOTE: Root directory still exists: $root"
      echo "      Remove it manually if empty: sudo rmdir '$root'"
    fi
  fi
}

list_mounts() {
  need_root
  mkdir -p "$AUTOFSD_DIR"

  local masters
  masters=( "${AUTOFSD_DIR}/${AUTOFSD_PREFIX}-"*.autofs )
  if [[ "${masters[0]}" == "${AUTOFSD_DIR}/${AUTOFSD_PREFIX}-*.autofs" ]]; then
    echo "No mounts managed by ${SCRIPT_NAME} found in ${AUTOFSD_DIR}."
    return 0
  fi

  printf "%-20s %-30s %-45s\n" "NAME" "ROOT" "SHARE"
  printf "%-20s %-30s %-45s\n" "----" "----" "-----"

  local m name root map share
  for m in "${masters[@]}"; do
    name="$(basename "$m" | sed -E "s/^${AUTOFSD_PREFIX}-//; s/\.autofs$//")"
    root="$(awk '{print $1}' "$m" | head -n1)"
    map="$(awk '{print $2}' "$m" | head -n1)"
    if [[ -f "$map" ]]; then
      # Extract after ":" in the map line (the share)
      share="$(grep -E '^[[:space:]]*\*' "$map" | head -n1 | sed -E 's/.*://')"
    else
      share="(missing map: $map)"
    fi
    printf "%-20s %-30s %-45s\n" "$name" "$root" "$share"
  done

  echo
  echo "Active mounts (if any):"
  mount | grep -E ' type autofs | type cifs ' || echo "  (none)"
}

check_config() {
  need_root

  echo "[config] Packages:"
  local pkgs=(autofs cifs-utils keyutils krb5-user)
  local missing=()
  for p in "${pkgs[@]}"; do
    if pkg_installed "$p"; then
      echo "  OK  $p"
    else
      echo "  MISSING  $p"
      missing+=("$p")
    fi
  done
  ((${#missing[@]} == 0)) || echo "  -> Install: apt-get install -y ${missing[*]}"

  echo "[config] nsswitch automount:"
  if grep -qE '^[[:space:]]*automount:' /etc/nsswitch.conf && grep -qE '^[[:space:]]*automount:.*files' /etc/nsswitch.conf; then
    echo "  OK  automount: includes files"
  else
    echo "  FIX  Add 'automount: files' to /etc/nsswitch.conf"
  fi

  echo "[config] auto.master include:"
  if grep -Eq '^[[:space:]]*(\+dir:/etc/auto\.master\.d|/\. /etc/auto\.master\.d|/etc/auto\.master\.d)' /etc/auto.master; then
    echo "  OK  /etc/auto.master includes ${AUTOFSD_DIR}"
  else
    echo "  FIX  Add '+dir:${AUTOFSD_DIR}' to /etc/auto.master"
  fi

  echo "[config] krb5 domain_realm:"
  local domain realm
  domain="$(hostname -d 2>/dev/null || true)"
  if [[ -z "$domain" ]]; then
    echo "  WARN cannot infer domain (hostname -d empty); ensure /etc/krb5.conf has your AD domain mapped."
  else
    realm="${domain^^}"
    if grep -qiE "^[[:space:]]*\\.${domain}[[:space:]]*=" /etc/krb5.conf && grep -qiE "^[[:space:]]*${domain}[[:space:]]*=" /etc/krb5.conf; then
      echo "  OK  domain_realm entries for ${domain} -> ${realm}"
    else
      echo "  FIX  Add domain_realm mapping for ${domain} in /etc/krb5.conf"
    fi
  fi

  echo "[config] krb5 ccache keyring:"
  if grep -qiE '^[[:space:]]*default_ccache_name[[:space:]]*=[[:space:]]*KEYRING:persistent:%\{uid\}' /etc/krb5.conf; then
    echo "  OK  default_ccache_name uses KEYRING:persistent:%{uid}"
  else
    echo "  FIX  Set default_ccache_name = KEYRING:persistent:%{uid} in /etc/krb5.conf"
  fi

  echo "[service] autofs status:"
  systemctl is-active --quiet autofs && echo "  OK  autofs active" || echo "  WARN autofs inactive"
}

check_mount() {
  need_root
  local name="$1"
  validate_name "$name"

  local master="${AUTOFSD_DIR}/${AUTOFSD_PREFIX}-${name}.autofs"
  local map="/etc/auto.${name}"
  local ok=0

  echo "[mount:${name}] master/map:"
  if [[ -f "$master" ]]; then
    echo "  OK  master $master"
  else
    echo "  MISSING  master $master"
    ok=1
  fi
  if [[ -f "$map" ]]; then
    echo "  OK  map $map"
  else
    echo "  MISSING  map $map"
    ok=1
  fi

  local root share
  root="$(awk '!/^#/ && NF>=2 {print $1; exit}' "$master" 2>/dev/null)"
  share="$(grep -E '^[[:space:]]*\*' "$map" 2>/dev/null | head -n1 | sed -E 's/.*://')"

  [[ -n "$root" ]] && echo "  Root: $root" || echo "  Root: (unknown)"
  [[ -n "$share" ]] && echo "  Share: $share" || echo "  Share: (unknown)"

  if [[ -n "$root" && -d "$root" ]]; then
    echo "  OK  root directory exists"
  else
    echo "  WARN  root directory missing: $root"
  fi

  local profile="/etc/profile.d/${AUTOFSD_PREFIX}-${name}.sh"
  if [[ -f "$profile" ]]; then
    echo "  OK  profile link script present ($profile)"
  else
    echo "  INFO no profile link script ($profile)"
  fi

  return $ok
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    add)
      [[ $# -ge 3 ]] || { usage; exit 1; }
      add_mount "$2" "$3" "${@:4}"
      ;;
    del|delete|rm|remove)
      [[ $# -eq 2 ]] || { usage; exit 1; }
      del_mount "$2"
      ;;
    list|ls)
      [[ $# -eq 1 ]] || { usage; exit 1; }
      list_mounts
      ;;
    check)
      if [[ $# -gt 2 ]]; then usage; exit 1; fi
      check_config
      echo
      mkdir -p "$AUTOFSD_DIR"
      if [[ $# -eq 2 ]]; then
        check_mount "$2"
      else
        local masters
        masters=( "${AUTOFSD_DIR}/${AUTOFSD_PREFIX}-"*.autofs )
        if [[ "${masters[0]}" == "${AUTOFSD_DIR}/${AUTOFSD_PREFIX}-*.autofs" ]]; then
          echo "No mounts managed by ${SCRIPT_NAME} found in ${AUTOFSD_DIR}."
        else
          local m name
          for m in "${masters[@]}"; do
            name="$(basename "$m" | sed -E "s/^${AUTOFSD_PREFIX}-//; s/\.autofs$//")"
            check_mount "$name"
            echo
          done
        fi
      fi
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      die "Unknown command: $cmd"
      ;;
  esac
}

main "$@"
