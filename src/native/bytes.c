// Writes byte segments made in Bend: a List of (Array<U32>, length in bytes),
// four bytes per U32, little-endian (the array memory is the byte stream).
// Moves bytes only; the segments are handed back to Bend unchanged.

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Calls write(ctx, bytes, n) for each segment; answers 0 or an errno.
static int bytes_each(Env e, Term segs, int (*write)(void *, const uint8_t *, size_t), void *ctx,
    uint64_t *total) {
  *total = 0;
  for (Term s = segs; term_aux(s) == CID(Con);) {
    u64 cell = term_peek(e.mem, s);
    u64 pair = term_peek(e.mem, e.mem[cell]);
    Term array = e.mem[pair];
    uint64_t length = (uint32_t)e.mem[pair + 1];
    uint64_t capacity = (1ull << blk_cls(array)) * 4u;
    if (term_tag(array) == TAG_ARR || length > capacity) {
      return EOVERFLOW;
    }
    int code = write(ctx, (const uint8_t *)blk_ptr(e.mem, blk_loc(e.mem, array), 0), (size_t)length);
    if (code != 0) {
      return code;
    }
    *total += length;
    s = e.mem[cell + 1];
  }
  return 0;
}

static int bytes_to_file(void *ctx, const uint8_t *bytes, size_t n) {
  return fwrite(bytes, 1, n, (FILE *)ctx) == n ? 0 : (errno == 0 ? EIO : errno);
}

#ifdef CID(Bytes.write_file)

Term bytes_write_file_run(Env e, Term *f, IoWork *w) {
  uint64_t len = 0;
  char *path = io_cstr(e, f[0], &len);
  Term segs = f[1];
  uint64_t total = 0;
  int code = io_nul(path, len) ? EINVAL : 0;
  FILE *file = code == 0 ? fopen(path, "wb") : NULL;
  if (code == 0 && file == NULL) {
    code = errno == 0 ? EIO : errno;
  }
  if (code == 0) {
    code = bytes_each(e, segs, bytes_to_file, file, &total);
  }
  if (file != NULL && fclose(file) != 0 && code == 0) {
    code = errno;
  }
  free(path);
  Term result = code == 0 ? io_done(e, (Term)(uint32_t)total)
    : io_fail(e, (u32)code, code == EOVERFLOW ? "A segment is longer than its array (encoder overflow)." : NULL);
  return io_tup(e, segs, result);
}

static void __attribute__((constructor)) bytes_write_file_use(void) {
  io_eff(CID(Bytes.write_file), bytes_write_file_run);
}

#endif
