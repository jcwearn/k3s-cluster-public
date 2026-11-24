#!/bin/sh
# Liveness check for the gluetun sidecar.
#
# gluetun's own healthcheck covers a tunnel that is down. It does not cover a
# wedge seen three times in November 2026: after a VPN outage gluetun
# reconnects, passes its healthcheck, and then spins at its CPU limit until the
# pod is replaced (19-42 h each time). This script also fails once the
# container has been almost fully CFS-throttled for PINNED_LIMIT probes in a
# row, so the kubelet restarts it.
#
# State lives in /tmp, which a container restart wipes along with the cgroup
# counters it is compared against.

PINNED_LIMIT=10
state=/tmp/liveness-cpu

/gluetun-entrypoint healthcheck || exit 1

set -- $(awk '$1 == "nr_periods" { p = $2 } $1 == "nr_throttled" { t = $2 } END { print p, t }' /sys/fs/cgroup/cpu.stat)
periods=$1
throttled=$2

prev_periods=
prev_throttled=
pinned=0
if [ -r "$state" ]; then
  read -r prev_periods prev_throttled pinned < "$state"
fi

# nr_periods only counts 100 ms periods in which the container ran. Fewer than
# 100 since the last probe means under 10 s of activity: not pinned.
if [ -n "$prev_periods" ] && [ $((periods - prev_periods)) -ge 100 ] &&
  [ $(((throttled - prev_throttled) * 100)) -gt $(((periods - prev_periods) * 90)) ]; then
  pinned=$((pinned + 1))
else
  pinned=0
fi

echo "$periods $throttled $pinned" > "$state"

if [ "$pinned" -ge "$PINNED_LIMIT" ]; then
  echo "throttled in >90% of CFS periods for $pinned consecutive probes"
  exit 1
fi
