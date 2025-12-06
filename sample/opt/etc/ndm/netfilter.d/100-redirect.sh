#!/bin/sh

# This script sets up NAT redirect rules for traffic in the 'unblock' ipset
# and redirects all DNS traffic on br0 to local dnsmasq.

[ "$type" = "ip6tables" ] && exit 0

# Setup redirect rules if not already present
if [ -z "$(iptables-save 2>/dev/null | grep unblock)" ]; then
    ipset create unblock hash:net -exist
    iptables -I PREROUTING -w -t nat -i br0 -p tcp -m set --match-set unblock dst -j REDIRECT --to-port 61219
    iptables -I PREROUTING -w -t nat -i br0 -p udp -m set --match-set unblock dst -j REDIRECT --to-port 61219
fi

# Redirect all DNS on br0 to 172.16.1.1
if [ -z "$(iptables-save 2>/dev/null | grep "udp --dport 53 -j DNAT")" ]; then
    iptables -w -t nat -I PREROUTING -i br0 -p udp --dport 53 -j DNAT --to 172.16.1.1
fi

if [ -z "$(iptables-save 2>/dev/null | grep "tcp --dport 53 -j DNAT")" ]; then
    iptables -w -t nat -I PREROUTING -i br0 -p tcp --dport 53 -j DNAT --to 172.16.1.1
fi

exit 0