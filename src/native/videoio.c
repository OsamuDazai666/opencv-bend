#include "native/videoio_darwin.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  BendVideoResult result;
  char *path;
  uint32_t mode[4];  // open: index, width, height, fps
} VideoCall;

static Term video_pack(Env e, IoWork *w, Term value) {
  VideoCall *call = (VideoCall *)w->data;
  Term answer = call->result.code == 0
    ? io_done(e, value)
    : io_fail(e, call->result.code,
        call->result.message[0] == '\0' ? NULL : call->result.message);
  free(call->path);
  free(call);
  return answer;
}

static Term video_release_pack(Env e, IoWork *w) {
  return video_pack(e, w, term_pak(CID(Unit), 0));
}

// Builds a constructor with n > 1 fields the way compiled Bend code does:
// one heap block of the field count's size class, each field sealed.
// (Base's io_node only covers two fields; a one-field constructor of a U32
// is packed inline with term_pak.)
static Term video_node(Env e, u64 cid, const Term *fields, u32 count) {
  u64 at = heap_alloc(e, cls_fit(count));
  for (u32 i = 0; i < count; i += 1) {
    e.mem[at + i] = io_seal(e, fields[i], cid);
  }
  return term_ctr(cid, at);
}

static VideoCall *video_call_new(IoWork *w) {
  VideoCall *call = io_mem(calloc(1, sizeof(VideoCall)));
  w->data = (char *)call;
  return call;
}

#ifdef CID(VideoCapture.open_native)

static void video_open_call(IoWork *w) {
  VideoCall *call = (VideoCall *)w->data;
  bend_video_open(call->mode[0], call->mode[1], call->mode[2], call->mode[3], &call->result);
}

static Term video_open_pack(Env e, IoWork *w) {
  VideoCall *call = (VideoCall *)w->data;
  Term capture = term_pak(CID(Capture), (Term)call->result.token);
  return video_pack(e, w, capture);
}

Term video_open_run(Env e, Term *f, IoWork *w) {
  VideoCall *call = video_call_new(w);
  for (int i = 0; i < 4; i += 1) {
    call->mode[i] = (uint32_t)f[i];
  }
  return io_work(w, video_open_call, video_open_pack);
}

static void __attribute__((constructor)) video_open_use(void) {
  io_eff(CID(VideoCapture.open_native), video_open_run);
}

#endif

#ifdef CID(VideoCapture.read_native)

static void video_read_call(IoWork *w) {
  VideoCall *call = (VideoCall *)w->data;
  bend_video_read((uint32_t)w->made, (uint32_t)w->word, &call->result);
}

static Term video_read_pack(Env e, IoWork *w) {
  VideoCall *call = (VideoCall *)w->data;
  BendVideoResult *r = &call->result;
  Term fields[6] = {(Term)r->token, (Term)r->width, (Term)r->height,
    (Term)r->stride, (Term)r->sequence, (Term)r->timestamp_ms};
  Term frame = video_node(e, CID(Frame), fields, 6);
  return video_pack(e, w, frame);
}

Term video_read_run(Env e, Term *f, IoWork *w) {
  w->made = (intptr_t)(uint32_t)f[0];
  w->word = (uint32_t)f[1];
  video_call_new(w);
  return io_work(w, video_read_call, video_read_pack);
}

static void __attribute__((constructor)) video_read_use(void) {
  io_eff(CID(VideoCapture.read_native), video_read_run);
}

#endif

#ifdef CID(VideoCapture.stats_native)

static void video_stats_call(IoWork *w) {
  VideoCall *call = (VideoCall *)w->data;
  bend_video_stats((uint32_t)w->word, &call->result);
}

static Term video_stats_pack(Env e, IoWork *w) {
  VideoCall *call = (VideoCall *)w->data;
  BendVideoResult *r = &call->result;
  Term fields[6] = {(Term)r->captured, (Term)r->delivered, (Term)r->superseded,
    (Term)r->dropped, (Term)r->latency_avg_us, (Term)r->latency_max_us};
  Term stats = video_node(e, CID(VideoStats), fields, 6);
  return video_pack(e, w, stats);
}

Term video_stats_run(Env e, Term *f, IoWork *w) {
  w->word = (uint32_t)f[0];
  video_call_new(w);
  return io_work(w, video_stats_call, video_stats_pack);
}

static void __attribute__((constructor)) video_stats_use(void) {
  io_eff(CID(VideoCapture.stats_native), video_stats_run);
}

#endif

#ifdef CID(VideoCapture.is_opened_native)

Term video_is_opened_run(Env e, Term *f, IoWork *w) {
  (void)w;
  return term_pak(bend_video_is_opened((uint32_t)f[0]) ? CID(True) : CID(False), 0);
}

static void __attribute__((constructor)) video_is_opened_use(void) {
  io_eff(CID(VideoCapture.is_opened_native), video_is_opened_run);
}

#endif

#ifdef CID(VideoCapture.release_native)

static void video_release_call(IoWork *w) {
  VideoCall *call = (VideoCall *)w->data;
  call->result.code = bend_video_release((uint32_t)w->word,
    call->result.message, sizeof(call->result.message));
}

Term video_release_run(Env e, Term *f, IoWork *w) {
  w->word = (uint32_t)f[0];
  video_call_new(w);
  return io_work(w, video_release_call, video_release_pack);
}

static void __attribute__((constructor)) video_release_use(void) {
  io_eff(CID(VideoCapture.release_native), video_release_run);
}

