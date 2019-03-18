#include <stddef.h>
#include <stdio.h>
#include <stdint.h>
#include <ctype.h>
#include <errno.h>
#include <unistd.h>
#include <string.h>
#include <sys/mman.h>

#define SIZE_SZ (sizeof(size_t))
#define MALLOC_ALIGNMENT (2 * SIZE_SZ < __alignof__(long double) ? __alignof__(long double) : 2 * SIZE_SZ)
#define MALLOC_ALIGN_MASK (MALLOC_ALIGNMENT - 1)
#define PREV_INUSE 0x1
#define IS_MMAPPED 0x2
#define NON_MAIN_ARENA 0x4
#define SIZE_BITS (PREV_INUSE | IS_MMAPPED | NON_MAIN_ARENA)
#define DEFAULT_MMAP_THRESHOLD_MAX (4 * 1024 * 1024 * sizeof(long))
#define HEAP_MAX_SIZE (2 * DEFAULT_MMAP_THRESHOLD_MAX)
#define NFASTBINS 10
#define NBINS 128
#define heap_for_ptr(ptr) ((struct heap_info *) ((unsigned long) (ptr) & ~(HEAP_MAX_SIZE - 1)))
#define bin_at(m, i) \
	(struct malloc_chunk *) (((char *) &((m)->bins[((i) - 1) * 2]))			      \
		- offsetof (struct malloc_chunk, fd))
#define chunkdata(p) (((const char *) (p)) + 2 * sizeof(size_t))
#define chunksize(p) ((p)->mchunk_size & ~SIZE_BITS)

#define MIN(a, b) ((a) < (b) ? (a) : (b))

struct heap_info;
struct malloc_state;
struct malloc_chunk;

struct heap_info {
	struct malloc_state *ar_ptr;
	struct heap_info *prev;
	size_t size;
	size_t mprotect_size;
	char pad[0];
};

/* Also known as an arena */
struct malloc_state {
	int mutex;
	int flags;
	int have_fastchunks;

	void *fastbinsY[NFASTBINS];
	struct malloc_chunk *top;
	struct malloc_chunk *last_remainder;
	struct malloc_chunk *bins[NBINS * 2 - 2];
	unsigned int binmap[4];
	struct malloc_state *next;
	struct malloc_state *next_free;

	size_t attached_threads;
	size_t system_mem;
	size_t max_system_mem;
};

struct malloc_chunk {
	size_t mchunk_prev_size;
	size_t mchunk_size;
	struct malloc_chunk *fd;
	struct malloc_chunk *bk;
	struct malloc_chunk *fd_nextsize;
	struct malloc_chunk *bk_nextsize;
};

static size_t
generate_bindata_preview(char *output, size_t output_size, const char *input, size_t input_size) {
	size_t len = output_size;
	if (input_size < output_size) {
		len = input_size;
	}

	for (size_t i = 0; i < len; i++) {
		if (isprint(input[i])) {
			output[i] = input[i];
		} else if (input[i] == '\0') {
			output[i] = '0';
		} else {
			output[i] = '.';
		}
	}

	return len;
}

static void
print_page_usages(FILE *f, char *addr, size_t len, size_t pageSize) {
	char *baseAddr = (char *) (((uintptr_t) addr) & ~(pageSize - 1));
	size_t numPages = (len + pageSize - 1) / pageSize;
	unsigned char pagesInUse[128 * 1024 + 1];
	size_t measurableNumPages = MIN(numPages, sizeof(pagesInUse) - 1);
	size_t usableLen = measurableNumPages * pageSize;

	fprintf(f, "Pages in use for %p-%p: ", baseAddr, baseAddr + usableLen);

	int ret = mincore(baseAddr, usableLen, pagesInUse);
	if (ret == 0) {
		for (size_t i = 0; i < measurableNumPages; i++) {
			pagesInUse[i] = pagesInUse[i] ? '1' : '0';
		}
		pagesInUse[sizeof(pagesInUse) - 1] = '\0';
		fprintf(f, "%s", pagesInUse);
		if (measurableNumPages < numPages) {
			fprintf(f, " (incomplete)");
		}
		fprintf(f, "\n");
	} else {
		int e = errno;
		fprintf(f, "ERROR (%s)\n", strerror(e));
	}
}

