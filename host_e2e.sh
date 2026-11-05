#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# Real-host variant of guest_e2e.sh: XFS on a loop device (direct-io=on)
# backed by a NOCOW file on the host's own btrfs, so this directory must be
# on btrfs.  Runs as root; writes results-<tag>.txt and dmesg-<tag>.txt here.
#
# Usage: host_e2e.sh <tag> [secs] [mkfs.xfs opts] [loop sector size] [fsstress opts]
# Set FSSTRESS to the fsstress binary from xfstests (ltp/fsstress).
TAG=${1:-host-e2e}
SECS=${2:-60}
MKFS_OPTS=${3:-}
LOOP_BS=${4:-512}
FSS_OPTS=${5:-}
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=$DIR/results-$TAG.txt
FSSTRESS=${FSSTRESS:-fsstress}
TR=/sys/kernel/tracing

exec 3>&1 > "$OUT" 2>&1
trap 'cat "$OUT" >&3' EXIT
echo "===START==="
uname -r
echo "PAGESIZE=$(getconf PAGESIZE) NPROC=$(nproc)"
findmnt -no SOURCE,FSTYPE,OPTIONS -T $DIR
echo "SECTORSIZE=$(cat /sys/fs/btrfs/*/sectorsize | head -1)"

# the disk image: NOCOW, sparse, then mkfs.xfs on the file
IMG=$DIR/block.img
rm -f $IMG
touch $IMG
chattr +C $IMG
truncate -s 3G $IMG
mkfs.xfs -f $MKFS_OPTS $IMG | grep -E "sectsz"
lsattr $IMG
LOOP=$(losetup --direct-io=on -b $LOOP_BS --show -f $IMG) || exit 1
L=${LOOP#/dev/}
echo "LOOP=$LOOP dio=$(cat /sys/block/$L/loop/dio) lbs=$(cat /sys/block/$L/queue/logical_block_size)"
XMNT=$(mktemp -d /tmp/diorepro-xfs.XXXXXX)
mount -t xfs $LOOP $XMNT || exit 1

mountpoint -q $TR || mount -t tracefs none $TR
echo 2048 > $TR/buffer_size_kb
echo 'r:diorepro_inv2fail invalidate_inode_pages2_range ret=$retval:s32' >> $TR/kprobe_events || cat $TR/error_log
echo 'ret != 0' > $TR/events/kprobes/diorepro_inv2fail/filter
echo 1 > $TR/events/kprobes/diorepro_inv2fail/enable
echo > $TR/trace
echo "diorepro: start $TAG" > /dev/kmsg

echo "--- fsstress -p 8 $FSS_OPTS for ${SECS}s on XFS-over-loop"
mkdir -p $XMNT/fss
timeout "$SECS" $FSSTRESS -d $XMNT/fss -p 8 -n 10000000 $FSS_OPTS > /dev/null 2>&1
echo "fsstress rc=$?"
sync

echo "INV2_FAIL=$(grep -c 'diorepro_inv2fail:' $TR/trace)"
dmesg | sed -n "/diorepro: start $TAG\$/,\$p" > $DIR/dmesg-$TAG.txt
echo "DMESG_WARN=$(grep -c 'Page cache invalidation failure' $DIR/dmesg-$TAG.txt)"
grep -A1 'Page cache invalidation failure' $DIR/dmesg-$TAG.txt | head -2
echo "--- XFS / loop / block errors:"
grep -iE "xfs|loop[0-9]|I/O error|shut" $DIR/dmesg-$TAG.txt | head -12

echo 0 > $TR/events/kprobes/diorepro_inv2fail/enable
echo '-:diorepro_inv2fail' >> $TR/kprobe_events
umount $XMNT
rmdir $XMNT
losetup -d $LOOP
rm -f $IMG
echo "===END==="
