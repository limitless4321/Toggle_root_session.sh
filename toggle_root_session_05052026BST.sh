#!/bin/bash
#
# toggle_root_session.sh
# Toggles root access on/off for the current session.
# Run it once to enable, run it again to disable.
# does not reset on reboot from my tests
#
# On ENABLE: finds all root-owned directories that non-root users can't read,
#            saves their original permissions, then opens them to all users.
# On DISABLE: restores every directory to its exact original permissions.
#
printf "You are running toggle root, you must rerun this script to disable it, or twice after reboot.\n"
sleep 2

printf "Thanks fOr downloading ig :3\n"
sleep 1
clear
# i hope this clear command works on the handheld emulators lol
# ── ENSURE /dev/shm EXISTS ──────────────────────────────────────────
# /dev/shm is RAM-backed and wiped on reboot — perfect for session data.
mkdir -p /dev/shm 2>/dev/null || true

FLAG="/dev/shm/root_session_active"
PERMS_BACKUP="/dev/shm/root_perms_backup"

# Directories to scan for root-only subdirs.
# Deliberately excludes virtual/device filesystems that must never be touched.
SCAN_DIRS="/root /etc /var /opt /boot /home /usr/local"

# ── OS DETECTION ────────────────────────────────────────────────────

OS_NAME=""
ALREADY_ROOT=false
HAS_SUDO=false
HAS_SYSTEMCTL=false
HAS_CHPASSWD=false
DEFAULT_PASSWORD="ark"

if [ "$(id -u)" = "0" ]; then
  ALREADY_ROOT=true
fi

command -v sudo       >/dev/null 2>&1 && HAS_SUDO=true
command -v systemctl  >/dev/null 2>&1 && HAS_SYSTEMCTL=true
command -v chpasswd   >/dev/null 2>&1 && HAS_CHPASSWD=true

# Primary detection via /etc/os-release
if [ -f /etc/os-release ]; then
  . /etc/os-release
  case "$ID" in
    arkos|ubuntu)   OS_NAME="ArkOS";    DEFAULT_PASSWORD="ark"     ;;
    rocknix|jelos)  OS_NAME="ROCKNIX";  DEFAULT_PASSWORD="root"    ;;
    muos)           OS_NAME="muOS";     DEFAULT_PASSWORD="root"    ;;
    batocera)       OS_NAME="Batocera"; DEFAULT_PASSWORD="linux"   ;;
    emuelec)        OS_NAME="EmuELEC";  DEFAULT_PASSWORD="emuelec" ;;
    *)
      OS_NAME="${PRETTY_NAME:-${ID:-}}"
      DEFAULT_PASSWORD="ark"
      ;;
  esac
fi

# Ensure OS_NAME is never blank (would skip marker-file fallback)
if [ -z "$OS_NAME" ]; then
  OS_NAME="unknown"
fi

# Marker-file fallback for firmwares with unusual os-release
if [ "$OS_NAME" = "unknown" ]; then
  if   [ -f /usr/share/rocknix/info ];  then OS_NAME="ROCKNIX";  DEFAULT_PASSWORD="root"
  elif [ -d /opt/muos ];                 then OS_NAME="muOS";     DEFAULT_PASSWORD="root"
  elif [ -f /usr/bin/batocera-info ];    then OS_NAME="Batocera"; DEFAULT_PASSWORD="linux"
  elif [ -f /etc/emuelec-release ];      then OS_NAME="EmuELEC";  DEFAULT_PASSWORD="emuelec"
  else                                        OS_NAME="Unknown Linux"; DEFAULT_PASSWORD="ark"
  fi
fi

printf "  Detected OS : $OS_NAME"
printf ""

# ── HELPER: privilege-aware command runner ───────────────────────────
# Runs directly if already root, via sudo if available, or direct fallback.
# All errors are suppressed with || true so no single failure aborts the script.
run_cmd() {
  if [ "$ALREADY_ROOT" = true ]; then
    "$@" 2>/dev/null || true
  elif [ "$HAS_SUDO" = true ]; then
    sudo "$@" 2>/dev/null || true
  else
    "$@" 2>/dev/null || true
  fi
}

# ── ALREADY ROOT NOTICE ─────────────────────────────────────────────
if [ "$ALREADY_ROOT" = true ]; then
  printf "  NOTE: $OS_NAME already runs as root."
  printf "  Root access is always available on this firmware."
  printf "  Continuing anyway to open directory permissions..."
  printf ""
  sleep 3
fi

# ── HELPER: restart SSH safely ──────────────────────────────────────
restart_ssh() {
  if [ "$HAS_SYSTEMCTL" = true ]; then
    run_cmd systemctl restart ssh
    run_cmd systemctl restart sshd
  else
    run_cmd service ssh restart
    run_cmd service sshd restart
  fi
}

