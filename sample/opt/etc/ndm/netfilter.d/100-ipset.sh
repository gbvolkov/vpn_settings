#!/bin/sh

# Create the 'unblock' ipset if it does not exist.
[ "$1" != "start" ] && exit 0

ipset create unblock hash:net -exist

exit 0