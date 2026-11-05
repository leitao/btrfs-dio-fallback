# btrfs: direct I/O fallback races with in-flight direct I/O

A reproducer for this btrfs message, which comes with `fsync()` failing with
`EIO`:

```
Page cache invalidation failure on direct I/O.  Possible data corruption due to collision with buffered I/O!
File: /path/to/disk.img PID: 501 Comm: kworker/4:1
```

The message blames the application for mixing buffered and direct I/O. Here
nothing does that: every write is `O_DIRECT`, no two writes touch the same
bytes, and btrfs itself turns some of them into buffered writes. It shows up
with VM disk images kept as NOCOW files on btrfs and opened with `O_DIRECT`,
mostly on arm64 hosts with 64K pages.

## What happens

1. Task A submits an async `O_DIRECT` write to a 4K block. iomap invalidates
   the page cache in the range and submits the bio, and the inode lock is
   dropped while the write is in flight.
2. Task B issues an `O_DIRECT` write that btrfs cannot do as direct I/O: its
   offset, length or user buffer is not aligned to the 4K sectorsize (also
   compressed or inline extents, or page cache in the range).
3. `btrfs_direct_write()` falls back to `btrfs_buffered_write()`, which
   dirties the folio without waiting for direct I/O in flight. With 64K pages
   a folio holds 16 btrfs blocks, so it can be the folio of task A's block.
4. Task A's write completes. The page cache is not empty, so the completion
   runs in a kworker and calls `kiocb_invalidate_post_direct_write()`.
5. `invalidate_inode_pages2_range()` finds the folio dirty and fails with
   `-EBUSY`.
6. `dio_warn_stale_pagecache()` prints the message (at most 10 times a day)
   and records `-EIO` in the mapping, every time.
7. The next `fsync()`/`fdatasync()` of the file returns `EIO`. With XFS on a
   loop device backed by the file, standing in for a VM guest, that fails a
   log write and XFS shuts down.

With 4K pages, task B's write has to land in the same 4K block as task A's
(the `-o` scenario below).

Why the writes are not 4K aligned: btrfs does not report `STATX_DIOALIGN`, so
loop and VMMs fall back to 512-byte sectors; `mkfs.xfs` on a file on btrfs
picks 512-byte sectors; and guest `O_DIRECT` buffers need only 512-byte
alignment. btrfs checks both the offset and the buffer address against its
sectorsize. Giving the guest XFS 4K sectors (`mkfs.xfs -s size=4096`) and the
loop device a 4K sector size is not enough: fsstress `O_DIRECT` buffers that
are only 512-byte aligned still fall back and still trigger it.

Kernel versions:

- The fallback has never waited for in-flight direct I/O, at least since
  btrfs moved to iomap direct I/O (v5.10).
- From v6.15 (968f19c5b1b7) to v7.2, every `O_DIRECT` write to a checksummed
  (COW) file was turned into a buffered write, so COW files could not hit it.
  v7.3 (e9b7b9d9e78e5b) made those writes direct I/O again, with bounce
  buffers, so COW files are exposed too (the `-C` scenario).

## Files

| File | What |
|---|---|
| `dio_fallback_race.c` | the reproducer, `make` builds it |
| `guest_test.sh` | micro test in a throwaway VM: btrfs on null_blk, four scenarios |
| `guest_e2e.sh` | end to end in a VM: XFS on a loop device over a NOCOW file, fsstress |
| `host_test.sh`, `host_e2e.sh` | the same two on a real host's btrfs |
| `kernel.config` | config fragment for the VM kernel |
| `results/` | output of the runs below |
| `0001-*.patch` | proposed fix |

## dio_fallback_race

```
dio_fallback_race [-s secs] [-q qd] [-m threads] [-c chunks] [-f fsync_ms] [-o] [-C] <file>
```

1. Recreates `<file>`, sets it NOCOW (unless `-C`) and fills `-c` (64)
   chunks of 64K with `O_DIRECT` writes.
