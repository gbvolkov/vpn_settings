#!/bin/sh

# Update the runtime unblock list and helper scripts from the Git repository.

PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

REPO_URL="https://github.com/gbvolkov/vpn_settings.git"
TMP_DIR="/tmp/vpn_settings_update.$$"
REPO_DIR="$TMP_DIR/repo"

log() { echo "[*] $*"; }
ok() { echo "[OK] $*"; }
fail() { echo "[ERR] $*" >&2; exit 1; }

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

[ -x /opt/bin/git ] || fail "git is missing. Install it with: opkg install git"
[ -x /opt/lib/git-core/git-remote-https ] || fail "Git HTTPS helper is missing. Install it with: opkg install git-http"

cleanup
mkdir -p "$TMP_DIR" || fail "Cannot create $TMP_DIR"

log "Cloning $REPO_URL (shallow clone)..."
/opt/bin/git clone --depth 1 --single-branch "$REPO_URL" "$REPO_DIR" || fail "Repository clone failed"

for name in unblock.txt unblock_dnsmasq.sh unblock_ipset.sh unblock_update.sh update.sh; do
    [ -f "$REPO_DIR/$name" ] || fail "$name is missing in the repository"
done

install_file() {
    src="$1"
    dst="$2"
    mode="$3"
    tmp="$dst.new.$$"

    cp "$src" "$tmp" || fail "Cannot copy $src to $tmp"
    chmod "$mode" "$tmp" || fail "Cannot chmod $tmp"
    mv -f "$tmp" "$dst" || fail "Cannot replace $dst"
    ok "Updated $dst"
}

mkdir -p /opt/bin /opt/etc || fail "Cannot create /opt/bin or /opt/etc"

install_file "$REPO_DIR/unblock_dnsmasq.sh" /opt/bin/unblock_dnsmasq.sh 755
install_file "$REPO_DIR/unblock_ipset.sh" /opt/bin/unblock_ipset.sh 755
install_file "$REPO_DIR/unblock_update.sh" /opt/bin/unblock_update.sh 755
install_file "$REPO_DIR/update.sh" /opt/bin/vpn_settings_update.sh 755
install_file "$REPO_DIR/unblock.txt" /opt/etc/unblock.txt 644

log "Rebuilding dnsmasq rules and ipset..."
/opt/bin/unblock_update.sh || fail "unblock update failed"

ok "VPN settings update completed."
exit 0
