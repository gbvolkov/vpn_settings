#!/bin/sh

# Populate the ipset 'unblock' with CIDR ranges, IPs and resolved domain IPs from /opt/etc/unblock.txt.

UNBLOCK_TXT="/opt/etc/unblock.txt"
SET_NAME="unblock"

# Ensure the ipset exists
ipset create "$SET_NAME" hash:net -exist

# Flush the set before repopulating
ipset flush "$SET_NAME"

while IFS= read -r line; do
    # Skip empty lines and comments
    [ -z "$line" ] && continue
    case "$line" in
        \#*) continue ;;
    esac

    # If entry contains slash, assume CIDR or IP range and add directly
    if echo "$line" | grep -q '/'; then
        ipset add "$SET_NAME" "$line" -exist
        continue
    fi

    # If it's a single IP address (no letters), add directly
    if echo "$line" | grep -Eq '^[0-9.]+$'; then
        ipset add "$SET_NAME" "$line" -exist
        continue
    fi

    # Otherwise, resolve the domain and add each IP
    for ip in $(getent hosts "$line" | awk '{ print $1 }'); do
        ipset add "$SET_NAME" "$ip" -exist
    done

done < "$UNBLOCK_TXT"

exit 0