#!/usr/bin/env bash
# post-join-chown-homes.sh
# Run AFTER domain join while SSSD is active.
# Chowns existing local home directories to their AD uid/gid so that
# AD users inherit their old home dirs without needing to rename anything.
#
# Usage:
#   sudo ./post-join-chown-homes.sh                 # process all homes
#   sudo ./post-join-chown-homes.sh user1 user2     # specific users only
#   sudo ./post-join-chown-homes.sh --dry-run       # preview without changes
#
# How it works:
#   After SSSD is active, `id <user>` returns the AD uid (typically > 100000000).
#   This script detects home dirs still owned by the old local uid and chowns them
#   to the AD uid/gid. When the AD user next logs in, pam_mkhomedir sees the
#   directory already exists and skips creation — everything just works.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.2.3"
HOME_BASE="/home"
DRY_RUN="no"
DOMAIN=""
# SSSD-mapped AD uids are well above local uids (typically millions)
AD_UID_MIN=100000
USERS=()

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME [options] [user1 user2 ...]

If no users are specified, all directories under $HOME_BASE are checked.

Options:
  --domain <domain>    AD domain (default: auto-detect from SSSD)
  --dry-run            Show what would happen without making changes
  --home-base <path>   Home directory base (default: /home)
  -V, --version        Show script version
  -h, --help           Show this help
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────

while (($# > 0)); do
  case "$1" in
    --domain)     shift; DOMAIN="$1" ;;
    --dry-run)    DRY_RUN="yes" ;;
    --home-base)  shift; HOME_BASE="$1" ;;
    -V|--version) echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
    -h|--help)    usage; exit 0 ;;
    -*)           die "Unknown option: $1" ;;
    *)            USERS+=("$1") ;;
  esac
  shift
done

[[ "$(id -u)" -eq 0 ]] || die "This script must be run as root (sudo)."

# Verify SSSD is running — if it's not, `id` won't return AD uids
if ! systemctl is-active --quiet sssd 2>/dev/null; then
  die "SSSD is not running. Join the domain first, then run this script."
fi

# ── Detect domain ─────────────────────────────────────────────────

if [[ -z "$DOMAIN" ]]; then
  if command -v realm >/dev/null 2>&1; then
    DOMAIN="$(realm list --name-only 2>/dev/null | head -1)" || true
  fi
  if [[ -z "$DOMAIN" ]] && [[ -f /etc/sssd/sssd.conf ]]; then
    DOMAIN="$(awk -F= '/^\s*domains\s*=/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' /etc/sssd/sssd.conf)" || true
  fi
  [[ -n "$DOMAIN" ]] || die "Could not auto-detect AD domain. Use --domain <domain>."
fi

echo "Using AD domain: $DOMAIN"
echo ""

# ── Build user list if not specified ──────────────────────────────

if (( ${#USERS[@]} == 0 )); then
  for home_dir in "${HOME_BASE}"/*/; do
    [[ -d "$home_dir" ]] || continue
    user="$(basename "$home_dir")"
    # Skip directories ending in .local (from pre-join-migrate-homes.sh)
    [[ "$user" == *.local ]] && continue
    USERS+=("$user")
  done
fi

(( ${#USERS[@]} > 0 )) || die "No home directories found under $HOME_BASE."

# ── Process each user ─────────────────────────────────────────────

CHOWNED=()
SKIPPED=()
FAILED=()

for user in "${USERS[@]}"; do
  home_dir="${HOME_BASE}/${user}"

  if [[ ! -d "$home_dir" ]]; then
    echo "SKIP   $user — $home_dir does not exist"
    SKIPPED+=("$user (no home dir)")
    continue
  fi

  # Resolve the user's AD uid using the domain-qualified name.
  # Plain `id kshah` returns the local uid (from /etc/passwd) because
  # nsswitch checks "files" before "sss". Using `id kshah@domain`
  # forces SSSD to query AD directly.
  ad_uid="$(id -u "${user}@${DOMAIN}" 2>/dev/null)" || {
    echo "SKIP   $user — no matching AD account (${user}@${DOMAIN} not found)"
    SKIPPED+=("$user (no AD account)")
    continue
  }

  ad_gid="$(id -g "${user}@${DOMAIN}" 2>/dev/null)" || {
    echo "SKIP   $user — could not resolve AD gid"
    SKIPPED+=("$user (unknown AD gid)")
    continue
  }

  # Sanity check — AD uids should be well above local uids
  if (( ad_uid < AD_UID_MIN )); then
    echo "SKIP   $user — uid $ad_uid unexpectedly low for an AD account"
    SKIPPED+=("$user (unexpected uid $ad_uid)")
    continue
  fi

  # Check current ownership
  current_uid="$(stat -c '%u' "$home_dir")"
  current_gid="$(stat -c '%g' "$home_dir")"

  if (( current_uid == ad_uid && current_gid == ad_gid )); then
    echo "OK     $user — $home_dir already owned by ${ad_uid}:${ad_gid}"
    SKIPPED+=("$user (already correct)")
    continue
  fi

  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "WOULD  $user — chown ${current_uid}:${current_gid} -> ${ad_uid}:${ad_gid}  $home_dir"
    CHOWNED+=("$user")
    continue
  fi

  echo "CHOWN  $user — ${current_uid}:${current_gid} -> ${ad_uid}:${ad_gid}  $home_dir"
  if chown -R "${ad_uid}:${ad_gid}" "$home_dir"; then
    CHOWNED+=("$user")
  else
    echo "  FAIL — chown failed for $home_dir"
    FAILED+=("$user")
  fi
done

# ── Summary ───────────────────────────────────────────────────────

echo ""
echo "=============================="
if [[ "$DRY_RUN" == "yes" ]]; then
  echo "DRY RUN — no changes were made."
else
  echo "Complete."
fi
echo "  Chowned: ${#CHOWNED[@]}"
echo "  Skipped: ${#SKIPPED[@]}"
if (( ${#FAILED[@]} > 0 )); then
  echo "  Failed:  ${#FAILED[@]}"
  for f in "${FAILED[@]}"; do
    echo "    - $f"
  done
fi
