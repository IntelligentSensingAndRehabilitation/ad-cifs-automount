#!/usr/bin/env bash
# pre-join-backup.sh
# Snapshots system config files BEFORE running ubuntu-ad-join.sh so you can
# cleanly revert if the domain join goes wrong.
#
# Usage:
#   sudo ./pre-join-backup.sh                       # backup (default)
#   sudo ./pre-join-backup.sh --restore             # interactive restore
#   sudo ./pre-join-backup.sh --restore --force      # restore without prompts
#
# Backup is saved to: /var/backups/pre-ad-join-<timestamp>/
# A symlink /var/backups/pre-ad-join-latest always points to the most recent backup.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.2.2"
BACKUP_BASE="/var/backups"
LATEST_LINK="${BACKUP_BASE}/pre-ad-join-latest"
MODE="backup"
FORCE="no"

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME                        Create a pre-join backup
  $SCRIPT_NAME --restore              Restore from the most recent backup (interactive)
  $SCRIPT_NAME --restore --force      Restore without prompting
  $SCRIPT_NAME --restore <path>       Restore from a specific backup directory
  -V, --version                       Show script version
  -h, --help                          Show this help
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────

RESTORE_PATH=""

while (($# > 0)); do
  case "$1" in
    --restore)   MODE="restore" ;;
    --force)     FORCE="yes" ;;
    -V|--version) echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
    -h|--help)    usage; exit 0 ;;
    -*)           die "Unknown option: $1" ;;
    *)            RESTORE_PATH="$1" ;;
  esac
  shift
done

[[ "$(id -u)" -eq 0 ]] || die "This script must be run as root (sudo)."

# ── Files to back up ─────────────────────────────────────────────
# These are the files ubuntu-ad-join.sh modifies.

CONFIG_FILES=(
  /etc/krb5.conf
  /etc/nsswitch.conf
  /etc/ssh/sshd_config
  /etc/pam.d/common-session
  /etc/default/autofs
  /etc/auto.master
  /etc/hostname
  /etc/hosts
  /etc/sssd/sssd.conf
)

CONFIG_DIRS=(
  /etc/sudoers.d
)

# ── Backup mode ───────────────────────────────────────────────────

do_backup() {
  local ts
  ts="$(date +%Y%m%d%H%M%S)"
  local backup_dir="${BACKUP_BASE}/pre-ad-join-${ts}"

  mkdir -p "$backup_dir"

  echo "Creating pre-join backup: $backup_dir"
  echo ""

  # Individual config files
  for f in "${CONFIG_FILES[@]}"; do
    if [[ -f "$f" ]]; then
      local dest="${backup_dir}${f}"
      mkdir -p "$(dirname "$dest")"
      cp -a "$f" "$dest"
      echo "  OK  $f"
    else
      echo "  --  $f (does not exist, skipping)"
    fi
  done

  # Config directories
  for d in "${CONFIG_DIRS[@]}"; do
    if [[ -d "$d" ]]; then
      local dest="${backup_dir}${d}"
      mkdir -p "$(dirname "$dest")"
      cp -a "$d" "$dest"
      echo "  OK  $d/"
    else
      echo "  --  $d/ (does not exist, skipping)"
    fi
  done

  # Metadata
  echo ""
  hostname -f > "${backup_dir}/hostname-fqdn.txt" 2>/dev/null || hostname > "${backup_dir}/hostname-fqdn.txt"
  echo "  OK  saved hostname: $(cat "${backup_dir}/hostname-fqdn.txt")"

  dpkg --get-selections > "${backup_dir}/dpkg-selections.txt"
  echo "  OK  saved package list ($(wc -l < "${backup_dir}/dpkg-selections.txt") packages)"

  # Capture whether the machine is currently domain-joined
  if command -v realm >/dev/null 2>&1; then
    realm list > "${backup_dir}/realm-list.txt" 2>&1 || true
    echo "  OK  saved realm list"
  fi

  systemctl list-units --type=service --state=running --no-pager > "${backup_dir}/running-services.txt" 2>&1 || true
  echo "  OK  saved running services list"

  # Update latest symlink
  ln -sfn "$backup_dir" "$LATEST_LINK"

  echo ""
  echo "=============================="
  echo "Backup complete: $backup_dir"
  echo "Symlinked as:    $LATEST_LINK"
  echo ""
  echo "To restore if the domain join goes wrong:"
  echo "  sudo $SCRIPT_NAME --restore"
  echo ""
  echo "Or for a manual nuclear revert:"
  echo "  sudo realm leave <domain>"
  echo "  sudo $SCRIPT_NAME --restore --force"
  echo "  sudo systemctl restart ssh"
}

