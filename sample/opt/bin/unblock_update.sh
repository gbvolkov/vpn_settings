#!/bin/sh

# Rebuild dnsmasq rules, reload dnsmasq and repopulate ipset.

PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "[*] Generating dnsmasq unblock rules..."
/opt/bin/unblock_dnsmasq.sh || exit 1

echo "[*] Validating dnsmasq configuration..."
/opt/sbin/dnsmasq --test -C /opt/etc/dnsmasq.conf || exit 1

echo "[*] Restarting dnsmasq..."
/opt/etc/init.d/S56dnsmasq restart || exit 1

# Run in the foreground so SSH receives progress output. S99unblock starts this
# helper itself in the background during boot.
echo "[*] Populating ipset..."
/opt/bin/unblock_ipset.sh || exit 1

echo "[OK] Unblock configuration updated."
exit 0
