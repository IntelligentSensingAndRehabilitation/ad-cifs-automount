#!/usr/bin/env bash
# pre-join-migrate-homes.sh
# Renames local home directories that will collide with AD usernames after domain join.
#
# Run BEFORE ubuntu-ad-join.sh on machines where local users share names with AD accounts.
#
# What it does:
#   1. For each username supplied, checks if /home/<user> exists and is owned by a local (non-AD) user.
#   2. Renames /home/<user>  ->  /home/<user>.local
#   3. Updates the local account's home directory with usermod -d (if the local account exists).
#   4. Generates a post-join restore script (/var/tmp/post-join-restore-homes-<timestamp>.sh)
#      that copies data back into the AD user's new home directory after first login.
#
# Usage:
#   sudo ./pre-join-migrate-homes.sh user1 user2 user3
#   sudo ./pre-join-migrate-homes.sh --from-file userlist.txt
#   sudo ./pre-join-migrate-homes.sh --all-local          # migrate ALL local human users (uid >= 1000)
#
# After domain join and AD users have logged in (pam_mkhomedir creates /home/<user>):
#   sudo /var/tmp/post-join-restore-homes-<timestamp>.sh
#
# Author: kshah

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.2.2"
SUFFIX=".local"
HOME_BASE="/home"
DRY_RUN="no"
ALL_LOCAL="no"
FROM_FILE=""
USERS=()
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
POST_SCRIPT="/var/tmp/post-join-restore-homes-${TIMESTAMP}.sh"

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME [options] <user1> [user2 ...]
  $SCRIPT_NAME [options] --from-file <file>
  $SCRIPT_NAME [options] --all-local

Options:
  --suffix <suffix>    Rename suffix (default: .local)
  --dry-run            Show what would happen without making changes
  -V, --version        Show script version
  -h, --help           Show this help

Examples:
  sudo $SCRIPT_NAME kshah jdoe              # migrate specific users
  sudo $SCRIPT_NAME --from-file users.txt   # one username per line
  sudo $SCRIPT_NAME --all-local             # all local users with uid >= 1000
  sudo $SCRIPT_NAME --dry-run --all-local   # preview without changes
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────

while (($# > 0)); do
  case "$1" in
    --suffix)     shift; SUFFIX="$1" ;;
    --dry-run)    DRY_RUN="yes" ;;
    --all-local)  ALL_LOCAL="yes" ;;
    --from-file)  shift; FROM_FILE="$1" ;;
    -V|--version) echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
    -h|--help)    usage; exit 0 ;;
    -*)           die "Unknown option: $1" ;;
    *)            USERS+=("$1") ;;
  esac
  shift
done

# ── Root check ────────────────────────────────────────────────────

[[ "$(id -u)" -eq 0 ]] || die "This script must be run as root (sudo)."

# ── Build user list ───────────────────────────────────────────────

if [[ "$ALL_LOCAL" == "yes" ]]; then
  while IFS=: read -r uname _ uid _ _ home _; do
    # local human users: uid >= 1000, home under /home, not nfsnobody
    if (( uid >= 1000 )) && [[ "$home" == "${HOME_BASE}/"* ]] && [[ "$uname" != "nfsnobody" ]]; then
      USERS+=("$uname")
    fi
  done < /etc/passwd
fi

if [[ -n "$FROM_FILE" ]]; then
  [[ -f "$FROM_FILE" ]] || die "File not found: $FROM_FILE"
  while IFS= read -r line; do
    line="${line%%#*}"                       # strip comments
    line="$(echo "$line" | xargs)"          # trim whitespace
    [[ -n "$line" ]] && USERS+=("$line")
  done < "$FROM_FILE"
fi

