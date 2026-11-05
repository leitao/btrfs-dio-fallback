#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# Real-host variant of guest_test.sh: runs as root on the host's own btrfs,
# so this directory must be on btrfs.  Writes results-<tag>.txt and
# dmesg-<tag>-<scenario>.txt here.
#
# Usage: host_test.sh <tag> [secs]
TAG=${1:-host}
SECS=${2:-10}
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=$DIR/results-$TAG.txt
BIN=$DIR/dio_fallback_race
TR=/sys/kernel/tracing

exec 3>&1 > "$OUT" 2>&1
trap 'cat "$OUT" >&3' EXIT
echo "===START==="
uname -r
echo "PAGESIZE=$(getconf PAGESIZE) NPROC=$(nproc)"
findmnt -no SOURCE,FSTYPE,OPTIONS -T $DIR
echo "SECTORSIZE=$(cat /sys/fs/btrfs/*/sectorsize | head -1)"

mountpoint -q $TR || mount -t tracefs none $TR
echo 2048 > $TR/buffer_size_kb
echo 'r:diorepro_inv2fail invalidate_inode_pages2_range ret=$retval:s32' >> $TR/kprobe_events || cat $TR/error_log
echo 'ret != 0' > $TR/events/kprobes/diorepro_inv2fail/filter
echo 1 > $TR/events/kprobes/diorepro_inv2fail/enable

run() {
	name=$1
	shift
	echo > $TR/trace
	echo "diorepro: start $TAG/$name" > /dev/kmsg
	echo "--- $name: $*"
	$BIN -s "$SECS" "$@" $DIR/block.img
	echo "INV2_FAIL_KWORKER=$(grep 'diorepro_inv2fail:' $TR/trace | grep -c kworker) INV2_FAIL_OTHER=$(grep 'diorepro_inv2fail:' $TR/trace | grep -vc kworker)"
	dmesg | sed -n "/diorepro: start $TAG\/$name\$/,\$p" > $DIR/dmesg-$TAG-$name.txt
	echo "DMESG_WARN=$(grep -c 'Page cache invalidation failure' $DIR/dmesg-$TAG-$name.txt)"
	grep -A1 'Page cache invalidation failure' $DIR/dmesg-$TAG-$name.txt | head -2
}

run aligned-only -m 0
run race -m 4
run race-overlap -m 4 -o
run race-cow -m 4 -C

echo 0 > $TR/events/kprobes/diorepro_inv2fail/enable
echo '-:diorepro_inv2fail' >> $TR/kprobe_events
rm -f $DIR/block.img
echo "===END==="
