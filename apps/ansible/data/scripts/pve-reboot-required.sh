#!/bin/sh
# Decide whether a Proxmox host needs a reboot after apt. Prints one reason per
# line; no output means no reboot. Exit status is always 0 -- the caller reads
# stdout, not rc, so a host with nothing to say is not a failed task.
#
# Ubuntu writes /var/run/reboot-required and the guest check reads that file.
# Debian and PVE never write it, which is why the old update-linux playbook
# reported "reboot required: false" for a hypervisor sitting on a stale kernel
# for months. Two signals replace it here:
#
#   1. The running kernel against the newest installed PVE kernel. This is the
#      one that matters and needs nothing installed. PVE kernels are all named
#      vmlinuz-<version>-pve and sort -V orders them correctly across the
#      6.8 -> 6.14 boundary the 8-to-9 upgrade crossed.
#
#   2. needrestart's kernel status, if the tool is present. KSTA 2 is an
#      ABI-compatible kernel update pending, 3 a version change; both want a
#      reboot. It is a second opinion, not a dependency.
#
# No braced expansion anywhere in this file, on purpose: it is delivered by a
# configMapGenerator on a path with postBuild substitution enabled, where an
# unescaped one is silently replaced with an empty string. Bare $var is left
# alone. See lvm-thin-metrics.sh for what the escaped form looks like.

set -u

running=$(uname -r)
newest=$(ls -1 /boot/vmlinuz-*-pve 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -n 1)

if [ -n "$newest" ] && [ "$running" != "$newest" ]; then
    echo "kernel: running $running, newest installed $newest"
fi

if command -v needrestart >/dev/null 2>&1; then
    ksta=$(needrestart -b 2>/dev/null | awk '/^NEEDRESTART-KSTA:/ { print $2 }' | tr -dc 0-9)
    if [ -n "$ksta" ] && [ "$ksta" -ge 2 ]; then
        echo "needrestart: KSTA=$ksta"
    fi
fi

exit 0
