// Native effects for the browser viewer (src/viewer.bend). Spliced into the
// program's C after Bend's runtime, so runtime helpers are in scope.
// Policy (who may connect, which routes exist, the sharing state machine)
// lives in Bend; this file only moves bytes and answers small questions.

#include "native/videoio_darwin.h"

#include <arpa/inet.h>
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

#define VIEWER_DEFAULT_PORT 8765u
#define VIEWER_MAX_STREAMS 16u
#define VIEWER_SEND_TIMEOUT_MS 5000u

// Loop-thread state (effects run on Bend's event loop, one at a time).
static bool     viewer_claimed;
static int      viewer_requested = -1;  // -1: not read from the environment yet
static bool     viewer_sharing;
static uint32_t viewer_epoch;
static uint32_t viewer_streams;

static Term viewer_bool(bool b) {
  return term_pak(b ? CID(True) : CID(False), 0);
}

static bool viewer_is_true(Term t) {
  return term_aux(t) == CID(True);
}

// --- Viewer.next_jpeg: wait for a newer frame and encode it (helper thread) --

typedef struct {
  uint32_t capture;
  uint32_t after;
  uint32_t timeout_ms;
  uint32_t sequence;
  int code;
  char message[128];
} ViewerNext;

static void viewer_next_call(IoWork *w) {
  ViewerNext *n = (ViewerNext *)w->data;
  n->code = bend_video_next_jpeg(n->capture, n->after, n->timeout_ms,
    &n->sequence, n->message, sizeof(n->message));
}

static Term viewer_next_pack(Env e, IoWork *w) {
  ViewerNext *n = (ViewerNext *)w->data;
  Term answer = n->code == 0 ? io_done(e, (Term)n->sequence)
    : io_fail(e, (u32)n->code, n->message[0] == '\0' ? NULL : n->message);
  free(n);
  return answer;
}

#ifdef CID(Viewer.next_jpeg)

Term viewer_next_run(Env e, Term *f, IoWork *w) {
  ViewerNext *n = io_mem(calloc(1, sizeof(ViewerNext)));
  n->capture = (uint32_t)f[0];
  n->after = (uint32_t)f[1];
  n->timeout_ms = (uint32_t)f[2];
  w->data = (char *)n;
  return io_work(w, viewer_next_call, viewer_next_pack);
}

static void __attribute__((constructor)) viewer_next_use(void) {
  io_eff(CID(Viewer.next_jpeg), viewer_next_run);
}

#endif

// --- Viewer.send_jpeg: write one multipart JPEG part (event loop, POLLOUT) ---
// The buffer's first 8 bytes hold the frame's sequence number; sending
// starts after them. w->word is the fd's slot once parked, so it is not used.

static Term viewer_send_more(Env e, IoWork *w) {
  int fd = (int)w->hand;
  w->code = 0;
  while ((u64)w->made < w->size) {
    ssize_t n;
    do {
      n = send(fd, w->data + w->made, w->size - (u64)w->made, 0);
    } while (n < 0 && errno == EINTR);
    if (n == 0) {
      w->code = EIO;
      break;
    }
    if (n < 0) {
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        if (io_tick() >= w->time) {
          w->code = ETIMEDOUT;
          break;
        }
        return io_wait_on(w, fd, POLLOUT, w->time, viewer_send_more);
      }
      w->code = (u32)errno;
      break;
    }
    w->made += n;
  }
  uint32_t sequence;
  memcpy(&sequence, w->data, sizeof sequence);
  free(w->data);
  Term r = w->code == 0 ? io_done(e, (Term)sequence)
    : io_fail(e, w->code, w->code == ETIMEDOUT ? "The viewer stopped accepting data." : NULL);
  return io_tup(e, io_hand(w->hand), r);
}

#ifdef CID(Viewer.send_jpeg)

Term viewer_send_run(Env e, Term *f, IoWork *w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  uint8_t *jpeg = NULL;
  size_t length = 0;
  uint32_t sequence = 0;
  int code = bend_video_copy_jpeg((uint32_t)f[1], &jpeg, &length, &sequence);
  if (code != 0) {
    return io_tup(e, f[0], io_fail(e, (u32)code, "No encoded frame is available."));
  }
  char head[128];
  int head_len = snprintf(head, sizeof head,
    "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %zu\r\n\r\n", length);
  size_t total = 8u + (size_t)head_len + length + 2u;
  char *buf = io_mem(malloc(total));
  memcpy(buf, &sequence, sizeof sequence);
  memcpy(buf + 8, head, (size_t)head_len);
  memcpy(buf + 8 + head_len, jpeg, length);
  memcpy(buf + 8 + head_len + length, "\r\n", 2);
  free(jpeg);
  w->data = buf;
  w->size = total;
  w->made = 8;
  w->time = io_until(VIEWER_SEND_TIMEOUT_MS);
  return viewer_send_more(e, w);
}

