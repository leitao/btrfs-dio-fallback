// SPDX-License-Identifier: GPL-2.0
/*
 * Reproducer for "Page cache invalidation failure on direct I/O" on btrfs.
 *
 * One libaio thread keeps 4K-aligned O_DIRECT writes in flight to blocks
 * 1..15 of a set of 64K chunks.  Other threads issue 512-byte O_DIRECT
 * writes at offset 512 of block 0 of the same chunks.  btrfs cannot do
 * those as direct I/O (not sectorsize aligned), so btrfs_direct_write()
 * falls back to a buffered write, which dirties the page cache folio that
 * also covers the in-flight aligned writes when PAGE_SIZE > 4K.  The two
 * streams never write the same bytes.
 *
 * The main thread calls fdatasync() every few milliseconds and counts EIO,
 * which dio_warn_stale_pagecache() records in the mapping on each failure.
 *
 * Usage: dio_fallback_race [-s secs] [-q qd] [-m mis_threads] [-c chunks]
 *                          [-o] [-C] [-f fsync_ms] <file>
 *   -o  aligned writes may also hit block 0 (byte overlap allowed)
 *   -C  keep the file COW (default: set NOCOW, like a VM disk image)
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/aio_abi.h>
#include <linux/fs.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define CHUNK_SZ	(64 * 1024)
#define BLK_SZ		4096
#define MIS_OFF		512
#define MIS_LEN		512

static int opt_secs = 10, opt_qd = 64, opt_mis = 4, opt_chunks = 64;
static int opt_fsync_ms = 5;
static bool opt_overlap, opt_cow;
static int fd;
static atomic_bool stop;
static atomic_ulong aio_done, aio_err, mis_done, mis_err;
static unsigned long fsync_calls, fsync_eio;

static long sys_io_setup(unsigned int nr, aio_context_t *ctx)
{
	return syscall(SYS_io_setup, nr, ctx);
}

static long sys_io_submit(aio_context_t ctx, long nr, struct iocb **iocbs)
{
	return syscall(SYS_io_submit, ctx, nr, iocbs);
}

static long sys_io_getevents(aio_context_t ctx, long min_nr, long nr,
			     struct io_event *ev, struct timespec *ts)
{
	return syscall(SYS_io_getevents, ctx, min_nr, nr, ev, ts);
}

static uint64_t xrand(uint64_t *s)
{
	*s ^= *s << 13;
	*s ^= *s >> 7;
	*s ^= *s << 17;
	return *s;
}

static off_t aio_target(uint64_t *seed)
{
	unsigned int chunk = xrand(seed) % opt_chunks;
	unsigned int blk = opt_overlap ? xrand(seed) % 16 : 1 + xrand(seed) % 15;

	return (off_t)chunk * CHUNK_SZ + (off_t)blk * BLK_SZ;
}

static void *aio_thread(void *arg)
{
	uint64_t seed = 0x9e3779b97f4a7c15ULL;
	aio_context_t ctx = 0;
	struct io_event *ev;
	struct iocb *cbs, **cbp;
	int i, inflight;
	char *bufs;

	(void)arg;
	if (sys_io_setup(opt_qd, &ctx)) {
		perror("io_setup");
		exit(1);
	}
	cbs = calloc(opt_qd, sizeof(*cbs));
	cbp = calloc(opt_qd, sizeof(*cbp));
	ev = calloc(opt_qd, sizeof(*ev));
	if (!cbs || !cbp || !ev ||
	    posix_memalign((void **)&bufs, BLK_SZ, (size_t)opt_qd * BLK_SZ))
		exit(1);
	memset(bufs, 0xa5, (size_t)opt_qd * BLK_SZ);

	for (i = 0; i < opt_qd; i++) {
		cbs[i].aio_fildes = fd;
		cbs[i].aio_lio_opcode = IOCB_CMD_PWRITE;
		cbs[i].aio_buf = (uintptr_t)(bufs + (size_t)i * BLK_SZ);
		cbs[i].aio_nbytes = BLK_SZ;
		cbs[i].aio_offset = aio_target(&seed);
		cbp[i] = &cbs[i];
	}
	if (sys_io_submit(ctx, opt_qd, cbp) != opt_qd) {
		perror("io_submit");
		exit(1);
	}
	inflight = opt_qd;

	while (inflight) {
		int n = sys_io_getevents(ctx, 1, opt_qd, ev, NULL);
		int nsub = 0;

		if (n < 0) {
			if (errno == EINTR)
				continue;
			perror("io_getevents");
			exit(1);
		}
		inflight -= n;
		for (i = 0; i < n; i++) {
			struct iocb *cb = (struct iocb *)(uintptr_t)ev[i].obj;

			if (ev[i].res != BLK_SZ)
				atomic_fetch_add(&aio_err, 1);
			else
				atomic_fetch_add(&aio_done, 1);
			if (atomic_load(&stop))
				continue;
			cb->aio_offset = aio_target(&seed);
			cbp[nsub++] = cb;
		}
		if (nsub) {
			if (sys_io_submit(ctx, nsub, cbp) != nsub) {
				perror("io_submit");
				exit(1);
			}
			inflight += nsub;
		}
	}
	return NULL;
}

static void *mis_thread(void *arg)
{
	uint64_t seed = 0x2545f4914f6cdd1dULL ^ ((uintptr_t)arg << 17);
	char *buf;

	if (posix_memalign((void **)&buf, BLK_SZ, BLK_SZ))
		exit(1);
	memset(buf, 0x5a, BLK_SZ);
	while (!atomic_load(&stop)) {
		unsigned int chunk = xrand(&seed) % opt_chunks;
		off_t off = (off_t)chunk * CHUNK_SZ + MIS_OFF;

		if (pwrite(fd, buf, MIS_LEN, off) != MIS_LEN)
			atomic_fetch_add(&mis_err, 1);
		else
			atomic_fetch_add(&mis_done, 1);
	}
	return NULL;
}

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void prefill(void)
{
	off_t size = (off_t)opt_chunks * CHUNK_SZ;
	char *buf;
	off_t off;

	if (posix_memalign((void **)&buf, BLK_SZ, CHUNK_SZ))
		exit(1);
	memset(buf, 0x11, CHUNK_SZ);
	for (off = 0; off < size; off += CHUNK_SZ) {
		if (pwrite(fd, buf, CHUNK_SZ, off) != CHUNK_SZ) {
			perror("prefill pwrite");
			exit(1);
		}
	}
	if (fsync(fd)) {
		perror("prefill fsync");
		exit(1);
	}
	free(buf);
}

int main(int argc, char **argv)
{
	pthread_t aio_tid, *mis_tids;
	struct timespec nap;
	double end;
	int c, i;

	while ((c = getopt(argc, argv, "s:q:m:c:f:oC")) != -1) {
		switch (c) {
		case 's': opt_secs = atoi(optarg); break;
		case 'q': opt_qd = atoi(optarg); break;
		case 'm': opt_mis = atoi(optarg); break;
		case 'c': opt_chunks = atoi(optarg); break;
		case 'f': opt_fsync_ms = atoi(optarg); break;
		case 'o': opt_overlap = true; break;
		case 'C': opt_cow = true; break;
		default:
			fprintf(stderr, "bad option\n");
			return 2;
		}
	}
	if (optind >= argc) {
		fprintf(stderr, "usage: %s [opts] <file>\n", argv[0]);
		return 2;
	}

	unlink(argv[optind]);
	fd = open(argv[optind], O_RDWR | O_CREAT | O_EXCL, 0644);
	if (fd < 0) {
		perror("open");
		return 1;
	}
	if (!opt_cow) {
		int flags = FS_NOCOW_FL;

		if (ioctl(fd, FS_IOC_SETFLAGS, &flags))
			perror("FS_IOC_SETFLAGS(NOCOW)");
	}
	close(fd);
	fd = open(argv[optind], O_RDWR | O_DIRECT);
	if (fd < 0) {
		perror("open O_DIRECT");
		return 1;
	}
	prefill();

	mis_tids = calloc(opt_mis ? opt_mis : 1, sizeof(*mis_tids));
	pthread_create(&aio_tid, NULL, aio_thread, NULL);
	for (i = 0; i < opt_mis; i++)
		pthread_create(&mis_tids[i], NULL, mis_thread, (void *)(uintptr_t)(i + 1));

	nap.tv_sec = opt_fsync_ms / 1000;
	nap.tv_nsec = (opt_fsync_ms % 1000) * 1000000L;
	end = now() + opt_secs;
	while (now() < end) {
		nanosleep(&nap, NULL);
		fsync_calls++;
		if (fdatasync(fd) && errno == EIO)
			fsync_eio++;
	}
	atomic_store(&stop, true);
	pthread_join(aio_tid, NULL);
	for (i = 0; i < opt_mis; i++)
		pthread_join(mis_tids[i], NULL);
	fsync_calls++;
	if (fdatasync(fd) && errno == EIO)
		fsync_eio++;

	printf("RESULT qd=%d mis=%d chunks=%d overlap=%d cow=%d secs=%d aio_done=%lu aio_err=%lu mis_done=%lu mis_err=%lu fsync_calls=%lu fsync_eio=%lu\n",
	       opt_qd, opt_mis, opt_chunks, opt_overlap, opt_cow, opt_secs,
	       atomic_load(&aio_done), atomic_load(&aio_err),
	       atomic_load(&mis_done), atomic_load(&mis_err),
	       fsync_calls, fsync_eio);
	close(fd);
	return 0;
}
