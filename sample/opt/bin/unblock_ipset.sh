#!/bin/sh

# Populate ipset 'unblock' from CIDRs, IPv4 addresses and resolved domains.

PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin

UNBLOCK_TXT="/opt/etc/unblock.txt"
SET_NAME="unblock"
IPSET="/opt/sbin/ipset"
DIG="/opt/bin/dig"
CR="$(printf '\r')"

[ -r "$UNBLOCK_TXT" ] || {
    echo "[ERR] Cannot read $UNBLOCK_TXT" >&2
    exit 1
}
[ -x "$IPSET" ] || {
    echo "[ERR] $IPSET is missing. Install it with: opkg install ipset" >&2
    exit 1
}
[ -x "$DIG" ] || {
    echo "[ERR] $DIG is missing. Install it with: opkg install bind-dig" >&2
    exit 1
}

"$IPSET" create "$SET_NAME" hash:net -exist || exit 1
"$IPSET" flush "$SET_NAME" || exit 1

processed=0
added=0
warnings=0

while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$CR}"

    [ -z "$line" ] && continue
    case "$line" in
        \#*) continue ;;
    esac

    processed=$((processed + 1))
    echo "[*] Processing: $line"

    # Entries made only of digits, dots, slash or dash are IPs/ranges/CIDRs.
    case "$line" in
        *[!0-9./-]*) ;;
        *)
            if "$IPSET" add "$SET_NAME" "$line" -exist; then
                added=$((added + 1))
            else
                warnings=$((warnings + 1))
                echo "[WARN] Cannot add network entry: $line" >&2
            fi
            continue
            ;;
    esac

    resolved=0
    for ip in $("$DIG" +time=2 +tries=1 +short A "$line" @127.0.0.1 | \
        awk -F. 'NF == 4 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ { print }')
    do
        if "$IPSET" add "$SET_NAME" "$ip" -exist; then
            added=$((added + 1))
            resolved=1
        fi
    done

    if [ "$resolved" -eq 0 ]; then
        warnings=$((warnings + 1))
        echo "[WARN] No IPv4 answer for: $line" >&2
    fi
done < "$UNBLOCK_TXT"

entries="$("$IPSET" save "$SET_NAME" 2>/dev/null | awk '$1 == "add" { n++ } END { print n + 0 }')"
echo "[OK] ipset population complete: processed=$processed, entries=$entries, add_operations=$added, warnings=$warnings."
exit 0
