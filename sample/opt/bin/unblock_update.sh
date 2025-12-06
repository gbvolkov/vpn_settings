#!/bin/sh

# Flush existing ipset, rebuild dnsmasq rules, restart dnsmasq, and repopulate ipset.
ipset flush unblock

# Generate /opt/etc/unblock.dnsmasq from unblock.txt
/opt/bin/unblock_dnsmasq.sh

# Restart dnsmasq to reload new rules
/opt/etc/init.d/S56dnsmasq restart

# Populate ipset in the background
/opt/bin/unblock_ipset.sh &

exit 0