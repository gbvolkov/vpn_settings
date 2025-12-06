#!/bin/sh

# Generate dnsmasq configuration entries for domains listed in /opt/etc/unblock.txt.
# Each domain will be associated with the ipset named 'unblock'.

UNBLOCK_TXT="/opt/etc/unblock.txt"
UNBLOCK_DNSMASQ="/opt/etc/unblock.dnsmasq"

rm -f "$UNBLOCK_DNSMASQ"

while IFS= read -r line; do
    # Skip empty lines and comments
    [ -z "$line" ] && continue
    case "$line" in
        \#*) continue ;;
    esac
    # If it's a plain domain (no slash or colon)
    # This basic check ensures we only write ipset rules for domain names.
    if echo "$line" | grep -vq '/'; then
        echo "ipset=/$(echo "$line" | tr -d '\r')/unblock" >> "$UNBLOCK_DNSMASQ"
    fi
done < "$UNBLOCK_TXT"

exit 0