#!/bin/sh
# build/install-via-ssh.sh — copy a package (.tar.gz or .apk) to a
# Cardputer Zero device over SSH and install (or upgrade) it.
#
# Usage:
#   sh build/install-via-ssh.sh <package> <user@host> [--restart-applaunch]
#
#   sh build/install-via-ssh.sh ./build/packages/cpz-compass-1.0.tar.gz cpz@100.101.102.97
#   sh build/install-via-ssh.sh ./build/packages/cpz-compass-1.0.tar.gz root@192.168.88.66 --restart-applaunch
#
# The script uses the sandbox SSH key (~/.ssh/id_ed25519_cpz) by default.
# Override with CPZ_SSH_KEY or SSH_OPTS.
#
# scp does not work on the device (no sftp-server), so the payload is
# piped over stdin to a cat-sink on the device.
#
# For .tar.gz packages: extracts to / with --overwrite (busybox tar).
# For .apk packages:     installs with /sbin/apk add --allow-untrusted --force
#                         (note: .apk creation needs GNU tar; the build
#                         script produces .tar.gz by default).
set -eu

die() { echo "ERROR: $*" >&2; exit 1; }

# --- parse args ---------------------------------------------------------
PKG="${1:?Usage: $0 <package.tar.gz|package.apk> <user@host> [--restart-applaunch]}"
TARGET="${2:?Usage: $0 <package.tar.gz|package.apk> <user@host> [--restart-applaunch]}"
RESTART_LAUNCHER=0
[ "${3:-}" = "--restart-applaunch" ] && RESTART_LAUNCHER=1

[ -f "$PKG" ] || die "package not found: $PKG"

PKG_BASENAME=$(basename "$PKG")
PKG_NAME="${PKG_BASENAME%%-[0-9]*}"  # strip version suffix

# --- SSH configuration --------------------------------------------------
SSH_KEY="${CPZ_SSH_KEY:-$HOME/.ssh/id_ed25519_cpz}"
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

if [ -f "$SSH_KEY" ]; then
    SSH="$SSH -i $SSH_KEY"
fi
SSH="$SSH ${SSH_OPTS:-}"

# --- test connectivity --------------------------------------------------
echo "== testing SSH to $TARGET =="
if ! $SSH "$TARGET" 'echo ok' 2>/dev/null; then
    die "cannot reach $TARGET — is the device on and reachable?
  Try:  ssh -i ~/.ssh/id_ed25519_cpz $TARGET
  or set CPZ_SSH_KEY=/path/to/key"
fi

# Detect whether we are root or need sudo on the device
IS_ROOT=$($SSH "$TARGET" 'id -u' 2>/dev/null || echo "0")
if [ "$IS_ROOT" = "0" ]; then
    SUDO=""
else
    SUDO="sudo -n"
    if ! $SSH "$TARGET" "$SUDO true" 2>/dev/null; then
        die "logged in as non-root and sudo -n failed. Is NOPASSWD sudo configured?
  The device's cpz user has NOPASSWD sudo on the CPZ-Alpine image."
    fi
fi

# --- copy the package ---------------------------------------------------
REMOTE_TMP="/tmp/${PKG_BASENAME}"

echo "== copying $PKG_BASENAME → $TARGET:$REMOTE_TMP =="
cat "$PKG" | $SSH "$TARGET" "cat > $REMOTE_TMP" || die "copy failed"

REMOTE_SIZE=$($SSH "$TARGET" "wc -c < '$REMOTE_TMP'")
LOCAL_SIZE=$(wc -c < "$PKG")
if [ "$REMOTE_SIZE" != "$LOCAL_SIZE" ]; then
    die "size mismatch after copy: local=$LOCAL_SIZE remote=$REMOTE_SIZE"
fi
echo "   copied $(du -h "$PKG" | cut -f1) OK"

# --- install -------------------------------------------------------------
echo "== installing $PKG_NAME on $TARGET =="

case "$PKG_BASENAME" in
    *.tar.gz|*.tgz)
        # Extract to / with overwrite (busybox tar)
        echo "   extracting tar.gz to /"
        INSTALL_OUT=$($SSH "$TARGET" \
            "$SUDO tar -xzf '$REMOTE_TMP' -C / --overwrite 2>&1") || {
            echo "$INSTALL_OUT"
            die "tar extract failed"
        }
        # Show what was installed
        $SSH "$TARGET" "ls -la /usr/share/APPLaunch/bin/ /usr/share/APPLaunch/applications/ 2>/dev/null" \
            | grep -i "$(echo "$PKG_NAME" | sed 's/^cpz-//')" || true
        ;;
    *.apk)
        # apk add with --allow-untrusted --force
        echo "   installing with apk"
        INSTALL_OUT=$($SSH "$TARGET" \
            "$SUDO /sbin/apk add --allow-untrusted --force '$REMOTE_TMP'" 2>&1) || {
            echo "$INSTALL_OUT"
            die "/sbin/apk add failed"
        }
        echo "$INSTALL_OUT"
        ;;
    *)
        die "unknown package type: $PKG_BASENAME (expected .tar.gz or .apk)"
        ;;
esac

# --- clean up -----------------------------------------------------------
$SSH "$TARGET" "rm -f '$REMOTE_TMP'" 2>/dev/null || true

# --- optional: restart the launcher -------------------------------------
if [ "$RESTART_LAUNCHER" -eq 1 ]; then
    echo "== restarting applaunch service =="
    $SSH "$TARGET" "$SUDO rc-service applaunch stop 2>/dev/null; \
                   sudo rm -f /run/applaunch.pid; \
                   sudo rc-service applaunch start" 2>/dev/null || true
    echo "   launcher restarted"
fi

echo ""
echo "== INSTALL COMPLETE =="
echo "   package: $PKG_NAME → $TARGET"