# ── HELPER: open root-only directories ──────────────────────────────
# Finds every root-owned directory inside SCAN_DIRS that is not currently
# readable by other users. Saves original permissions to PERMS_BACKUP,
# then adds o+rX (read + conditional execute) so the file manager can browse.
open_root_dirs() {
  printf "  Scanning for root-only directories..."
  sleep 2
  # Wipe any stale backup from a previous session
  run_cmd rm -f "$PERMS_BACKUP"
  run_cmd touch "$PERMS_BACKUP"

  local count=0

  for scan_dir in $SCAN_DIRS; do
    # Skip if the directory doesn't exist on this firmware
    [ -d "$scan_dir" ] || continue

    # FIX: Use process substitution < <(...) instead of find | while so that
    # the while loop runs in the current shell, not a subshell. This ensures
    # the count variable and >> writes to PERMS_BACKUP are all in the same
    # process and the count is accurate when we echo it after the loop.
    while IFS= read -r path; do
      # Save original octal permissions before changing anything
      orig=$(stat --format="%a" "$path" 2>/dev/null)
      [ -z "$orig" ] && continue

      # Write to backup: "PERM /path/to/dir"
      echo "$orig $path" >> "$PERMS_BACKUP"

      # Open to other users: r (read dir contents) + X (enter dir,
      # only sets x if it was already set for owner — safe pattern)
      run_cmd chmod o+rX "$path"
      count=$((count + 1))
    done < <(find "$scan_dir" \
      -maxdepth 5 \
      -user root \
      -type d \
      ! -perm -o+r \
      ! -path "*/proc/*" \
      ! -path "*/sys/*" \
      ! -path "*/dev/*" \
      ! -path "*/run/*" \
      ! -path "*/.git/*" \
      2>/dev/null)
  done

  printf "  Opened $count root-only directories."
}

# ── HELPER: restore original permissions ────────────────────────────
# Reads the backup file written by open_root_dirs and restores each
# directory to its exact original octal permission value.
restore_root_dirs() {
  if [ ! -f "$PERMS_BACKUP" ]; then
    printf "  [WARNING] Permission backup not found — nothing to restore."
    printf "  Directories may stay open until possibly next time you run the script i think."
    return
  fi

  local count=0

  while IFS=" " read -r perm path; do
    # Skip blank or malformed lines
    [ -z "$perm" ] || [ -z "$path" ] && continue

    run_cmd chmod "$perm" "$path"
    count=$((count + 1))
  done < "$PERMS_BACKUP"

  run_cmd rm -f "$PERMS_BACKUP"
  echo "  Restored $count directories to original permissions."
}

# ── TOGGLE ──────────────────────────────────────────────────────────

if [ -f "$FLAG" ]; then
  # ── ROOT IS ACTIVE — DISABLE ──────────────────────────────────────
  printf "=========================================="
  printf "  Disabling root session"
  printf "=========================================="
  printf ""

  # Restore all directories to their original permissions
  restore_root_dirs

  # Lock the root account
  run_cmd passwd -l root

  # Restore /root to owner-only (also caught by restore above, but explicit)
  run_cmd chmod 700 /root

  # Revert SSH root login
  if [ -f /etc/ssh/sshd_config ]; then
    run_cmd sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    restart_ssh
  fi

  # Remove session flag from RAM
  run_cmd rm -f "$FLAG"

  printf ""
  printf "[OK] Root session DISABLED."
  printf ""
  printf "  All directories restored to original permissions."
  printf "  The file manager is back to normal user access."
  printf "  Run this script again to re-enable."
  printf ""
  printf "=========================================="
  sleep 5

else
  # ── ROOT IS INACTIVE — ENABLE ─────────────────────────────────────
  printf "=========================================="
  printf "  Enabling root session (until next run of script)"
  printf "=========================================="
  printf ""

  # Set root password — chpasswd if available, BusyBox passwd fallback
  if [ "$HAS_CHPASSWD" = true ]; then
    echo "root:$DEFAULT_PASSWORD" | run_cmd chpasswd
  else
    printf '%s\n%s\n' "$DEFAULT_PASSWORD" "$DEFAULT_PASSWORD" | run_cmd passwd root
  fi

  # Unlock root account in case it was locked
  run_cmd passwd -u root

  # Open all root-only directories and save their original permissions
  open_root_dirs

  # Allow root SSH login if SSH is installed
  if [ -f /etc/ssh/sshd_config ]; then
    run_cmd sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

    # Append only if the directive was entirely absent
    grep -q "PermitRootLogin" /etc/ssh/sshd_config || \
      echo "PermitRootLogin yes" | run_cmd tee -a /etc/ssh/sshd_config > /dev/null

    restart_ssh
  fi

  # Write session flag to RAM — gone automatically on running the script again
  echo "active" | run_cmd tee "$FLAG" > /dev/null

  printf ""
  printf "[OK] Root session ACTIVE."
  printf ""
  printf "  Username : root"
  printf "  Password : $DEFAULT_PASSWORD"
  printf ""
  printf "  All root-only directories are now readable."
  printf "  Run this script again to disable early."
  printf "  Rerun script to disable ig."
  printf ""
  printf "=========================================="
  sleep 5
fi