#endif

#ifdef CID(Frame.release_native)

static void video_frame_release_call(IoWork *w) {
  VideoCall *call = (VideoCall *)w->data;
  call->result.code = bend_video_frame_release((uint32_t)w->word,
    call->result.message, sizeof(call->result.message));
}

Term video_frame_release_run(Env e, Term *f, IoWork *w) {
  w->word = (uint32_t)f[0];
  video_call_new(w);
  return io_work(w, video_frame_release_call, video_release_pack);
}

static void __attribute__((constructor)) video_frame_release_use(void) {
  io_eff(CID(Frame.release_native), video_frame_release_run);
}

#endif

#ifdef CID(Frame.snapshot_native)

static void video_snapshot_call(IoWork *w) {
  VideoCall *call = (VideoCall *)w->data;
  call->result.code = bend_video_snapshot((uint32_t)w->word, call->path,
    call->result.message, sizeof(call->result.message));
}

Term video_snapshot_run(Env e, Term *f, IoWork *w) {
  uint64_t length = 0;
  VideoCall *call = video_call_new(w);
  call->path = io_cstr(e, f[1], &length);
  w->word = (uint32_t)f[0];
  if (io_nul(call->path, length)) {
    call->result.code = EILSEQ;
    snprintf(call->result.message, sizeof(call->result.message),
      "%s", "The snapshot path contains a null byte.");
    return video_release_pack(e, w);
  }
  return io_work(w, video_snapshot_call, video_release_pack);
}

static void __attribute__((constructor)) video_snapshot_use(void) {
  io_eff(CID(Frame.snapshot_native), video_snapshot_run);
}

#endif

#ifdef CID(VideoCapture.modes_native)

// A camera's modes as a flat list: width, height, fps, width, height, fps, ...
// (src/modes.bend turns it into Modes).
Term video_modes_run(Env e, Term *f, IoWork *w) {
  uint32_t triples[3 * 64];
  int code = 0;
  size_t n = bend_video_modes((uint32_t)f[0], triples, 64, &code);
  if (code != 0) {
    return io_fail(e, (u32)code, "No camera exists at the requested index.");
  }
  Term list = term_pak(CID(Nil), 0);
  for (size_t i = n * 3u; i > 0; i -= 1u) {
    list = io_node(e, CID(Con), (Term)triples[i - 1u], list);
  }
  return io_done(e, list);
}

static void __attribute__((constructor)) video_modes_use(void) {
  io_eff(CID(VideoCapture.modes_native), video_modes_run);
}

#endif

// Copies a frame's pixels into Bend arrays, one per band of `rows_per_band`
// rows (Bend chooses the band size and, with swap_rb, asks for red and blue
// to be swapped: BGRA frames become RGBA Mats): a List of (rows, Array<U32>) pairs,
// top to bottom. Row padding is dropped; each array is a packed U32 block
// (TAG_BUF) of the next power-of-two size, zero-filled past the pixels.
// Not static: the viewer's encoder (viewer.c) uses it too.
Term video_bands_answer(Env e, uint32_t token, uint32_t rows_per_band, uint32_t swap_rb) {
  const uint8_t *base = NULL;
  uint32_t width = 0, height = 0;
  size_t stride = 0;
  if (rows_per_band == 0) {
    return io_fail(e, EINVAL, "Bands must hold at least one row.");
  }
  void *frame = bend_video_frame_lock(token, &base, &width, &height, &stride);
  if (frame == NULL) {
    return io_fail(e, EBADF, "The frame handle is invalid or has already been released.");
  }
  uint32_t bands = (height + rows_per_band - 1u) / rows_per_band;
  Term list = term_pak(CID(Nil), 0);
  for (uint32_t k = bands; k > 0; k -= 1u) {
    uint32_t y0 = (k - 1u) * rows_per_band;
    uint32_t rows = height - y0 < rows_per_band ? height - y0 : rows_per_band;
    uint32_t count = width * rows;
    uint32_t cls = 0;
    while ((1u << cls) < count) {
      cls += 1u;
    }
    u64 at = heap_alloc(e, blk_wcls(false, cls));
    uint32_t *dst = (uint32_t *)blk_ptr(e.mem, at, 0);
    for (uint32_t r = 0; r < rows; r += 1u) {
      const uint32_t *src = (const uint32_t *)(base + (size_t)(y0 + r) * stride);
      uint32_t *out = dst + (size_t)r * width;
      if (swap_rb) {
        for (uint32_t x = 0; x < width; x += 1u) {
          uint32_t p = src[x];
          out[x] = (p & 0xFF00FF00u) | ((p >> 16) & 0xFFu) | ((p & 0xFFu) << 16);
        }
      } else {
        memcpy(out, src, (size_t)width * 4u);
      }
    }
    memset(dst + count, 0, ((size_t)(1u << cls) - count) * 4u);
    list = io_node(e, CID(Con), io_tup(e, (Term)rows, term_blk(false, cls, at)), list);
  }
  bend_video_frame_unlock(frame);
  return io_done(e, list);
}

#ifdef CID(Frame.bands_native)

Term video_bands_run(Env e, Term *f, IoWork *w) {
  return video_bands_answer(e, (uint32_t)f[0], (uint32_t)f[1], (uint32_t)f[2]);
}

static void __attribute__((constructor)) video_bands_use(void) {
  io_eff(CID(Frame.bands_native), video_bands_run);
}

#endif