static void __attribute__((constructor)) viewer_send_use(void) {
  io_eff(CID(Viewer.send_jpeg), viewer_send_run);
}

#endif

// --- Viewer.peer_is_local: is the connected peer on this computer? ---------

#ifdef CID(Viewer.peer_is_local)

Term viewer_peer_run(Env e, Term *f, IoWork *w) {
  int fd = (int)io_hand_v(f[0]);
  struct sockaddr_storage at;
  socklen_t len = sizeof at;
  bool local = false;
  if (getpeername(fd, (struct sockaddr *)&at, &len) == 0) {
    if (at.ss_family == AF_INET) {
      local = (ntohl(((struct sockaddr_in *)&at)->sin_addr.s_addr) >> 24) == 127u;
    } else if (at.ss_family == AF_INET6) {
      struct in6_addr *a = &((struct sockaddr_in6 *)&at)->sin6_addr;
      local = IN6_IS_ADDR_LOOPBACK(a) || (IN6_IS_ADDR_V4MAPPED(a) && a->s6_addr[12] == 127u);
    }
  }
  return io_tup(e, f[0], viewer_bool(local));
}

static void __attribute__((constructor)) viewer_peer_use(void) {
  io_eff(CID(Viewer.peer_is_local), viewer_peer_run);
}

#endif

// --- Viewer.lan_addresses: this computer's IPv4 LAN addresses --------------

#ifdef CID(Viewer.lan_addresses)

Term viewer_lan_run(Env e, Term *f, IoWork *w) {
  char out[512] = "";
  size_t used = 0;
  struct ifaddrs *list = NULL;
  if (getifaddrs(&list) == 0) {
    for (struct ifaddrs *i = list; i != NULL; i = i->ifa_next) {
      if (i->ifa_addr == NULL || i->ifa_addr->sa_family != AF_INET
          || !(i->ifa_flags & IFF_UP) || (i->ifa_flags & IFF_LOOPBACK)) {
        continue;
      }
      char text[INET_ADDRSTRLEN];
      inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, text, sizeof text);
      int n = snprintf(out + used, sizeof out - used, "%s%s", used == 0 ? "" : " ", text);
      if (n < 0 || (size_t)n >= sizeof out - used) {
        break;
      }
      used += (size_t)n;
    }
    freeifaddrs(list);
  }
  return io_str(e, out, used);
}

static void __attribute__((constructor)) viewer_lan_use(void) {
  io_eff(CID(Viewer.lan_addresses), viewer_lan_run);
}

#endif

// --- Viewer.random_token: 128 random bits as 32 hex digits -----------------

#ifdef CID(Viewer.random_token)

Term viewer_token_run(Env e, Term *f, IoWork *w) {
  uint8_t bytes[16];
  char text[33];
  arc4random_buf(bytes, sizeof bytes);
  for (size_t i = 0; i < sizeof bytes; i += 1u) {
    snprintf(text + i * 2u, 3, "%02x", bytes[i]);
  }
  return io_str(e, text, 32);
}

static void __attribute__((constructor)) viewer_token_use(void) {
  io_eff(CID(Viewer.random_token), viewer_token_run);
}

#endif

// --- Server singleton, sharing mailbox and published state -----------------

#ifdef CID(Viewer.claim)

Term viewer_claim_run(Env e, Term *f, IoWork *w) {
  bool won = !viewer_claimed;
  viewer_claimed = true;
  return viewer_bool(won);
}

static void __attribute__((constructor)) viewer_claim_use(void) {
  io_eff(CID(Viewer.claim), viewer_claim_run);
}

#endif

#ifdef CID(Viewer.unclaim)

Term viewer_unclaim_run(Env e, Term *f, IoWork *w) {
  viewer_claimed = false;
  return term_pak(CID(Unit), 0);
}

static void __attribute__((constructor)) viewer_unclaim_use(void) {
  io_eff(CID(Viewer.unclaim), viewer_unclaim_run);
}

#endif

