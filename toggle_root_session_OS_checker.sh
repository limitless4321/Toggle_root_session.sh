#!/bin/bash
#
# toggle_root_session.sh
# Toggles root access on/off for the current session.
# Run it once to enable, run it again to disable.
# Always resets on reboot regardless.
#

FLAG="/dev/shm/root_session_active"

# ── OS DETECTION ────────────────────────────────────────────────────
# Detect which firmware we're running on so we use the right commands.
# Checks are ordered from most specific to most generic.

OS_NAME="unknown"
ALREADY_ROOT=false
HAS_SUDO=false
HAS_SYSTEMCTL=false
HAS_CHPASSWD=false
DEFAULT_PASSWORD="ark"

# Check if we're already running as root
if [ "$(id -u)" = "0" ]; then
  ALREADY_ROOT=true
fi

# Check for sudo
if command -v sudo >/dev/null 2>&1; then
  HAS_SUDO=true
fi

# Check for systemctl (systemd) vs other init systems
if command -v systemctl >/dev/null 2>&1; then
  HAS_SYSTEMCTL=true
fi

# Check for chpasswd
if command -v chpasswd >/dev/null 2>&1; then
  HAS_CHPASSWD=true
fi

# Identify the OS/firmware by sourcing /etc/os-release if available
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
      OS_NAME="${PRETTY_NAME:-$ID}"
      DEFAULT_PASSWORD="ark"
      ;;
  esac
fi

# Fallback checks for firmwares that don't set ID cleanly in os-release
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

# ── HELPER: run a command with or without sudo as needed ────────────
# On already-root systems (ROCKNIX, muOS etc) runs directly.
# On sudo systems (ArkOS) prefixes with sudo.
# Falls back to direct execution if neither applies.
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
# ROCKNIX, muOS, EmuELEC etc run as root natively.
# The toggle still works (flag file, /root chmod) but we let the user know.
if [ "$ALREADY_ROOT" = true ]; then
  echo "  NOTE: $OS_NAME already runs as root."
  echo "  Root access is always available on this firmware."
  echo "  Continuing anyway for file manager /root access..."
  echo ""
  sleep 3
fi

# ── TOGGLE LOGIC ────────────────────────────────────────────────────

if [ -f "$FLAG" ]; then
  # ── ROOT IS ACTIVE → DISABLE ──────────────────────────────────────
  echo "=========================================="
  echo "  Disabling root session"
  echo "=========================================="
  echo ""

  # Lock the root account
  run_cmd passwd -l root

  # Restore /root to owner-only access
  run_cmd chmod 700 /root

  # Revert SSH config if it exists
  if [ -f /etc/ssh/sshd_config ]; then
    run_cmd sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

    # Restart SSH using whichever init system is present
    if [ "$HAS_SYSTEMCTL" = true ]; then
      run_cmd systemctl restart ssh
      run_cmd systemctl restart sshd
    else
      run_cmd service ssh restart
      run_cmd service sshd restart
    fi
  fi

  # Remove the flag from RAM
  run_cmd rm -f "$FLAG"

  echo "[OK] Root session DISABLED."
  echo ""
  echo "  The file manager is back to normal user access."
  echo "  Run this script again to re-enable."
  echo ""
  echo "=========================================="
  sleep 5

else
  # ── ROOT IS INACTIVE → ENABLE ─────────────────────────────────────
  echo "=========================================="
  echo "  Enabling root session (until reboot)"
  echo "=========================================="
  echo ""

  # Set root password using chpasswd if available (full util),
  # otherwise fall back to BusyBox passwd which reads from stdin.
  if [ "$HAS_CHPASSWD" = true ]; then
    echo "root:$DEFAULT_PASSWORD" | run_cmd chpasswd
  else
    printf '%s\n%s\n' "$DEFAULT_PASSWORD" "$DEFAULT_PASSWORD" | run_cmd passwd root
  fi

  # Unlock the root account in case it was locked
  run_cmd passwd -u root

  # Open /root so the file manager can browse it
  run_cmd chmod 755 /root

  # Update SSH config to permit root login if SSH is installed
  if [ -f /etc/ssh/sshd_config ]; then
    run_cmd sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

    # Add the directive if it wasn't in the file at all
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

  # Write flag to /dev/shm (RAM only — wiped automatically on reboot)
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