# ── Restore mode ──────────────────────────────────────────────────

do_restore() {
  local backup_dir="$RESTORE_PATH"

  # Default to latest
  if [[ -z "$backup_dir" ]]; then
    if [[ -L "$LATEST_LINK" && -d "$LATEST_LINK" ]]; then
      backup_dir="$(readlink -f "$LATEST_LINK")"
    else
      die "No backup found. Run '$SCRIPT_NAME' first to create one."
    fi
  fi

  [[ -d "$backup_dir" ]] || die "Backup directory not found: $backup_dir"

  echo "Restoring from: $backup_dir"
  echo ""

  # Show what will be restored
  local files_to_restore=()
  for f in "${CONFIG_FILES[@]}"; do
    local src="${backup_dir}${f}"
    if [[ -f "$src" ]]; then
      if [[ -f "$f" ]]; then
        if ! diff -q "$src" "$f" >/dev/null 2>&1; then
          echo "  CHANGED  $f"
          files_to_restore+=("$f")
        else
          echo "  OK       $f (unchanged, skipping)"
        fi
      else
        echo "  MISSING  $f (will recreate)"
        files_to_restore+=("$f")
      fi
    fi
  done

  for d in "${CONFIG_DIRS[@]}"; do
    local src="${backup_dir}${d}"
    if [[ -d "$src" ]]; then
      echo "  DIR      $d/"
      files_to_restore+=("$d")
    fi
  done

  if (( ${#files_to_restore[@]} == 0 )); then
    echo ""
    echo "Nothing to restore — all files match the backup."
    return 0
  fi

  # Confirm unless --force
  if [[ "$FORCE" != "yes" ]]; then
    echo ""
    echo "This will overwrite the ${#files_to_restore[@]} file(s) listed above."
    echo "Services (ssh, sssd, autofs) will NOT be restarted automatically."
    read -r -p "Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
  fi

  echo ""

  # Restore files
  for f in "${CONFIG_FILES[@]}"; do
    local src="${backup_dir}${f}"
    if [[ -f "$src" ]]; then
      mkdir -p "$(dirname "$f")"
      cp -a "$src" "$f"
      echo "  RESTORED  $f"
    fi
  done

  # Restore directories
  for d in "${CONFIG_DIRS[@]}"; do
    local src="${backup_dir}${d}"
    if [[ -d "$src" ]]; then
      # Don't blow away the whole dir — just restore files from backup
      cp -a "$src"/. "$d"/
      echo "  RESTORED  $d/"
    fi
  done

  # Restore hostname if --set-fqdn changed it
  if [[ -f "${backup_dir}/hostname-fqdn.txt" ]]; then
    local old_hostname
    old_hostname="$(cat "${backup_dir}/hostname-fqdn.txt")"
    local current_hostname
    current_hostname="$(hostname -f 2>/dev/null || hostname)"
    if [[ "$old_hostname" != "$current_hostname" ]]; then
      echo ""
      echo "  Hostname changed: $old_hostname -> $current_hostname"
      if [[ "$FORCE" == "yes" ]]; then
        hostnamectl set-hostname "$old_hostname"
        echo "  RESTORED hostname to $old_hostname"
      else
        read -r -p "  Restore hostname to $old_hostname? [y/N] " confirm
        if [[ "$confirm" =~ ^[Yy] ]]; then
          hostnamectl set-hostname "$old_hostname"
          echo "  RESTORED hostname to $old_hostname"
        fi
      fi
    fi
  fi

  echo ""
  echo "=============================="
  echo "Restore complete."
  echo ""
  echo "You likely need to restart services:"
  echo "  sudo systemctl restart ssh"
  echo "  sudo systemctl restart sssd    # if it was running"
  echo "  sudo systemctl restart autofs  # if it was running"
  echo ""
  echo "If the machine was joined to a domain and you want to unjoin:"
  echo "  sudo realm leave <domain>"
}

# ── Main ──────────────────────────────────────────────────────────

case "$MODE" in
  backup)  do_backup ;;
  restore) do_restore ;;
esac