static bool viewer_requested_now(void) {
  if (viewer_requested < 0) {
    const char *share = getenv("OPENCV_BEND_SHARE");
    viewer_requested = share != NULL && strcmp(share, "lan") == 0;
  }
  return viewer_requested == 1;
}

#ifdef CID(Viewer.request_sharing)

Term viewer_request_run(Env e, Term *f, IoWork *w) {
  viewer_requested = viewer_is_true(f[0]) ? 1 : 0;
  return term_pak(CID(Unit), 0);
}

static void __attribute__((constructor)) viewer_request_use(void) {
  io_eff(CID(Viewer.request_sharing), viewer_request_run);
}

#endif

#ifdef CID(Viewer.requested_sharing)

Term viewer_requested_run(Env e, Term *f, IoWork *w) {
  return viewer_bool(viewer_requested_now());
}

static void __attribute__((constructor)) viewer_requested_use(void) {
  io_eff(CID(Viewer.requested_sharing), viewer_requested_run);
}

#endif

#ifdef CID(Viewer.publish_state)

Term viewer_publish_run(Env e, Term *f, IoWork *w) {
  viewer_sharing = viewer_is_true(f[0]);
  viewer_epoch = (uint32_t)f[1];
  return term_pak(CID(Unit), 0);
}

static void __attribute__((constructor)) viewer_publish_use(void) {
  io_eff(CID(Viewer.publish_state), viewer_publish_run);
}

#endif

#ifdef CID(Viewer.state)

Term viewer_state_run(Env e, Term *f, IoWork *w) {
  return io_tup(e, viewer_bool(viewer_sharing), (Term)viewer_epoch);
}

static void __attribute__((constructor)) viewer_state_use(void) {
  io_eff(CID(Viewer.state), viewer_state_run);
}

#endif

// --- Open cameras ------------------------------------------------------------

#ifdef CID(Viewer.capture_count)

Term viewer_count_run(Env e, Term *f, IoWork *w) {
  return (Term)bend_video_count();
}

static void __attribute__((constructor)) viewer_count_use(void) {
  io_eff(CID(Viewer.capture_count), viewer_count_run);
}

#endif

#ifdef CID(Viewer.cameras)

Term viewer_cameras_run(Env e, Term *f, IoWork *w) {
  uint32_t indices[64];
  size_t n = bend_video_indices(indices, 64);
  Term list = term_pak(CID(Nil), 0);
  for (size_t i = n; i > 0; i -= 1u) {
    list = io_node(e, CID(Con), (Term)indices[i - 1u], list);
  }
  return list;
}

static void __attribute__((constructor)) viewer_cameras_use(void) {
  io_eff(CID(Viewer.cameras), viewer_cameras_run);
}

#endif

#ifdef CID(Viewer.capture_for)

Term viewer_capture_for_run(Env e, Term *f, IoWork *w) {
  return (Term)bend_video_token_for_index((uint32_t)f[0]);
}

static void __attribute__((constructor)) viewer_capture_for_use(void) {
  io_eff(CID(Viewer.capture_for), viewer_capture_for_run);
}

#endif

#ifdef CID(Viewer.encodes)

Term viewer_encodes_run(Env e, Term *f, IoWork *w) {
  return (Term)bend_video_encodes((uint32_t)f[0]);
}

static void __attribute__((constructor)) viewer_encodes_use(void) {
  io_eff(CID(Viewer.encodes), viewer_encodes_run);
}

#endif

#ifdef CID(Viewer.base_port)

Term viewer_port_run(Env e, Term *f, IoWork *w) {
  const char *text = getenv("OPENCV_BEND_PORT");
  long port = text == NULL ? 0 : strtol(text, NULL, 10);
  return (Term)(uint32_t)(port > 0 && port < 65536 ? port : VIEWER_DEFAULT_PORT);
}

static void __attribute__((constructor)) viewer_port_use(void) {
  io_eff(CID(Viewer.base_port), viewer_port_run);
}

#endif

// --- Concurrent stream cap (each stream briefly uses an IO helper thread) ----

#ifdef CID(Viewer.stream_enter)

Term viewer_enter_run(Env e, Term *f, IoWork *w) {
  bool ok = viewer_streams < VIEWER_MAX_STREAMS;
  viewer_streams += ok;
  return viewer_bool(ok);
}

static void __attribute__((constructor)) viewer_enter_use(void) {
  io_eff(CID(Viewer.stream_enter), viewer_enter_run);
}

#endif

#ifdef CID(Viewer.stream_leave)

