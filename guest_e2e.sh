#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# End-to-end test, run as root inside a throwaway VM (virtme-ng): XFS on a
# loop device (direct-io=on) backed by a NOCOW file on btrfs, the way a VMM
# opens a disk image with O_DIRECT.  fsstress runs on the XFS.
# The output also lands in results-<tag>.txt next to this script.
#
# Usage: guest_e2e.sh <tag> [secs] [mkfs.xfs opts] [dropcache] [loop sector size] [fsstress opts]
# Set FSSTRESS to the fsstress binary from xfstests (ltp/fsstress).
TAG=${1:-e2e}
SECS=${2:-60}
MKFS_OPTS=${3:-}
DROP=${4:-}
LOOP_BS=${5:-512}
FSS_OPTS=${6:-}
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=$DIR/results-$TAG.txt
FSSTRESS=${FSSTRESS:-fsstress}
TR=/sys/kernel/tracing

exec 3>&1 > "$OUT" 2>&1
trap 'cat "$OUT" >&3' EXIT
echo "===START==="
uname -r
echo "PAGESIZE=$(getconf PAGESIZE) NPROC=$(nproc)"

mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
NB=/sys/kernel/config/nullb/nullb1
mkdir $NB
echo 1 > $NB/memory_backed
echo 4096 > $NB/size
# 512-byte sectors under btrfs; btrfs itself still uses 4K blocks (-s 4096)
echo 512 > $NB/blocksize
echo 2 > $NB/irqmode
echo 50000 > $NB/completion_nsec
echo 8 > $NB/submit_queues
echo 1 > $NB/power
sleep 1

mkfs.btrfs -q -f -s 4096 /dev/nullb1 || exit 1
MNT=$(mktemp -d /tmp/diorepro.XXXXXX)
mount -o compress-force=zstd:3 /dev/nullb1 $MNT || exit 1
echo "SECTORSIZE=$(cat /sys/fs/btrfs/*/sectorsize)"

# the disk image: NOCOW, sparse, then mkfs.xfs on the file
IMG=$MNT/block.img
touch $IMG
chattr +C $IMG
truncate -s 3G $IMG
mkfs.xfs -f $MKFS_OPTS $IMG | grep -E "sectsz|log "
lsattr $IMG
echo "after mkfs: $(fincore -n -o RES,PAGES $IMG)"
if [ -n "$DROP" ]; then
	echo 1 > /proc/sys/vm/drop_caches
	echo "after drop_caches: $(fincore -n -o RES,PAGES $IMG)"
fi
LOOP=$(losetup --direct-io=on -b $LOOP_BS --show -f $IMG) || exit 1
L=${LOOP#/dev/}
echo "LOOP=$LOOP dio=$(cat /sys/block/$L/loop/dio) lbs=$(cat /sys/block/$L/queue/logical_block_size)"
XMNT=$(mktemp -d /tmp/diorepro-xfs.XXXXXX)
mount -t xfs $LOOP $XMNT || exit 1
echo "after xfs mount: $(fincore -n -o RES,PAGES $IMG)"

mountpoint -q $TR || mount -t tracefs none $TR
echo 16384 > $TR/buffer_size_kb
echo 'r:inv2fail invalidate_inode_pages2_range ret=$retval:s32' > $TR/kprobe_events || cat $TR/error_log
echo 'ret != 0' > $TR/events/kprobes/inv2fail/filter
echo 1 > $TR/events/iomap/iomap_dio_invalidate_fail/enable
echo 1 > $TR/events/kprobes/inv2fail/enable
echo > $TR/trace
dmesg -C

echo "--- fsstress -p 8 $FSS_OPTS for ${SECS}s on XFS-over-loop"
mkdir -p $XMNT/fss
timeout "$SECS" $FSSTRESS -d $XMNT/fss -p 8 -n 10000000 $FSS_OPTS > /dev/null 2>&1
echo "fsstress rc=$?"
sync

echo "INV2_FAIL_KWORKER=$(grep 'inv2fail:' $TR/trace | grep -c kworker) INV2_FAIL_OTHER=$(grep 'inv2fail:' $TR/trace | grep -vc kworker)"
echo "PRE_DIO_INVALIDATE_FAIL=$(grep -c iomap_dio_invalidate_fail: $TR/trace)"
echo "DMESG_WARN=$(dmesg | grep -c 'Page cache invalidation failure')"
dmesg | grep -A1 'Page cache invalidation failure' | head -2
echo "--- XFS / loop / block errors:"
dmesg | grep -iE "xfs|loop[0-9]|I/O error|shut" | head -20

echo 0 > $TR/events/kprobes/inv2fail/enable
umount $XMNT
losetup -d $LOOP
umount $MNT
echo "===END==="
