#!/bin/sh

# Generate dnsmasq ipset rules for domains in /opt/etc/unblock.txt.

PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin

UNBLOCK_TXT="/opt/etc/unblock.txt"
UNBLOCK_DNSMASQ="/opt/etc/unblock.dnsmasq"
TMP_FILE="/tmp/unblock.dnsmasq.$$"
CR="$(printf '\r')"

cleanup() {
    rm -f "$TMP_FILE"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

[ -r "$UNBLOCK_TXT" ] || {
    echo "[ERR] Cannot read $UNBLOCK_TXT" >&2
    exit 1
}

: > "$TMP_FILE" || exit 1
count=0

while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$CR}"

    [ -z "$line" ] && continue
    case "$line" in
        \#*) continue ;;
        */*|*:*) continue ;;
    esac

    # Skip a bare IPv4 address. It is added directly by unblock_ipset.sh.
    case "$line" in
        *[!0-9.]*) ;;
        *) continue ;;
    esac

    case "$line" in
        *[!A-Za-z0-9._*-]*)
            echo "[WARN] Skipping invalid domain entry: $line" >&2
            continue
            ;;
    esac

    echo "ipset=/$line/unblock" >> "$TMP_FILE" || exit 1
    count=$((count + 1))
done < "$UNBLOCK_TXT"

mv -f "$TMP_FILE" "$UNBLOCK_DNSMASQ" || exit 1
chmod 644 "$UNBLOCK_DNSMASQ"

echo "[OK] Generated $UNBLOCK_DNSMASQ ($count domain rules)."
exit 0
