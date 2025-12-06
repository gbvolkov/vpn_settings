#!/bin/sh

set -e

# Ensure Git is in PATH (Entware usually installs it into /opt/bin)
/opt/bin/git --version >/dev/null 2>&1 || {
    echo "[ERR] git not found at /opt/bin/git. Install it with: opkg install git"
    exit 1
}

TMP_DIR="/tmp/vpn_settings.$$"
REPO_URL="https://github.com/gbvolkov/vpn_settings.git"
UNBLOCK_DST="/opt/etc/unblock.txt"
UNBLOCK_UPDATE="/opt/bin/unblock_update.sh"

echo "[*] Cloning repository: $REPO_URL"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

# Clone into temporary directory
/opt/bin/git clone "$REPO_URL" "$TMP_DIR/repo"

echo "[*] Updating $UNBLOCK_DST from repo unblock.txt"
if [ ! -f "$TMP_DIR/repo/unblock.txt" ]; then
    echo "[ERR] unblock.txt not found in cloned repo."
    rm -rf "$TMP_DIR"
    exit 1
fi

mkdir -p "$(dirname "$UNBLOCK_DST")"
cp "$TMP_DIR/repo/unblock.txt" "$UNBLOCK_DST"

echo "[*] Running unblock_update.sh..."
if [ -x "$UNBLOCK_UPDATE" ]; then
    "$UNBLOCK_UPDATE"
else
    echo "[ERR] $UNBLOCK_UPDATE not found or not executable."
    rm -rf "$TMP_DIR"
    exit 1
fi

echo "[*] Cleaning temporary files..."
rm -rf "$TMP_DIR"

echo "[OK] unblock.txt updated and unblock_update.sh executed."
exit 0