Term viewer_leave_run(Env e, Term *f, IoWork *w) {
  viewer_streams -= viewer_streams > 0;
  return term_pak(CID(Unit), 0);
}

static void __attribute__((constructor)) viewer_leave_use(void) {
  io_eff(CID(Viewer.stream_leave), viewer_leave_run);
}

#endif

// --- Views (View.publish) ------------------------------------------------------

#ifdef CID(View.publish_native)

// Copies a Mat's bands (a List of (rows, Array<U32>)) into one row-major
// buffer and publishes it as the newest frame of view `name`. The bands are
// only read, and handed back to Bend unchanged.
Term view_publish_run(Env e, Term *f, IoWork *w) {
  uint64_t name_len = 0;
  char *name = io_cstr(e, f[0], &name_len);
  uint32_t width = (uint32_t)f[1], height = (uint32_t)f[2];
  Term bands = f[3];
  uint32_t *pixels = io_mem(calloc((size_t)width * height + 1u, 4u));
  uint32_t row = 0;
  int code = io_nul(name, name_len) ? EINVAL : 0;
  for (Term s = bands; code == 0 && term_aux(s) == CID(Con);) {
    u64 cell = term_peek(e.mem, s);
    u64 pair = term_peek(e.mem, e.mem[cell]);
    uint32_t rows = (uint32_t)e.mem[pair];
    Term array = e.mem[pair + 1];
    bool is_arr = term_tag(array) == TAG_ARR;
    uint64_t capacity = 1ull << blk_cls(array);
    uint64_t count = (uint64_t)rows * width;
    if (row + rows > height || count > capacity) {
      code = EINVAL;
      break;
    }
    u64 at = blk_loc(e.mem, array);
    if (!is_arr) {
      memcpy(pixels + (size_t)row * width, (const void *)blk_ptr(e.mem, at, 0), (size_t)count * 4u);
    } else {
      for (uint64_t i = 0; i < count; i += 1u) {
        pixels[(size_t)row * width + i] = (uint32_t)blk_read(e.mem, true, at, (u32)i);
      }
    }
    row += rows;
    s = e.mem[cell + 1];
  }
  if (code == 0 && row != height) {
    code = EINVAL;
  }
  if (code == 0) {
    code = bend_view_publish(name, width, height, pixels);
  }
  free(pixels);
  free(name);
  Term result = code == 0 ? io_done(e, term_pak(CID(Unit), 0))
    : io_fail(e, (u32)code, code == EINVAL ? "The image's bands do not match its size." : NULL);
  return io_tup(e, bands, result);
}

static void __attribute__((constructor)) view_publish_use(void) {
  io_eff(CID(View.publish_native), view_publish_run);
}

#endif

#ifdef CID(Viewer.view_for)

Term viewer_view_for_run(Env e, Term *f, IoWork *w) {
  uint64_t len = 0;
  char *name = io_cstr(e, f[0], &len);
  uint32_t token = io_nul(name, len) ? 0 : bend_view_token(name);
  free(name);
  return (Term)token;
}

static void __attribute__((constructor)) viewer_view_for_use(void) {
  io_eff(CID(Viewer.view_for), viewer_view_for_run);
}

#endif

#ifdef CID(Viewer.views)

Term viewer_views_run(Env e, Term *f, IoWork *w) {
  char names[1024];
  size_t n = bend_view_names(names, sizeof names);
  return io_str(e, names, n);
}

static void __attribute__((constructor)) viewer_views_use(void) {
  io_eff(CID(Viewer.views), viewer_views_run);
}

#endif

// --- Encoding in Bend ------------------------------------------------------------
// The viewer claims a new frame (Viewer.peek), copies it into a Mat, encodes it
// with the pure-Bend JPEG encoder and stores the bytes (Viewer.store_jpeg).

Term video_bands_answer(Env e, uint32_t token, uint32_t rows_per_band);  // videoio.c

typedef struct {
  uint32_t capture, after, timeout_ms, sequence, frame;
  int code;
  char message[128];
} ViewerPeek;

static void viewer_peek_call(IoWork *w) {
  ViewerPeek *p = (ViewerPeek *)w->data;
  p->code = bend_video_peek(p->capture, p->after, p->timeout_ms, &p->sequence, &p->frame,
    p->message, sizeof p->message);
}

