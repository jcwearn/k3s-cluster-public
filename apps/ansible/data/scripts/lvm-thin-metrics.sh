#!/bin/sh
# Export LVM thin-pool fullness for node_exporter's textfile collector.
#
# The PVE API reports thin-pool DATA usage, which is what pve_disk_usage_bytes
# and the ProxmoxStorage* alerts already watch. It does not report thin-pool
# METADATA usage, and that is the failure that cannot be undone: when the
# metadata LV fills, the pool goes read-only and deleting data does not bring it
# back, because releasing a block is itself a metadata write. Repairing it means
# lvconvert --repair against a spare LV, offline.
#
# Metadata is small relative to data and usually grows with the number of
# distinct blocks rather than their volume, so it can approach full while data
# sits comfortably low -- which is precisely why nothing else notices.
#
# Written to a temp file and renamed, because the collector may read the
# directory mid-write and a half-written file is a parse error rather than a
# missing metric.

set -eu

DIR=/var/lib/prometheus/node-exporter
OUT=$DIR/lvm_thin.prom
TMP=$OUT.tmp

{
    echo '# HELP lvm_thin_data_percent Percent of a thin pool'"'"'s data space in use.'
    echo '# TYPE lvm_thin_data_percent gauge'
    echo '# HELP lvm_thin_metadata_percent Percent of a thin pool'"'"'s metadata space in use.'
    echo '# TYPE lvm_thin_metadata_percent gauge'

    # lv_attr starts with t on thin pools. --select keeps this to pools rather
    # than every LV, most of which report an empty data_percent.
    lvs --noheadings --nameprefixes --readonly \
        --select 'lv_attr=~"^t"' \
        -o vg_name,lv_name,data_percent,metadata_percent 2>/dev/null |
        sed -e 's/^ *//' |
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            eval "$line"
            # The doubled dollar is not a typo. This file is pulled in by a
            # configMapGenerator on a path with postBuild substitution enabled,
            # so a braced expansion is replaced with an empty string before it
            # ever reaches a host, and doubling the dollar escapes it back to
            # one. Unbraced expansion is left alone, which is why every other
            # one here is written bare.
            [ -n "$${LVM2_DATA_PERCENT:-}" ] || continue
            printf 'lvm_thin_data_percent{vg="%s",lv="%s"} %s\n' \
                "$LVM2_VG_NAME" "$LVM2_LV_NAME" "$LVM2_DATA_PERCENT"
            printf 'lvm_thin_metadata_percent{vg="%s",lv="%s"} %s\n' \
                "$LVM2_VG_NAME" "$LVM2_LV_NAME" "$LVM2_METADATA_PERCENT"
        done
} >"$TMP"

mv "$TMP" "$OUT"
