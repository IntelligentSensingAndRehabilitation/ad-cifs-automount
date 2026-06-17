#!/usr/bin/env bash
# check-ad-overlap.sh
# Compares local user accounts against AD to find overlapping usernames.
# Run AFTER domain join (requires SSSD to be active for AD lookups).
#
# Usage:
#   sudo ./check-ad-overlap.sh                        # check all local human users
#   sudo ./check-ad-overlap.sh --domain smpp.local     # check against a specific domain
#   sudo ./check-ad-overlap.sh --min-uid 500           # lower uid threshold
#
# Output shows:
#   MATCH    — local user has a matching AD account (home dir will collide)
#   NO MATCH — local user has no AD counterpart (safe, no action needed)
#   SKIP     — system account or other reason to ignore

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.2.3"
MIN_UID=1000
DOMAIN=""

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  --domain <domain>    AD domain to check against (default: auto-detect from SSSD)
  --min-uid <uid>      Minimum uid to consider as a human user (default: 1000)
  -V, --version        Show script version
  -h, --help           Show this help
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────

while (($# > 0)); do
  case "$1" in
    --domain)   shift; DOMAIN="$1" ;;
    --min-uid)  shift; MIN_UID="$1" ;;
    -V|--version) echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
    -h|--help)    usage; exit 0 ;;
    -*)           die "Unknown option: $1" ;;
  esac
  shift
done

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

echo "Checking local users against AD domain: $DOMAIN"
echo ""

# Verify SSSD can resolve AD users
if ! systemctl is-active --quiet sssd 2>/dev/null; then
  die "SSSD is not running. Join the domain first, then run this script."
fi

# ── Gather local users from /etc/passwd directly ──────────────────

MATCH_USERS=()
NOMATCH_USERS=()
SKIP_USERS=()

printf "%-20s %-12s %-8s %-14s %-8s %s\n" "USER" "LOCAL UID" "STATUS" "AD UID" "AD GID" "HOME DIR"
printf "%-20s %-12s %-8s %-14s %-8s %s\n" "----" "---------" "------" "------" "------" "--------"

while IFS=: read -r uname _ uid _ _ home _; do
  # Skip system accounts and nfsnobody
  if (( uid < MIN_UID )); then
    continue
  fi
  [[ "$uname" == "nfsnobody" ]] && continue
  [[ "$uname" == "nobody" ]] && continue

  # Try to resolve the user in AD using the explicit domain qualifier.
  # This bypasses SSSD's local-user shadowing and queries AD directly.
  ad_uid="$(id -u "${uname}@${DOMAIN}" 2>/dev/null)" || ad_uid=""
  ad_gid="$(id -g "${uname}@${DOMAIN}" 2>/dev/null)" || ad_gid=""

  home_dir="${home:-/home/$uname}"
  home_exists="no"
  [[ -d "$home_dir" ]] && home_exists="yes"

  if [[ -n "$ad_uid" ]]; then
    printf "%-20s %-12s %-8s %-14s %-8s %s" "$uname" "$uid" "MATCH" "$ad_uid" "$ad_gid" "$home_dir"
    if [[ "$home_exists" == "yes" ]]; then
      current_owner="$(stat -c '%u' "$home_dir")"
      if (( current_owner == ad_uid )); then
        printf " (already AD-owned)"
      else
        printf " (owned by uid %s, needs chown)" "$current_owner"
      fi
    else
      printf " (does not exist)"
    fi
    printf "\n"
    MATCH_USERS+=("$uname")
  else
    printf "%-20s %-12s %-8s %-14s %-8s %s\n" "$uname" "$uid" "NONE" "-" "-" "$home_dir"
    NOMATCH_USERS+=("$uname")
  fi

done < /etc/passwd

# ── Summary ───────────────────────────────────────────────────────

echo ""
echo "=============================="
echo "Domain: $DOMAIN"
echo "  AD matches:    ${#MATCH_USERS[@]}"
echo "  No AD account: ${#NOMATCH_USERS[@]}"

if (( ${#MATCH_USERS[@]} > 0 )); then
  echo ""
  echo "Users with matching AD accounts (will need home dir chown):"
  for u in "${MATCH_USERS[@]}"; do
    echo "  $u"
  done
  echo ""
  echo "To chown their home directories to AD ownership:"
  echo "  sudo ./post-join-chown-homes.sh ${MATCH_USERS[*]}"
  echo ""
  echo "Or preview first:"
  echo "  sudo ./post-join-chown-homes.sh --dry-run ${MATCH_USERS[*]}"
fi
