#ifndef OPENCV_BEND_VIDEOIO_DARWIN_H
#define OPENCV_BEND_VIDEOIO_DARWIN_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
  uint32_t token;
  uint32_t width;
  uint32_t height;
  uint32_t stride;
  uint32_t sequence;
  uint32_t timestamp_ms;
  uint32_t captured;
  uint32_t delivered;
  uint32_t superseded;
  uint32_t dropped;
  uint32_t latency_avg_us;
  uint32_t latency_max_us;
  int code;
  char message[256];
} BendVideoResult;

void bend_video_open(uint32_t index, uint32_t width, uint32_t height, uint32_t fps,
  BendVideoResult *result);
size_t bend_video_modes(uint32_t index, uint32_t *triples, size_t max, int *code);
void bend_video_read(uint32_t token, uint32_t timeout_ms, BendVideoResult *result);
void bend_video_stats(uint32_t token, BendVideoResult *result);
int bend_video_is_opened(uint32_t token);
int bend_video_release(uint32_t token, char *message, size_t size);
int bend_video_frame_release(uint32_t token, char *message, size_t size);
int bend_video_snapshot(uint32_t token, const char *path, char *message, size_t size);

// Pixel access: lock a frame for reading (NULL if the token is stale), copy
// rows out, then unlock with the returned handle.
void *bend_video_frame_lock(uint32_t token, const uint8_t **base, uint32_t *width,
  uint32_t *height, size_t *stride);
void bend_video_frame_unlock(void *handle);

// Viewer support (frames are peeked, never consumed).
uint32_t bend_video_count(void);
uint32_t bend_video_token_for_index(uint32_t index);
size_t bend_video_indices(uint32_t *out, size_t max);
int bend_video_next_jpeg(uint32_t token, uint32_t after, uint32_t timeout_ms,
  uint32_t *sequence, char *message, size_t size);
int bend_video_copy_jpeg(uint32_t token, uint8_t **bytes, size_t *length, uint32_t *sequence);
uint32_t bend_video_encodes(uint32_t token);

// Views: named image streams published from Bend (View.publish).
int bend_view_publish(const char *name, uint32_t width, uint32_t height, const uint32_t *pixels);
uint32_t bend_view_token(const char *name);
size_t bend_view_names(char *out, size_t size);

// Encoding in Bend: claim a new frame (or find it cached), then store the bytes.
int bend_video_peek(uint32_t token, uint32_t after, uint32_t timeout_ms, uint32_t *sequence,
  uint32_t *frame, char *message, size_t size);
int bend_video_store_jpeg(uint32_t token, uint32_t sequence, const uint8_t *bytes, size_t length);
int bend_video_frame_drop(uint32_t token);

#endif
