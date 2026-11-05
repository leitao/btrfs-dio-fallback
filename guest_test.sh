#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# Micro test, run as root inside a throwaway VM (virtme-ng): btrfs on a
# memory-backed null_blk, then dio_fallback_race in four scenarios.
# The output also lands in results-<tag>.txt next to this script.
#
# Usage: guest_test.sh <tag> [completion_nsec] [secs]
TAG=${1:-run}
LAT=${2:-50000}
SECS=${3:-10}
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=$DIR/results-$TAG.txt
BIN=$DIR/dio_fallback_race
TR=/sys/kernel/tracing

exec 3>&1 > "$OUT" 2>&1
trap 'cat "$OUT" >&3' EXIT
echo "===START==="
uname -r
echo "PAGESIZE=$(getconf PAGESIZE) NPROC=$(nproc) LAT_NS=$LAT"

# memory-backed null_blk with timer completions, so DIO stays in flight a while
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
NB=/sys/kernel/config/nullb/nullb1
mkdir $NB
echo 1 > $NB/memory_backed
echo 2048 > $NB/size
echo 4096 > $NB/blocksize
echo 2 > $NB/irqmode
echo "$LAT" > $NB/completion_nsec
echo 8 > $NB/submit_queues
echo 1 > $NB/power
sleep 1

mkfs.btrfs -q -f -s 4096 /dev/nullb1 || exit 1
MNT=$(mktemp -d /tmp/diorepro.XXXXXX)
mount -o compress-force=zstd:3 /dev/nullb1 $MNT || exit 1
echo "SECTORSIZE=$(cat /sys/fs/btrfs/*/sectorsize)"

# dio_warn_stale_pagecache() prints at most 10 times a day; count the failing
# invalidate_inode_pages2_range() calls instead.  Post-DIO ones run in a kworker.
mountpoint -q $TR || mount -t tracefs none $TR
echo 16384 > $TR/buffer_size_kb
echo 'r:inv2fail invalidate_inode_pages2_range ret=$retval:s32' > $TR/kprobe_events || cat $TR/error_log
echo 'ret != 0' > $TR/events/kprobes/inv2fail/filter
echo 1 > $TR/events/kprobes/inv2fail/enable

run() {
	name=$1
	shift
	echo > $TR/trace
	dmesg -C
	echo "--- $name: $*"
	$BIN -s "$SECS" "$@" $MNT/block.img
	echo "INV2_FAIL_KWORKER=$(grep 'inv2fail:' $TR/trace | grep -c kworker) INV2_FAIL_OTHER=$(grep 'inv2fail:' $TR/trace | grep -vc kworker)"
	echo "DMESG_WARN=$(dmesg | grep -c 'Page cache invalidation failure')"
	dmesg | grep -A1 'Page cache invalidation failure' | head -4
}

run aligned-only -m 0
run race -m 4
run race-overlap -m 4 -o
run race-cow -m 4 -C

echo 0 > $TR/events/kprobes/inv2fail/enable
umount $MNT; rmdir $MNT
echo "===END==="