static Term viewer_peek_pack(Env e, IoWork *w) {
  ViewerPeek *p = (ViewerPeek *)w->data;
  Term answer = p->code == 0 ? io_done(e, io_tup(e, (Term)p->sequence, (Term)p->frame))
    : io_fail(e, (u32)p->code, p->message[0] == '\0' ? NULL : p->message);
  free(p);
  return answer;
}

#ifdef CID(Viewer.peek)

Term viewer_peek_run(Env e, Term *f, IoWork *w) {
  ViewerPeek *p = io_mem(calloc(1, sizeof(ViewerPeek)));
  p->capture = (uint32_t)f[0];
  p->after = (uint32_t)f[1];
  p->timeout_ms = (uint32_t)f[2];
  w->data = (char *)p;
  return io_work(w, viewer_peek_call, viewer_peek_pack);
}

static void __attribute__((constructor)) viewer_peek_use(void) {
  io_eff(CID(Viewer.peek), viewer_peek_run);
}

#endif

#ifdef CID(Viewer.frame_size)

Term viewer_frame_size_run(Env e, Term *f, IoWork *w) {
  const uint8_t *base = NULL;
  uint32_t width = 0, height = 0;
  size_t stride = 0;
  void *frame = bend_video_frame_lock((uint32_t)f[0], &base, &width, &height, &stride);
  if (frame == NULL) {
    return io_fail(e, EBADF, "The frame handle is invalid or has already been released.");
  }
  bend_video_frame_unlock(frame);
  return io_done(e, io_tup(e, (Term)width, (Term)height));
}

static void __attribute__((constructor)) viewer_frame_size_use(void) {
  io_eff(CID(Viewer.frame_size), viewer_frame_size_run);
}

#endif

#ifdef CID(Viewer.frame_bands)

Term viewer_frame_bands_run(Env e, Term *f, IoWork *w) {
  return video_bands_answer(e, (uint32_t)f[0], (uint32_t)f[1]);
}

static void __attribute__((constructor)) viewer_frame_bands_use(void) {
  io_eff(CID(Viewer.frame_bands), viewer_frame_bands_run);
}

#endif

#ifdef CID(Viewer.frame_drop)

Term viewer_frame_drop_run(Env e, Term *f, IoWork *w) {
  bend_video_frame_drop((uint32_t)f[0]);
  return term_pak(CID(Unit), 0);
}

static void __attribute__((constructor)) viewer_frame_drop_use(void) {
  io_eff(CID(Viewer.frame_drop), viewer_frame_drop_run);
}

#endif

#ifdef CID(Viewer.store_jpeg)

// Joins the encoder's segments (a List of (Array<U32>, bytes)) and stores
// them as the frame's JPEG. The segments are handed back unchanged.
Term viewer_store_run(Env e, Term *f, IoWork *w) {
  Term segs = f[2];
  size_t total = 0;
  int code = 0;
  for (Term s = segs; term_aux(s) == CID(Con);) {
    u64 cell = term_peek(e.mem, s);
    u64 pair = term_peek(e.mem, e.mem[cell]);
    Term array = e.mem[pair];
    uint64_t length = (uint32_t)e.mem[pair + 1];
    if (term_tag(array) == TAG_ARR || length > (1ull << blk_cls(array)) * 4u) {
      code = EOVERFLOW;
      break;
    }
    total += (size_t)length;
    s = e.mem[cell + 1];
  }
  uint8_t *bytes = code == 0 ? io_mem(malloc(total + 1u)) : NULL;
  size_t at = 0;
  for (Term s = segs; code == 0 && term_aux(s) == CID(Con);) {
    u64 cell = term_peek(e.mem, s);
    u64 pair = term_peek(e.mem, e.mem[cell]);
    Term array = e.mem[pair];
    size_t length = (size_t)(uint32_t)e.mem[pair + 1];
    memcpy(bytes + at, (const void *)blk_ptr(e.mem, blk_loc(e.mem, array), 0), length);
    at += length;
    s = e.mem[cell + 1];
  }
  if (code == 0) {
    code = bend_video_store_jpeg((uint32_t)f[0], (uint32_t)f[1], bytes, total);
  }
  free(bytes);
  Term result = code == 0 ? io_done(e, term_pak(CID(Unit), 0))
    : io_fail(e, (u32)code, code == EOVERFLOW ? "The encoder overflowed its buffer." : NULL);
  return io_tup(e, segs, result);
}

static void __attribute__((constructor)) viewer_store_use(void) {
  io_eff(CID(Viewer.store_jpeg), viewer_store_run);
}

#endif