void
dump_non_main_heap(const char *path, const struct heap_info *heap) {
	char *ptr;
	struct malloc_chunk *p, *next;
	FILE *f = fopen(path, "a");
	long pageSize = sysconf(_SC_PAGESIZE);

	if (f == NULL) {
		fprintf(stderr, "ERROR: cannot open %s for writing.\n", path);
		return;
	}

	fprintf(f, "Heap  %p size %10lu bytes:\n", heap, (unsigned long) heap->size);
	print_page_usages(f, (char *) heap, heap->size, pageSize);

	ptr = (heap->ar_ptr != (struct malloc_state *) (heap + 1)) ?
		(char *) (heap + 1) : (char *) (heap + 1) + sizeof(struct malloc_state);
	p = (struct malloc_chunk *) (((unsigned long) ptr + MALLOC_ALIGN_MASK) &
		~MALLOC_ALIGN_MASK);

	while (p != NULL) {
		next = (struct malloc_chunk *) (((char *) p) + chunksize(p));

		fprintf(f, "chunk %p size %10lu bytes", p, (unsigned long) chunksize(p));
		if (p == heap->ar_ptr->top) {
			fprintf(f, " (top)  ");
			next = NULL;
		} else if (p->mchunk_size == PREV_INUSE) {
			fprintf(f, " (fence)");
			next = NULL;
		} else if (!(next->mchunk_size & PREV_INUSE)) {
			fprintf(f, " [free] ");
		} else {
			char preview[16];
			size_t len = generate_bindata_preview(preview, sizeof(preview),
				chunkdata(p), chunksize(p));
			fprintf(f, "          ");
			fwrite(preview, 1, len, f);
		}

		fprintf(f, "\n");

		p = next;
	}

	fclose(f);
}

void
dump_non_main_heaps(const char *path, struct malloc_state *main_arena) {
	struct malloc_state *ar_ptr = main_arena->next;
	while (ar_ptr != main_arena) {
		struct heap_info *heap = heap_for_ptr(ar_ptr->top);
		do {
			dump_non_main_heap(path, heap);
			heap = heap->prev;
		} while (heap != NULL);
		ar_ptr = ar_ptr->next;
	}
}

void
dump_main_heap(const char *path, struct malloc_state *main_arena) {
	struct malloc_chunk *base, *p;
	FILE *f = fopen(path, "a");
	long pageSize = sysconf(_SC_PAGESIZE);

	if (f == NULL) {
		fprintf(stderr, "ERROR: cannot open %s for writing.\n", path);
		return;
	}

	base = (struct malloc_chunk *) (((const char *) main_arena->top)
		+ chunksize(main_arena->top) - main_arena->system_mem);
	fprintf(f, "Heap  %p size %10lu bytes:\n", base, main_arena->system_mem);
	print_page_usages(f, (char *) base, main_arena->system_mem, pageSize);

	p = base;
	while (p != NULL) {
		struct malloc_chunk *next = (struct malloc_chunk *) (((char *) p) + chunksize(p));

		fprintf(f, "chunk %p size %10lu bytes", p, (unsigned long) chunksize(p));
		if (p == main_arena->top) {
			fprintf(f, " (top)  ");
			next = NULL;
		} else if (p->mchunk_size == PREV_INUSE) {
			fprintf(f, " (fence)");
			next = NULL;
		} else if (!(next->mchunk_size & PREV_INUSE)) {
			fprintf(f, " [free] ");
		} else {
			char preview[16];
			size_t len = generate_bindata_preview(preview, sizeof(preview),
				chunkdata(p), chunksize(p));
			fprintf(f, "          ");
			fwrite(preview, 1, len, f);
		}

		fprintf(f, "\n");fflush(f);

		p = next;
	}

	fclose(f);
}
