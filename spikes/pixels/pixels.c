// Spike: hand a BGRA frame to Bend as an Array<U32> (one pixel per U32).
// Bend lays out Array<U32> as a packed buffer block (TAG_BUF): 2^c u32
// slots in 2^(c-1) heap words, read through blk_ptr. We allocate one and
// copy rows into it, dropping each row's stride padding.

#include <stdint.h>
#include <string.h>
#include <time.h>

#define SPIKE_W 640u
#define SPIKE_H 480u
#define SPIKE_STRIDE (SPIKE_W * 4u + 64u)  // padded rows, like CVPixelBuffer

static uint8_t spike_src[SPIKE_STRIDE * SPIKE_H];
static int spike_ready = 0;

static void spike_fill(void) {
  if (spike_ready) {
    return;
  }
  for (uint32_t y = 0; y < SPIKE_H; y += 1u) {
    for (uint32_t x = 0; x < SPIKE_W; x += 1u) {
      uint8_t *p = spike_src + (size_t)y * SPIKE_STRIDE + (size_t)x * 4u;
      p[0] = (uint8_t)(x * 3u + y);   // B
      p[1] = (uint8_t)(x + y * 2u);   // G
      p[2] = (uint8_t)(x ^ y);        // R
      p[3] = 255;                     // A
    }
  }
  spike_ready = 1;
}

static uint32_t spike_luma(uint32_t px) {
  uint32_t b = px & 255u, g = (px >> 8) & 255u, r = (px >> 16) & 255u;
  return (77u * r + 150u * g + 29u * b) >> 8;
}

static uint32_t spike_log2_ceil(uint32_t n) {
  uint32_t c = 0;
  while ((1u << c) < n) {
    c += 1u;
  }
  return c;
}

Term spike_frame_run(Env e, Term *f, IoWork *w) {
  (void)f;
  (void)w;
  spike_fill();
  uint32_t n = SPIKE_W * SPIKE_H;
  uint32_t c = spike_log2_ceil(n);
  u64 loc = heap_alloc(e, blk_wcls(false, c));
  uint32_t *dst = (uint32_t *)blk_ptr(e.mem, loc, 0);
  for (uint32_t y = 0; y < SPIKE_H; y += 1u) {
    memcpy(dst + (size_t)y * SPIKE_W, spike_src + (size_t)y * SPIKE_STRIDE, SPIKE_W * 4u);
  }
  memset(dst + n, 0, ((size_t)(1u << c) - n) * 4u);  // black padding: luma 0
  return term_blk(false, c, loc);
}

// Answers (sum, elapsed microseconds) of `reps` native luma sums.
Term spike_native_run(Env e, Term *f, IoWork *w) {
  (void)w;
  uint32_t reps = (uint32_t)f[0];
  spike_fill();
  struct timespec a, b;
  clock_gettime(CLOCK_MONOTONIC, &a);
  volatile uint32_t sum = 0;
  for (uint32_t r = 0; r < reps; r += 1u) {
    uint32_t s = 0;
    for (uint32_t y = 0; y < SPIKE_H; y += 1u) {
      const uint8_t *row = spike_src + (size_t)y * SPIKE_STRIDE;
      for (uint32_t x = 0; x < SPIKE_W; x += 1u) {
        uint32_t px;
        memcpy(&px, row + (size_t)x * 4u, 4u);
        s += spike_luma(px);
      }
    }
    sum = s;
  }
  clock_gettime(CLOCK_MONOTONIC, &b);
  uint64_t us = (uint64_t)(b.tv_sec - a.tv_sec) * 1000000ull
    + (uint64_t)(b.tv_nsec - a.tv_nsec) / 1000ull;
  return io_tup(e, (Term)sum, (Term)(uint32_t)us);
}

static void __attribute__((constructor)) spike_use(void) {
  io_eff(CID(Spike.frame_native), spike_frame_run);
  io_eff(CID(Spike.native_native), spike_native_run);
}