(( ${#USERS[@]} > 0 )) || die "No users specified. Use --help for usage."

# ── Deduplicate ───────────────────────────────────────────────────

declare -A SEEN
UNIQUE_USERS=()
for u in "${USERS[@]}"; do
  if [[ -z "${SEEN[$u]:-}" ]]; then
    SEEN[$u]=1
    UNIQUE_USERS+=("$u")
  fi
done
USERS=("${UNIQUE_USERS[@]}")

# ── Migrate ───────────────────────────────────────────────────────

MIGRATED=()
SKIPPED=()
DEFERRED_USERMOD=()

is_local_user() {
  # Returns 0 if the user exists in /etc/passwd (local), 1 otherwise
  grep -qE "^${1}:" /etc/passwd
}

for user in "${USERS[@]}"; do
  src="${HOME_BASE}/${user}"
  dst="${HOME_BASE}/${user}${SUFFIX}"

  # Skip if no home directory to migrate
  if [[ ! -d "$src" ]]; then
    echo "SKIP  $user — $src does not exist"
    SKIPPED+=("$user (no home dir)")
    continue
  fi

  # Skip if already migrated
  if [[ -d "$dst" ]]; then
    echo "SKIP  $user — $dst already exists (already migrated?)"
    SKIPPED+=("$user (already migrated)")
    continue
  fi

  # Check ownership — only migrate if owned by a local uid (not an AD uid)
  owner_uid="$(stat -c '%u' "$src")"
  if (( owner_uid < 1000 )); then
    echo "SKIP  $user — $src owned by uid $owner_uid (system account)"
    SKIPPED+=("$user (system account)")
    continue
  fi

  # Check for active processes — usermod will fail if the user has sessions/processes
  has_procs="no"
  if is_local_user "$user"; then
    local_uid="$(id -u "$user" 2>/dev/null)" || local_uid=""
    if [[ -n "$local_uid" ]] && pgrep -u "$local_uid" >/dev/null 2>&1; then
      has_procs="yes"
    fi
  fi

  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "WOULD rename  $src  ->  $dst"
    if is_local_user "$user"; then
      echo "WOULD usermod -d $dst $user"
      if [[ "$has_procs" == "yes" ]]; then
        echo "  NOTE: $user has active processes — usermod will fail unless sessions are closed first"
      fi
    fi
    MIGRATED+=("$user")
    continue
  fi

  # If user has active processes, we can still rename the dir but must skip usermod.
  # The running session keeps its file handles — the old path becomes stale but doesn't crash.
  if [[ "$has_procs" == "yes" ]]; then
    echo ""
    echo "WARNING: $user has active processes (logged-in session, cron, Docker, etc.)."
    echo "  The home directory can be renamed, but 'usermod -d' will be skipped because"
    echo "  it refuses to modify accounts with running processes."
    echo "  After this user's sessions end, run manually:"
    echo "    sudo usermod -d $dst $user"
    echo ""
    read -r -p "  Rename $src -> $dst anyway? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
      echo "SKIP  $user — user chose to skip (active processes)"
      SKIPPED+=("$user (active processes, skipped by user)")
      continue
    fi
  fi

  # Rename the home directory
  echo "RENAME  $src  ->  $dst"
  mv "$src" "$dst"

  # Update the local account if it exists
  if is_local_user "$user"; then
    if [[ "$has_procs" == "yes" ]]; then
      echo "DEFERRED  usermod for $user — run after sessions end: sudo usermod -d $dst $user"
      DEFERRED_USERMOD+=("$user")
    else
      echo "USERMOD $user home -> $dst"
      usermod -d "$dst" "$user"
    fi
  fi

  MIGRATED+=("$user")
done

# ── Generate post-join restore script ─────────────────────────────

if (( ${#MIGRATED[@]} > 0 )) && [[ "$DRY_RUN" != "yes" ]]; then
  cat > "$POST_SCRIPT" <<'HEADER'
#!/usr/bin/env bash
# Auto-generated post-join home directory restore script.
# Run this AFTER domain join and AFTER each AD user has logged in at least once
# (so that pam_mkhomedir has created their new /home/<user>).
#
# What it does for each user:
#   1. Checks that the AD user's new home dir exists.
#   2. Copies files from the old .local backup into it (preserving ownership/perms).
#   3. Chowns everything to the AD user's new uid/gid.
#   4. Leaves the .local directory intact as a backup until you remove it manually.
#
# Usage:  sudo ./post-join-restore-homes-*.sh [--delete-backups]

set -euo pipefail

DELETE_BACKUPS="no"
[[ "${1:-}" == "--delete-backups" ]] && DELETE_BACKUPS="yes"

HEADER

  for user in "${MIGRATED[@]}"; do
    cat >> "$POST_SCRIPT" <<EOF

# ── $user ──
src="${HOME_BASE}/${user}${SUFFIX}"
dst="${HOME_BASE}/${user}"
if [[ ! -d "\$dst" ]]; then
  echo "SKIP  $user — \$dst does not exist yet (has the AD user logged in?)"
else
  echo "RESTORE  $user — copying \$src -> \$dst"
  rsync -aHAX --ignore-existing "\$src/" "\$dst/"
  ad_uid="\$(id -u "$user" 2>/dev/null)" || { echo "WARN  could not resolve AD uid for $user"; ad_uid=""; }
  ad_gid="\$(id -g "$user" 2>/dev/null)" || ad_gid=""
  if [[ -n "\$ad_uid" && -n "\$ad_gid" ]]; then
    chown -R "\${ad_uid}:\${ad_gid}" "\$dst"
    echo "  chowned \$dst to \${ad_uid}:\${ad_gid}"
  else
    echo "  WARN  skipped chown — could not resolve AD uid/gid for $user"
  fi
  if [[ "\$DELETE_BACKUPS" == "yes" ]]; then
    rm -rf "\$src"
    echo "  deleted backup \$src"
  fi
fi
EOF
  done

  cat >> "$POST_SCRIPT" <<'FOOTER'

echo ""
echo "Done. Old .local directories are still in place unless --delete-backups was used."
echo "Once you've verified everything, you can remove them:"
echo "  sudo rm -rf /home/*.local"
FOOTER

  chmod 700 "$POST_SCRIPT"
fi

# ── Summary ───────────────────────────────────────────────────────

echo ""
echo "=============================="
if [[ "$DRY_RUN" == "yes" ]]; then
  echo "DRY RUN — no changes were made."
else
  echo "Migration complete."
fi
echo "  Migrated: ${#MIGRATED[@]}"
echo "  Skipped:  ${#SKIPPED[@]}"

if (( ${#SKIPPED[@]} > 0 )); then
  for s in "${SKIPPED[@]}"; do
    echo "    - $s"
  done
fi

if (( ${#DEFERRED_USERMOD[@]} > 0 )); then
  echo ""
  echo "DEFERRED: The following users had active processes. Their home directories"
  echo "were renamed, but usermod was skipped. After their sessions end, run:"
  for u in "${DEFERRED_USERMOD[@]}"; do
    echo "  sudo usermod -d ${HOME_BASE}/${u}${SUFFIX} $u"
  done
fi

if (( ${#MIGRATED[@]} > 0 )) && [[ "$DRY_RUN" != "yes" ]]; then
  echo ""
  echo "Next steps:"
  echo "  1. Log out any migrated users with deferred usermod (if applicable)."
  echo "  2. Run ubuntu-ad-join.sh to join the domain."
  echo "  3. Have each AD user log in once (creates /home/<user> via pam_mkhomedir)."
  echo "  4. Run:  sudo $POST_SCRIPT"
  echo "  5. After verifying, optionally remove backups:  sudo $POST_SCRIPT --delete-backups"
fi