2. One thread keeps `-q` (64) 4K `O_DIRECT` writes in flight with libaio, to
   blocks 1 to 15 of random chunks. With `-o` they can hit block 0 too.
3. `-m` (4) threads `pwrite()` 512 bytes at offset 512 of random chunks,
   through the same `O_DIRECT` file descriptor. btrfs does these as buffered
   writes.
4. The main thread calls `fdatasync()` every `-f` (5) ms and counts `EIO`.
5. After `-s` (10) seconds it prints a `RESULT` line. Any `fsync_eio` above
   zero is the bug.

Quick check on any btrfs: `make && ./dio_fallback_race /mnt/btrfs/test.img`.

## Running it in a VM (virtme-ng)

The guest sees the host filesystem, so the scripts and the reproducer run
from this directory, and the results land next to the scripts. The host needs
btrfs-progs, xfsprogs, util-linux, e2fsprogs and, for the end-to-end test,
`fsstress` from xfstests (`ltp/fsstress`).

```
# arm64 kernel with 64K pages
cd linux
vng --kconfig
scripts/kconfig/merge_config.sh -m .config $REPRO/kernel.config
make olddefconfig && make -j$(nproc)

cd $REPRO && make
vng --run ~/linux/arch/arm64/boot/Image --memory 16G --cpus 16 --rw --user root \
    --append null_blk.nr_devices=0 \
    --exec "sh $REPRO/guest_test.sh micro-64k"

vng --run ~/linux/arch/arm64/boot/Image --memory 16G --cpus 16 --rw --user root \
    --append null_blk.nr_devices=0 \
    --exec "FSSTRESS=$XFSTESTS/ltp/fsstress sh $REPRO/guest_e2e.sh e2e-64k 60"
```

`guest_test.sh` counts the failed invalidations with a kretprobe on
`invalidate_inode_pages2_range()`, since the message itself is rate limited.

## Running it on a host

Copy this directory onto a btrfs filesystem, run `make`, then as root:

```
sh host_test.sh mytag 10
FSSTRESS=/path/to/fsstress sh host_e2e.sh mytag-e2e 90
```

`host_e2e.sh` shuts down an XFS on a loop device over a 3G file in this
directory. The host's own btrfs is not affected.

## Results

Micro test: 10 seconds per scenario in a 16 vCPU VM, btrfs with 4K sectors on
null_blk with 50 us completions. Each cell is failed post-write invalidations
/ `fdatasync()` calls that returned `EIO`.

| Kernel | aligned only | race | race `-o` | race `-C` |
|---|---|---|---|---|
| next-20261104, 64K pages | 0 / 0 | 1889 / 1123 | 1201 / 811 | 144 / 119 |
| next-20261104 + fix, 64K pages | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| next-20261103, 4K pages | 0 / 0 | 0 / 0 | 368 / 331 | not run |
| 7.1-based, 64K pages, 72-core NVIDIA Grace host | 0 / 0 | 3 / 3 | 24 / 22 | 0 / 0 |

End to end: XFS (default `mkfs.xfs`, 512-byte sectors) on a loop device with
direct I/O over a 3G NOCOW file, `fsstress -p 8`.

| Kernel | Result |
|---|---|
| next-20261104, 64K pages | `XFS (loop0): log I/O error -5`, shut down 2 s after mount |
| next-20261104 + fix, 64K pages | no errors in 60 s |
| next-20261103, 4K pages | no errors in 60 s |
| 7.1-based, 64K pages, Grace host | `log I/O error -5`, shut down |

## Fix

`btrfs_buffered_write()` runs with the inode lock held exclusively, so no new
direct I/O can start there. The proposed fix waits for the direct I/O already
in flight (`inode_dio_wait()`) at that point when the buffered write is a
fallback from `btrfs_direct_write()`, as ext4 does since 15cdefd0c052 ("ext4:
drain in-flight DIO before buffered write fallback"). The same race was fixed
for ext2 and is being fixed for ntfs and exfat ("fs: drain in-flight DIO
before buffered write fallback").

## License

GPL-2.0, see `LICENSE`.
