#!/bin/bash
#
# toggle_root_session.sh
# Toggles root access on/off for the current session.
# Run it once to enable, run it again to disable.
# Always resets on reboot regardless.
#

# ── ENSURE /dev/shm EXISTS ──────────────────────────────────────────
# /dev/shm is RAM-backed and wiped on reboot — perfect for a session flag.
# It exists on virtually all Linux systems but we create it just in case.
mkdir -p /dev/shm 2>/dev/null || true

FLAG="/dev/shm/root_session_active"

# ── OS DETECTION ────────────────────────────────────────────────────

OS_NAME=""
ALREADY_ROOT=false
HAS_SUDO=false
HAS_SYSTEMCTL=false
HAS_CHPASSWD=false
DEFAULT_PASSWORD="ark"

# Check if we're already running as root
if [ "$(id -u)" = "0" ]; then
  ALREADY_ROOT=true
fi

# Check available tools
command -v sudo       >/dev/null 2>&1 && HAS_SUDO=true
command -v systemctl  >/dev/null 2>&1 && HAS_SYSTEMCTL=true
command -v chpasswd   >/dev/null 2>&1 && HAS_CHPASSWD=true

# Primary detection: source /etc/os-release if present
if [ -f /etc/os-release ]; then
  . /etc/os-release
  case "$ID" in
    arkos|ubuntu)
      OS_NAME="ArkOS"
      DEFAULT_PASSWORD="ark"
      ;;
    rocknix|jelos)
      OS_NAME="ROCKNIX"
      DEFAULT_PASSWORD="root"
      ;;
    muos)
      OS_NAME="muOS"
      DEFAULT_PASSWORD="root"
      ;;
    batocera)
      OS_NAME="Batocera"
      DEFAULT_PASSWORD="linux"
      ;;
    emuelec)
      OS_NAME="EmuELEC"
      DEFAULT_PASSWORD="emuelec"
      ;;
    *)
      # FIX: PRETTY_NAME or ID may be empty; use a safe fallback chain
      # so OS_NAME is never blank (which would skip the marker-file fallback)
      OS_NAME="${PRETTY_NAME:-${ID:-}}"
      DEFAULT_PASSWORD="ark"
      ;;
  esac
fi

# FIX: If OS_NAME is still empty or unset after sourcing os-release,
# treat it the same as unknown so the marker-file fallback runs correctly.
if [ -z "$OS_NAME" ]; then
  OS_NAME="unknown"
fi

# Fallback: check known marker files for firmwares with unusual os-release
if [ "$OS_NAME" = "unknown" ]; then
  if [ -f /usr/share/rocknix/info ]; then
    OS_NAME="ROCKNIX"
    DEFAULT_PASSWORD="root"
  elif [ -d /opt/muos ]; then
    OS_NAME="muOS"
    DEFAULT_PASSWORD="root"
  elif [ -f /usr/bin/batocera-info ]; then
    OS_NAME="Batocera"
    DEFAULT_PASSWORD="linux"
  elif [ -f /etc/emuelec-release ]; then
    OS_NAME="EmuELEC"
    DEFAULT_PASSWORD="emuelec"
  else
    OS_NAME="Unknown Linux"
    DEFAULT_PASSWORD="ark"
  fi
fi

echo "  Detected OS : $OS_NAME"
echo ""

# ── HELPER: run a command with privilege escalation as needed ────────
# - Already root (ROCKNIX, muOS, EmuELEC): run directly
# - Has sudo (ArkOS): prefix with sudo
# - Neither: attempt directly and silently continue on failure
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
# Firmwares like ROCKNIX and muOS run natively as root.
# The script still runs safely — the flag and chmod still apply.
if [ "$ALREADY_ROOT" = true ]; then
  echo "  NOTE: $OS_NAME already runs as root."
  echo "  Root access is always available on this firmware."
  echo "  Continuing anyway to set file manager access..."
  echo ""
  sleep 3
fi

# ── TOGGLE ──────────────────────────────────────────────────────────

if [ -f "$FLAG" ]; then
  # ── ROOT IS ACTIVE — DISABLE ──────────────────────────────────────
  echo "=========================================="
  echo "  Disabling root session"
  echo "=========================================="
  echo ""

  # Lock the root account
  run_cmd passwd -l root

  # Restore /root to owner-only access
  run_cmd chmod 700 /root

  # Revert SSH root login if sshd_config exists
  if [ -f /etc/ssh/sshd_config ]; then
    run_cmd sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

    if [ "$HAS_SYSTEMCTL" = true ]; then
      run_cmd systemctl restart ssh
      run_cmd systemctl restart sshd
    else
      run_cmd service ssh restart
      run_cmd service sshd restart
    fi
  fi

  # Remove flag from RAM
  run_cmd rm -f "$FLAG"

  echo "[OK] Root session DISABLED."
  echo ""
  echo "  The file manager is back to normal user access."
  echo "  Run this script again to re-enable."
  echo ""
  echo "=========================================="
  sleep 5

else
  # ── ROOT IS INACTIVE — ENABLE ─────────────────────────────────────
  echo "=========================================="
  echo "  Enabling root session (until reboot)"
  echo "=========================================="
  echo ""

  # Set root password.
  # chpasswd is the reliable way; fall back to BusyBox passwd via stdin.
  if [ "$HAS_CHPASSWD" = true ]; then
    echo "root:$DEFAULT_PASSWORD" | run_cmd chpasswd
  else
    printf '%s\n%s\n' "$DEFAULT_PASSWORD" "$DEFAULT_PASSWORD" | run_cmd passwd root
  fi

  # Unlock root account in case it was locked
  run_cmd passwd -u root

  # Open /root so the file manager can browse it
  run_cmd chmod 755 /root

  # Allow root login over SSH if sshd_config exists
  if [ -f /etc/ssh/sshd_config ]; then
    run_cmd sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

    # Append directive only if it was missing entirely from the file
    grep -q "PermitRootLogin" /etc/ssh/sshd_config || \
      echo "PermitRootLogin yes" | run_cmd tee -a /etc/ssh/sshd_config > /dev/null

    if [ "$HAS_SYSTEMCTL" = true ]; then
      run_cmd systemctl restart ssh
      run_cmd systemctl restart sshd
    else
      run_cmd service ssh restart
      run_cmd service sshd restart
    fi
  fi

  # Write session flag to RAM — automatically gone after reboot
  echo "active" | run_cmd tee "$FLAG" > /dev/null

  echo "[OK] Root session ACTIVE."
  echo ""
  echo "  Username : root"
  echo "  Password : $DEFAULT_PASSWORD"
  echo ""
  echo "  Browse ALL directories in the file manager."
  echo "  Run this script again to disable early."
  echo "  Reboot to disable automatically."
  echo ""
  echo "=========================================="
  sleep 5
fi
