#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

#include "videoio_darwin.h"

#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define VIDEO_CAPTURE_SLOTS 64
#define VIDEO_FRAME_SLOTS 256
#define VIDEO_GENERATION_MASK 0x00ffffffu

typedef struct BendCapture BendCapture;

@interface BendVideoDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate> {
 @public
  BendCapture *capture;
}
@end

struct BendCapture {
  uint32_t token;
  size_t references;
  pthread_mutex_t lock;
  pthread_cond_t ready;
  CVPixelBufferRef latest;
  uint64_t captured_at_ns;
  uint32_t sequence;
  uint32_t consumed_sequence;
  uint32_t delivered;
  uint32_t superseded;
  uint32_t dropped;
  uint32_t window_sequence;
  uint64_t latency_total_ns;
  uint64_t latency_max_ns;
  int error_code;
  char error_message[256];
  bool closed;
  AVCaptureSession *session;
  BendVideoDelegate *delegate;
  dispatch_queue_t queue;
  // The camera index this capture was opened with (0 is the default camera).
  uint32_t index;
  // Test pattern source (OPENCV_BEND_TEST_PATTERN=1) instead of a camera.
  dispatch_source_t timer;
  uint32_t pattern_frame;
  // Viewer: the newest JPEG, encoded at most once per frame and shared by
  // every browser watching. Guarded by encode_lock.
  pthread_mutex_t encode_lock;
  CFDataRef jpeg;
  uint32_t jpeg_sequence;
  uint32_t encodes;
  // The frame a viewer has claimed to encode in Bend (guarded by lock).
  uint32_t encoding_sequence;
  // A view: a named image stream fed by View.publish instead of a camera.
  bool is_view;
  char name[33];
};

typedef struct {
  uint32_t token;
  size_t references;
  CVPixelBufferRef pixels;
  uint32_t width;
  uint32_t height;
  uint32_t stride;
  uint32_t sequence;
  uint32_t timestamp_ms;
} BendFrame;

static pthread_mutex_t video_registry_lock = PTHREAD_MUTEX_INITIALIZER;
static BendCapture *video_captures[VIDEO_CAPTURE_SLOTS];
static BendFrame *video_frames[VIDEO_FRAME_SLOTS];
static uint32_t video_capture_generations[VIDEO_CAPTURE_SLOTS];
static uint32_t video_frame_generations[VIDEO_FRAME_SLOTS];

static void video_message(char *destination, size_t size, const char *format, ...) {
  if (size == 0) {
    return;
  }
  va_list arguments;
  va_start(arguments, format);
  vsnprintf(destination, size, format, arguments);
  va_end(arguments);
}

static int video_result_error(BendVideoResult *result, int code, const char *message) {
  result->code = code;
  video_message(result->message, sizeof(result->message), "%s", message);
  return code;
}

static uint64_t video_now_ns(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
}

static uint32_t video_make_token(uint32_t *generation, size_t slot) {
  uint32_t next = (*generation + 1u) & VIDEO_GENERATION_MASK;
  if (next == 0) {
    next = 1;
  }
  *generation = next;
  return (next << 8) | (uint32_t)(slot + 1u);
}

static size_t video_token_slot(uint32_t token) {
  uint32_t low = token & 0xffu;
  return low == 0 ? SIZE_MAX : (size_t)(low - 1u);
}

static void video_queue_release(dispatch_queue_t queue) {
  dispatch_release(queue);
}

static void video_capture_destroy(BendCapture *capture) {
  if (capture->latest != NULL) {
    CVPixelBufferRelease(capture->latest);
  }
  if (capture->jpeg != NULL) {
    CFRelease(capture->jpeg);
  }
  if (capture->timer != NULL) {
    dispatch_release(capture->timer);
  }
  pthread_mutex_destroy(&capture->encode_lock);
  [capture->session release];
  [capture->delegate release];
  if (capture->queue != NULL) {
    video_queue_release(capture->queue);
  }
  pthread_cond_destroy(&capture->ready);
  pthread_mutex_destroy(&capture->lock);
  free(capture);
}

static void video_capture_unref(BendCapture *capture) {
  bool destroy = false;
  pthread_mutex_lock(&video_registry_lock);
  capture->references -= 1u;
  destroy = capture->references == 0;
  pthread_mutex_unlock(&video_registry_lock);
  if (destroy) {
    video_capture_destroy(capture);
  }
}

static BendCapture *video_capture_get(uint32_t token, bool retain) {
  size_t slot = video_token_slot(token);
  BendCapture *capture = NULL;
  pthread_mutex_lock(&video_registry_lock);
  if (slot < VIDEO_CAPTURE_SLOTS && video_captures[slot] != NULL
      && video_captures[slot]->token == token) {
    capture = video_captures[slot];
    if (retain) {
      capture->references += 1u;
    }
  }
  pthread_mutex_unlock(&video_registry_lock);
  return capture;
}

static void video_capture_set_error(BendCapture *capture, int code, NSString *message) {
  pthread_mutex_lock(&capture->lock);
  if (!capture->closed) {
    capture->error_code = code;
    const char *text = message == nil ? NULL : message.UTF8String;
    video_message(capture->error_message, sizeof(capture->error_message), "%s",
      text == NULL ? "AVCaptureSession stopped" : text);
  }
  pthread_cond_broadcast(&capture->ready);
  pthread_mutex_unlock(&capture->lock);
}

// Takes ownership of one retain on pixels: publishes it as the latest frame.
static void video_capture_push(BendCapture *capture, CVPixelBufferRef pixels) {
  pthread_mutex_lock(&capture->lock);
  if (!capture->closed) {
    if (capture->latest != NULL) {
      CVPixelBufferRelease(capture->latest);
      // Only a frame no read has taken yet counts as superseded.
      if (capture->sequence != capture->consumed_sequence) {
        capture->superseded += 1u;
      }
    }
    capture->latest = pixels;
    capture->captured_at_ns = video_now_ns();
    capture->sequence += 1u;
    pixels = NULL;
    pthread_cond_broadcast(&capture->ready);
  }
  pthread_mutex_unlock(&capture->lock);
  if (pixels != NULL) {
    CVPixelBufferRelease(pixels);
  }
}

@implementation BendVideoDelegate

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
    fromConnection:(AVCaptureConnection *)connection {
  (void)output;
  (void)connection;
  CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (pixels == NULL) {
    video_capture_set_error(capture, EIO, @"The camera delivered a frame without pixel data");
    return;
  }
  CVPixelBufferRetain(pixels);
  video_capture_push(capture, pixels);
}

- (void)captureOutput:(AVCaptureOutput *)output
    didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
    fromConnection:(AVCaptureConnection *)connection {
  (void)output;
  (void)sampleBuffer;
  (void)connection;
  pthread_mutex_lock(&capture->lock);
  capture->dropped += 1u;
  pthread_mutex_unlock(&capture->lock);
}
- (void)sessionWasInterrupted:(NSNotification *)notification {
  (void)notification;
  video_capture_set_error(capture, EAGAIN, @"The camera session was interrupted");
}

- (void)sessionInterruptionEnded:(NSNotification *)notification {
  (void)notification;
  pthread_mutex_lock(&capture->lock);
  if (capture->error_code == EAGAIN) {
    capture->error_code = 0;
    capture->error_message[0] = '\0';
  }
  pthread_mutex_unlock(&capture->lock);
}

- (void)sessionRuntimeError:(NSNotification *)notification {
  NSError *error = notification.userInfo[AVCaptureSessionErrorKey];
  NSString *message = error == nil
    ? @"The camera session reported a runtime error"
    : [NSString stringWithFormat:@"The camera session failed: %@", error.localizedDescription];
  video_capture_set_error(capture, EIO, message);
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [super dealloc];
}

@end

static void video_capture_close(BendCapture *capture) {
  pthread_mutex_lock(&capture->lock);
  capture->closed = true;
  pthread_cond_broadcast(&capture->ready);
  pthread_mutex_unlock(&capture->lock);

  if (capture->timer != NULL) {
    dispatch_source_cancel(capture->timer);
    dispatch_sync(capture->queue, ^{
    });
    return;
  }
  dispatch_sync(capture->queue, ^{
    [capture->session stopRunning];
  });
  [[NSNotificationCenter defaultCenter] removeObserver:capture->delegate];
}

// Test pattern: a moving gradient with a sweeping bar, 1280x720 BGRA at 30 FPS.
// Selected with OPENCV_BEND_TEST_PATTERN=1, so the viewer and the capture
// path can be exercised on machines (or sessions) without camera access.
#define VIDEO_PATTERN_W 1280u
#define VIDEO_PATTERN_H 720u

static bool video_pattern_wanted(void) {
  const char *value = getenv("OPENCV_BEND_TEST_PATTERN");
  return value != NULL && value[0] != '\0' && strcmp(value, "0") != 0;
}

static void video_pattern_tick(BendCapture *capture) {
  CVPixelBufferRef pixels = NULL;
  NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
  if (CVPixelBufferCreate(kCFAllocatorDefault, VIDEO_PATTERN_W, VIDEO_PATTERN_H,
        kCVPixelFormatType_32BGRA, (CFDictionaryRef)attributes, &pixels) != kCVReturnSuccess) {
    video_capture_set_error(capture, ENOMEM, @"The test pattern could not allocate a frame");
    return;
  }
  CVPixelBufferLockBaseAddress(pixels, 0);
  uint8_t *base = CVPixelBufferGetBaseAddress(pixels);
  size_t stride = CVPixelBufferGetBytesPerRow(pixels);
  uint32_t t = capture->pattern_frame;
  uint32_t bar = (t * 8u) % VIDEO_PATTERN_W;
  const char *mode = getenv("OPENCV_BEND_TEST_PATTERN");
  bool noisy = mode != NULL && strcmp(mode, "noisy") == 0;
  for (uint32_t y = 0; y < VIDEO_PATTERN_H; y += 1u) {
    uint8_t *row = base + (size_t)y * stride;
    for (uint32_t x = 0; x < VIDEO_PATTERN_W; x += 1u) {
      bool in_bar = x >= bar && x < bar + 24u;
      row[x * 4u] = in_bar ? 255 : (uint8_t)(x / 5u + t);        // B
      row[x * 4u + 1u] = in_bar ? 255 : (uint8_t)(y / 3u + t * 2u); // G
      row[x * 4u + 2u] = in_bar ? 255 : (uint8_t)((x + y) / 8u);    // R
      row[x * 4u + 3u] = 255;
      if (noisy) {
        // Camera-like detail: hash noise on top (large JPEGs, like real scenes).
        uint32_t h = (x * 73856093u) ^ (y * 19349663u) ^ (t * 83492791u);
        h ^= h >> 13;
        h *= 0x5bd1e995u;
        row[x * 4u] = (uint8_t)(row[x * 4u] / 2u + (h & 127u));
        row[x * 4u + 1u] = (uint8_t)(row[x * 4u + 1u] / 2u + ((h >> 8) & 127u));
        row[x * 4u + 2u] = (uint8_t)(row[x * 4u + 2u] / 2u + ((h >> 16) & 127u));
      }
    }
  }
  CVPixelBufferUnlockBaseAddress(pixels, 0);
  capture->pattern_frame = t + 1u;
  video_capture_push(capture, pixels);
}

static int video_pattern_start(BendCapture *capture) {
  capture->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, capture->queue);
  if (capture->timer == NULL) {
    return ENOMEM;
  }
  dispatch_source_set_timer(capture->timer, dispatch_time(DISPATCH_TIME_NOW, 0),
    NSEC_PER_SEC / 30u, NSEC_PER_MSEC);
  dispatch_source_set_event_handler(capture->timer, ^{
    @autoreleasepool {
      video_pattern_tick(capture);
    }
  });
  dispatch_resume(capture->timer);
  return 0;
}

// Index 0 is the system default camera; 1, 2, ... list every camera.
static AVCaptureDevice *video_device_for_index(uint32_t index) {
  if (index == 0) {
    return [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  }
  NSArray<AVCaptureDeviceType> *types = @[
    AVCaptureDeviceTypeBuiltInWideAngleCamera,
    AVCaptureDeviceTypeExternal
  ];
  AVCaptureDeviceDiscoverySession *discovery =
    [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types
      mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified];
  return (size_t)(index - 1u) < discovery.devices.count ? discovery.devices[index - 1u] : nil;
}

static uint32_t video_format_max_fps(AVCaptureDeviceFormat *format) {
  double best = 0;
  for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
    best = range.maxFrameRate > best ? range.maxFrameRate : best;
  }
  return (uint32_t)(best + 0.5);
}

// The device format for a mode Bend chose (exact size, rate at least fps).
static AVCaptureDeviceFormat *video_format_for(AVCaptureDevice *device, uint32_t width,
    uint32_t height, uint32_t fps) {
  for (AVCaptureDeviceFormat *format in device.formats) {
    CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
    if ((uint32_t)size.width == width && (uint32_t)size.height == height
        && video_format_max_fps(format) >= fps) {
      return format;
    }
  }
  return nil;
}

static int video_capture_configure(BendCapture *capture, uint32_t index, uint32_t width,
    uint32_t height, uint32_t fps) {
  AVCaptureDevice *device = video_device_for_index(index);
  if (device == nil) {
    return ENXIO;
  }
  AVCaptureDeviceFormat *format = video_format_for(device, width, height, fps);
  if (format == nil || fps == 0) {
    return EINVAL;
  }

  NSError *error = nil;
  AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
  if (input == nil || ![capture->session canAddInput:input]) {
    return error == nil ? EINVAL : EIO;
  }
  [capture->session addInput:input];

  AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
  output.alwaysDiscardsLateVideoFrames = YES;
  output.videoSettings = @{
    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
  };
  if (![capture->session canAddOutput:output]) {
    [output release];
    return EINVAL;
  }
  [capture->session addOutput:output];
  capture->delegate = [[BendVideoDelegate alloc] init];
  capture->delegate->capture = capture;
  [output setSampleBufferDelegate:capture->delegate queue:capture->queue];
  [output release];

  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  [center addObserver:capture->delegate selector:@selector(sessionWasInterrupted:)
    name:AVCaptureSessionWasInterruptedNotification object:capture->session];
  [center addObserver:capture->delegate selector:@selector(sessionInterruptionEnded:)
    name:AVCaptureSessionInterruptionEndedNotification object:capture->session];
  [center addObserver:capture->delegate selector:@selector(sessionRuntimeError:)
    name:AVCaptureSessionRuntimeErrorNotification object:capture->session];
  // Apply the chosen mode. The device stays locked until the session runs:
  // on macOS, committing or starting a session can otherwise reset the
  // format to the session preset's choice.
  NSError *lock_error = nil;
  if (![device lockForConfiguration:&lock_error]) {
    return EBUSY;
  }
  device.activeFormat = format;
  device.activeVideoMinFrameDuration = CMTimeMake(1, (int32_t)fps);
  [capture->session commitConfiguration];
  [capture->session startRunning];
  [device unlockForConfiguration];
  return capture->session.running ? 0 : EIO;
}

// Lists a camera's modes as (width, height, max fps) triples, without
// opening it (no camera permission is needed). Answers the count; *code is
// ENXIO when there is no such camera.
size_t bend_video_modes(uint32_t index, uint32_t *triples, size_t max, int *code) {
  *code = 0;
  if (video_pattern_wanted()) {
    if (max == 0) {
      return 0;
    }
    triples[0] = VIDEO_PATTERN_W;
    triples[1] = VIDEO_PATTERN_H;
    triples[2] = 30;
    return 1;
  }
  size_t count = 0;
  @autoreleasepool {
    AVCaptureDevice *device = video_device_for_index(index);
    if (device == nil) {
      *code = ENXIO;
      return 0;
    }
    for (AVCaptureDeviceFormat *format in device.formats) {
      CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
      uint32_t w = (uint32_t)size.width, h = (uint32_t)size.height, fps = video_format_max_fps(format);
      bool seen = false;
      for (size_t i = 0; i < count && !seen; i += 1u) {
        seen = triples[i * 3u] == w && triples[i * 3u + 1u] == h && triples[i * 3u + 2u] == fps;
      }
      if (!seen && count < max) {
        triples[count * 3u] = w;
        triples[count * 3u + 1u] = h;
        triples[count * 3u + 2u] = fps;
        count += 1u;
      }
    }
  }
  return count;
}

static int video_capture_alloc(uint32_t index, BendCapture **created) {
  BendCapture *capture = calloc(1, sizeof(*capture));
  if (capture == NULL) {
    return ENOMEM;
  }
  capture->references = 1;
  capture->index = index;
  if (pthread_mutex_init(&capture->lock, NULL) != 0) {
    free(capture);
    return ENOMEM;
  }
  if (pthread_mutex_init(&capture->encode_lock, NULL) != 0) {
    pthread_mutex_destroy(&capture->lock);
    free(capture);
    return ENOMEM;
  }
  if (pthread_cond_init(&capture->ready, NULL) != 0) {
    pthread_mutex_destroy(&capture->encode_lock);
    pthread_mutex_destroy(&capture->lock);
    free(capture);
    return ENOMEM;
  }
  capture->queue = dispatch_queue_create("org.bend.opencv.videoio", DISPATCH_QUEUE_SERIAL);
  if (capture->queue == NULL) {
    video_capture_destroy(capture);
    return ENOMEM;
  }
  *created = capture;
  return 0;
}

static int video_capture_create(uint32_t index, uint32_t width, uint32_t height, uint32_t fps,
    BendCapture **created) {
  if (video_pattern_wanted()) {
    BendCapture *capture = NULL;
    int code = video_capture_alloc(index, &capture);
    if (code == 0 && (code = video_pattern_start(capture)) != 0) {
      video_capture_destroy(capture);
    }
    if (code == 0) {
      *created = capture;
    }
    return code;
  }
  AVAuthorizationStatus authorization =
    [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  if (authorization == AVAuthorizationStatusDenied
      || authorization == AVAuthorizationStatusRestricted) {
    return EPERM;
  }
  if (authorization == AVAuthorizationStatusNotDetermined) {
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    __block BOOL allowed = NO;
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
      allowed = granted;
      dispatch_semaphore_signal(answered);
    }];
    dispatch_semaphore_wait(answered, DISPATCH_TIME_FOREVER);
    dispatch_release(answered);
    if (!allowed) {
      return EPERM;
    }
  }

  BendCapture *capture = NULL;
  int made = video_capture_alloc(index, &capture);
  if (made != 0) {
    return made;
  }
  capture->session = [[AVCaptureSession alloc] init];
  if (capture->session == nil) {
    video_capture_destroy(capture);
    return ENODEV;
  }
  [capture->session beginConfiguration];

  __block int code = 0;
  dispatch_sync(capture->queue, ^{
    code = video_capture_configure(capture, index, width, height, fps);
  });
  if (code != 0) {
    pthread_mutex_lock(&capture->lock);
    capture->closed = true;
    pthread_mutex_unlock(&capture->lock);
    video_capture_destroy(capture);
    return code;
  }
  *created = capture;
  return 0;
}

void bend_video_open(uint32_t index, uint32_t width, uint32_t height, uint32_t fps,
    BendVideoResult *result) {
  memset(result, 0, sizeof(*result));
  @autoreleasepool {
    BendCapture *capture = NULL;
    int code = video_capture_create(index, width, height, fps, &capture);
    if (code == EPERM) {
      video_result_error(result, code, "Camera permission was denied. Enable it in macOS Privacy & Security settings.");
      return;
    }
    if (code == ENXIO) {
      video_result_error(result, code, "No camera exists at the requested index. Index 0 selects the default camera.");
      return;
    }
    if (code == EINVAL) {
      video_result_error(result, code, "The camera does not offer the requested mode.");
      return;
    }
    if (code == EBUSY) {
      video_result_error(result, code, "The camera could not be configured; another app may be using it.");
      return;
    }
    if (code != 0) {
      video_result_error(result, code, "The camera could not be opened or configured.");
      return;
    }

    pthread_mutex_lock(&video_registry_lock);
    size_t slot = 0;
    while (slot < VIDEO_CAPTURE_SLOTS && video_captures[slot] != NULL) {
      slot += 1u;
    }
    if (slot == VIDEO_CAPTURE_SLOTS) {
      pthread_mutex_unlock(&video_registry_lock);
      video_capture_close(capture);
      video_capture_unref(capture);
      video_result_error(result, ENOSPC, "Too many camera captures are open.");
      return;
    }
    capture->token = video_make_token(&video_capture_generations[slot], slot);
    video_captures[slot] = capture;
    result->token = capture->token;
    pthread_mutex_unlock(&video_registry_lock);
  }
}

static uint32_t video_frame_create(CVPixelBufferRef pixels, const BendVideoResult *source) {
  BendFrame *frame = calloc(1, sizeof(*frame));
  if (frame == NULL) {
    CVPixelBufferRelease(pixels);
    return 0;
  }
  frame->references = 1;
  frame->pixels = pixels;
  frame->width = source->width;
  frame->height = source->height;
  frame->stride = source->stride;
  frame->sequence = source->sequence;
  frame->timestamp_ms = source->timestamp_ms;

  pthread_mutex_lock(&video_registry_lock);
  size_t slot = 0;
  while (slot < VIDEO_FRAME_SLOTS && video_frames[slot] != NULL) {
    slot += 1u;
  }
  if (slot == VIDEO_FRAME_SLOTS) {
    pthread_mutex_unlock(&video_registry_lock);
    CVPixelBufferRelease(frame->pixels);
    free(frame);
    return 0;
  }
  frame->token = video_make_token(&video_frame_generations[slot], slot);
  video_frames[slot] = frame;
  pthread_mutex_unlock(&video_registry_lock);
  return frame->token;
}

static BendFrame *video_frame_get(uint32_t token, bool retain) {
  size_t slot = video_token_slot(token);
  BendFrame *frame = NULL;
  pthread_mutex_lock(&video_registry_lock);
  if (slot < VIDEO_FRAME_SLOTS && video_frames[slot] != NULL
      && video_frames[slot]->token == token) {
    frame = video_frames[slot];
    if (retain) {
      frame->references += 1u;
    }
  }
  pthread_mutex_unlock(&video_registry_lock);
  return frame;
}

static void video_frame_unref(BendFrame *frame) {
  bool destroy = false;
  pthread_mutex_lock(&video_registry_lock);
  frame->references -= 1u;
  destroy = frame->references == 0;
  pthread_mutex_unlock(&video_registry_lock);
  if (destroy) {
    CVPixelBufferRelease(frame->pixels);
    free(frame);
  }
}

void bend_video_read(uint32_t token, uint32_t timeout_ms, BendVideoResult *result) {
  memset(result, 0, sizeof(*result));
  if (timeout_ms == 0) {
    video_result_error(result, EINVAL, "The frame timeout must be greater than zero milliseconds.");
    return;
  }
  BendCapture *capture = video_capture_get(token, true);
  if (capture == NULL) {
    video_result_error(result, EBADF, "The camera handle is invalid or has already been released.");
    return;
  }

  struct timespec deadline;
  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_sec += timeout_ms / 1000u;
  deadline.tv_nsec += (long)(timeout_ms % 1000u) * 1000000l;
  if (deadline.tv_nsec >= 1000000000l) {
    deadline.tv_sec += 1;
    deadline.tv_nsec -= 1000000000l;
  }

  CVPixelBufferRef pixels = NULL;
  int code = 0;
  pthread_mutex_lock(&capture->lock);
  while (!capture->closed && capture->error_code == 0
      && capture->sequence == capture->consumed_sequence) {
    if (pthread_cond_timedwait(&capture->ready, &capture->lock, &deadline) == ETIMEDOUT) {
      code = ETIMEDOUT;
      break;
    }
  }
  if (code == 0 && capture->error_code != 0) {
    code = capture->error_code;
    video_message(result->message, sizeof(result->message), "%s", capture->error_message);
  } else if (code == 0 && capture->closed) {
    code = EPIPE;
  } else if (code == 0) {
    pixels = capture->latest;
    CVPixelBufferRetain(pixels);
    result->width = (uint32_t)CVPixelBufferGetWidth(pixels);
    result->height = (uint32_t)CVPixelBufferGetHeight(pixels);
    result->stride = (uint32_t)CVPixelBufferGetBytesPerRow(pixels);
    result->sequence = capture->sequence;
    result->timestamp_ms = (uint32_t)(capture->captured_at_ns / 1000000ull);
    capture->consumed_sequence = capture->sequence;
    capture->delivered += 1u;
    uint64_t latency = video_now_ns() - capture->captured_at_ns;
    capture->latency_total_ns += latency;
    if (latency > capture->latency_max_ns) {
      capture->latency_max_ns = latency;
    }
  }
  pthread_mutex_unlock(&capture->lock);
  video_capture_unref(capture);

  if (code == ETIMEDOUT) {
    video_result_error(result, code, "No camera frame arrived before the read timeout.");
  } else if (code == EPIPE) {
    video_result_error(result, code, "The camera was released while a read was pending.");
  } else if (code != 0) {
    result->code = code;
  } else {
    result->token = video_frame_create(pixels, result);
    if (result->token == 0) {
      video_result_error(result, ENOSPC, "Too many captured frames are retained. Release frames before reading more.");
    }
  }
}

void bend_video_stats(uint32_t token, BendVideoResult *result) {
  memset(result, 0, sizeof(*result));
  BendCapture *capture = video_capture_get(token, false);
  if (capture == NULL) {
    video_result_error(result, EBADF, "The camera handle is invalid or has already been released.");
    return;
  }
  pthread_mutex_lock(&capture->lock);
  result->captured = capture->sequence - capture->window_sequence;
  result->delivered = capture->delivered;
  result->superseded = capture->superseded;
  result->dropped = capture->dropped;
  result->latency_avg_us = capture->delivered == 0 ? 0u
    : (uint32_t)(capture->latency_total_ns / capture->delivered / 1000ull);
  result->latency_max_us = (uint32_t)(capture->latency_max_ns / 1000ull);
  capture->window_sequence = capture->sequence;
  capture->delivered = 0;
  capture->superseded = 0;
  capture->dropped = 0;
  capture->latency_total_ns = 0;
  capture->latency_max_ns = 0;
  pthread_mutex_unlock(&capture->lock);
}

int bend_video_is_opened(uint32_t token) {
  BendCapture *capture = video_capture_get(token, false);
  if (capture == NULL) {
    return 0;
  }
  pthread_mutex_lock(&capture->lock);
  int opened = !capture->closed && (capture->timer != NULL || capture->session.running);
  pthread_mutex_unlock(&capture->lock);
  return opened;
}

int bend_video_release(uint32_t token, char *message, size_t size) {
  size_t slot = video_token_slot(token);
  BendCapture *capture = NULL;
  pthread_mutex_lock(&video_registry_lock);
  if (slot < VIDEO_CAPTURE_SLOTS && video_captures[slot] != NULL
      && video_captures[slot]->token == token) {
    capture = video_captures[slot];
    video_captures[slot] = NULL;
  }
  pthread_mutex_unlock(&video_registry_lock);
  if (capture == NULL) {
    video_message(message, size, "The camera handle is invalid or has already been released.");
    return EBADF;
  }
  video_capture_close(capture);
  video_capture_unref(capture);
  return 0;
}

int bend_video_frame_release(uint32_t token, char *message, size_t size) {
  size_t slot = video_token_slot(token);
  BendFrame *frame = NULL;
  pthread_mutex_lock(&video_registry_lock);
  if (slot < VIDEO_FRAME_SLOTS && video_frames[slot] != NULL
      && video_frames[slot]->token == token) {
    frame = video_frames[slot];
    video_frames[slot] = NULL;
  }
  pthread_mutex_unlock(&video_registry_lock);
  if (frame == NULL) {
    video_message(message, size, "The frame handle is invalid or has already been released.");
    return EBADF;
  }
  video_frame_unref(frame);
  return 0;
}

int bend_video_snapshot(uint32_t token, const char *path, char *message, size_t size) {
  BendFrame *frame = video_frame_get(token, true);
  if (frame == NULL) {
    video_message(message, size, "The frame handle is invalid or has already been released.");
    return EBADF;
  }
  int code = CVPixelBufferLockBaseAddress(frame->pixels, kCVPixelBufferLock_ReadOnly);
  if (code != kCVReturnSuccess) {
    video_frame_unref(frame);
    video_message(message, size, "The captured pixel buffer could not be locked for reading.");
    return EIO;
  }
  const uint8_t *base = CVPixelBufferGetBaseAddress(frame->pixels);
  errno = 0;
  FILE *file = fopen(path, "wb");
  if (base == NULL || file == NULL) {
    code = errno == 0 ? EIO : errno;
    video_message(message, size, "The snapshot file could not be opened.");
  } else if (CVPixelBufferGetPixelFormatType(frame->pixels) != kCVPixelFormatType_32BGRA) {
    code = EILSEQ;
    video_message(message, size, "The captured frame is not in BGRA format.");
  } else {
    fprintf(file, "P6\n%u %u\n255\n", frame->width, frame->height);
    uint8_t *row = malloc((size_t)frame->width * 3u);
    if (row == NULL) {
      code = ENOMEM;
      video_message(message, size, "The snapshot row buffer could not be allocated.");
    }
    for (uint32_t y = 0; code == 0 && y < frame->height; y += 1u) {
      const uint8_t *source = base + (size_t)y * frame->stride;
      for (uint32_t x = 0; x < frame->width; x += 1u) {
        row[x * 3u] = source[x * 4u + 2u];
        row[x * 3u + 1u] = source[x * 4u + 1u];
        row[x * 3u + 2u] = source[x * 4u];
      }
      if (fwrite(row, (size_t)frame->width * 3u, 1, file) != 1) {
        code = errno == 0 ? EIO : errno;
        video_message(message, size, "The snapshot file could not be written completely.");
      }
    }
    free(row);
  }
  if (file != NULL && fclose(file) != 0 && code == 0) {
    code = errno;
    video_message(message, size, "The snapshot file could not be closed cleanly.");
  }
  CVPixelBufferUnlockBaseAddress(frame->pixels, kCVPixelBufferLock_ReadOnly);
  video_frame_unref(frame);
  return code;
}

// ---------------------------------------------------------------------------
// Viewer support: the browser viewer peeks at the latest frame without
// consuming it, so a program's own reads (and their statistics) are unaffected.

uint32_t bend_video_count(void) {
  uint32_t count = 0;
  pthread_mutex_lock(&video_registry_lock);
  for (size_t slot = 0; slot < VIDEO_CAPTURE_SLOTS; slot += 1u) {
    count += video_captures[slot] != NULL && !video_captures[slot]->is_view;
  }
  pthread_mutex_unlock(&video_registry_lock);
  return count;
}

uint32_t bend_video_token_for_index(uint32_t index) {
  uint32_t token = 0;
  pthread_mutex_lock(&video_registry_lock);
  for (size_t slot = 0; slot < VIDEO_CAPTURE_SLOTS && token == 0; slot += 1u) {
    if (video_captures[slot] != NULL && !video_captures[slot]->is_view
        && video_captures[slot]->index == index) {
      token = video_captures[slot]->token;
    }
  }
  pthread_mutex_unlock(&video_registry_lock);
  return token;
}

size_t bend_video_indices(uint32_t *out, size_t max) {
  size_t count = 0;
  pthread_mutex_lock(&video_registry_lock);
  for (size_t slot = 0; slot < VIDEO_CAPTURE_SLOTS && count < max; slot += 1u) {
    if (video_captures[slot] != NULL && !video_captures[slot]->is_view) {
      out[count] = video_captures[slot]->index;
      count += 1u;
    }
  }
  pthread_mutex_unlock(&video_registry_lock);
  return count;
}

static CFDataRef video_jpeg_encode(CVPixelBufferRef pixels, double quality) {
  if (CVPixelBufferGetPixelFormatType(pixels) != kCVPixelFormatType_32BGRA
      || CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
    return NULL;
  }
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixels),
    CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), 8,
    CVPixelBufferGetBytesPerRow(pixels), space,
    (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
  CGImageRef image = context == NULL ? NULL : CGBitmapContextCreateImage(context);
  if (context != NULL) {
    CGContextRelease(context);
  }
  CGColorSpaceRelease(space);
  CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
  if (image == NULL) {
    return NULL;
  }
  CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
  CGImageDestinationRef destination =
    CGImageDestinationCreateWithData(data, CFSTR("public.jpeg"), 1, NULL);
  bool encoded = false;
  if (destination != NULL) {
    NSDictionary *options = @{(id)kCGImageDestinationLossyCompressionQuality: @(quality)};
    CGImageDestinationAddImage(destination, image, (CFDictionaryRef)options);
    encoded = CGImageDestinationFinalize(destination);
    CFRelease(destination);
  }
  CGImageRelease(image);
  if (!encoded) {
    CFRelease(data);
    return NULL;
  }
  return data;
}

// Waits for a frame newer than `after`, makes sure it has been JPEG-encoded
// (once, shared by every viewer), and answers its sequence number.
int bend_video_next_jpeg(uint32_t token, uint32_t after, uint32_t timeout_ms,
    uint32_t *sequence, char *message, size_t size) {
  BendCapture *capture = video_capture_get(token, true);
  if (capture == NULL) {
    video_message(message, size, "The camera is no longer open.");
    return EBADF;
  }
  struct timespec deadline;
  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_sec += timeout_ms / 1000u;
  deadline.tv_nsec += (long)(timeout_ms % 1000u) * 1000000l;
  if (deadline.tv_nsec >= 1000000000l) {
    deadline.tv_sec += 1;
    deadline.tv_nsec -= 1000000000l;
  }
  int code = 0;
  CVPixelBufferRef pixels = NULL;
  uint32_t wanted = 0;
  pthread_mutex_lock(&capture->lock);
  while (!capture->closed && capture->error_code == 0
      && (capture->latest == NULL || (int32_t)(capture->sequence - after) <= 0)) {
    if (pthread_cond_timedwait(&capture->ready, &capture->lock, &deadline) == ETIMEDOUT) {
      code = ETIMEDOUT;
      break;
    }
  }
  if (code == 0 && capture->closed) {
    code = EPIPE;
  } else if (code == 0 && capture->error_code != 0) {
    code = capture->error_code;
  } else if (code == 0) {
    pixels = capture->latest;
    CVPixelBufferRetain(pixels);
    wanted = capture->sequence;
  }
  pthread_mutex_unlock(&capture->lock);

  if (code == 0) {
    pthread_mutex_lock(&capture->encode_lock);
    if (capture->jpeg == NULL || (int32_t)(capture->jpeg_sequence - wanted) < 0) {
      CFDataRef jpeg = NULL;
      @autoreleasepool {
        jpeg = video_jpeg_encode(pixels, 0.7);
      }
      if (jpeg == NULL) {
        code = EIO;
      } else {
        if (capture->jpeg != NULL) {
          CFRelease(capture->jpeg);
        }
        capture->jpeg = jpeg;
        capture->jpeg_sequence = wanted;
        capture->encodes += 1u;
      }
    }
    *sequence = capture->jpeg_sequence;
    pthread_mutex_unlock(&capture->encode_lock);
    CVPixelBufferRelease(pixels);
  }
  video_capture_unref(capture);
  if (code == ETIMEDOUT) {
    video_message(message, size, "No camera frame arrived in time.");
  } else if (code == EPIPE) {
    video_message(message, size, "The camera was released.");
  } else if (code == EIO) {
    video_message(message, size, "The frame could not be encoded as JPEG.");
  } else if (code != 0) {
    video_message(message, size, "The camera stopped with an error.");
  }
  return code;
}

// Copies the newest encoded JPEG (malloc'ed; the caller frees it).
int bend_video_copy_jpeg(uint32_t token, uint8_t **bytes, size_t *length, uint32_t *sequence) {
  BendCapture *capture = video_capture_get(token, true);
  if (capture == NULL) {
    return EBADF;
  }
  int code = 0;
  pthread_mutex_lock(&capture->encode_lock);
  if (capture->jpeg == NULL) {
    code = EAGAIN;
  } else {
    *length = (size_t)CFDataGetLength(capture->jpeg);
    *bytes = malloc(*length);
    if (*bytes == NULL) {
      code = ENOMEM;
    } else {
      memcpy(*bytes, CFDataGetBytePtr(capture->jpeg), *length);
      *sequence = capture->jpeg_sequence;
    }
  }
  pthread_mutex_unlock(&capture->encode_lock);
  video_capture_unref(capture);
  return code;
}

uint32_t bend_video_encodes(uint32_t token) {
  BendCapture *capture = video_capture_get(token, true);
  if (capture == NULL) {
    return 0;
  }
  pthread_mutex_lock(&capture->encode_lock);
  uint32_t encodes = capture->encodes;
  pthread_mutex_unlock(&capture->encode_lock);
  video_capture_unref(capture);
  return encodes;
}

// ---------------------------------------------------------------------------
// Pixel access for Bend: lock a frame's pixels for reading. The caller copies
// rows out (into Bend arrays) and then unlocks with the returned handle.

void *bend_video_frame_lock(uint32_t token, const uint8_t **base, uint32_t *width,
    uint32_t *height, size_t *stride) {
  BendFrame *frame = video_frame_get(token, true);
  if (frame == NULL) {
    return NULL;
  }
  if (CVPixelBufferGetPixelFormatType(frame->pixels) != kCVPixelFormatType_32BGRA
      || CVPixelBufferLockBaseAddress(frame->pixels, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
    video_frame_unref(frame);
    return NULL;
  }
  *base = CVPixelBufferGetBaseAddress(frame->pixels);
  *width = frame->width;
  *height = frame->height;
  *stride = CVPixelBufferGetBytesPerRow(frame->pixels);
  return frame;
}

void bend_video_frame_unlock(void *handle) {
  BendFrame *frame = handle;
  CVPixelBufferUnlockBaseAddress(frame->pixels, kCVPixelBufferLock_ReadOnly);
  video_frame_unref(frame);
}

// ---------------------------------------------------------------------------
// Views (View.publish): named image streams. Each is a capture-registry entry
// with no camera behind it, so the viewer serves it exactly like a camera.
// Views live until the process exits and do not keep the viewer running.

static uint32_t video_view_find_locked(const char *name) {
  for (size_t slot = 0; slot < VIDEO_CAPTURE_SLOTS; slot += 1u) {
    BendCapture *c = video_captures[slot];
    if (c != NULL && c->is_view && strcmp(c->name, name) == 0) {
      return c->token;
    }
  }
  return 0;
}

uint32_t bend_view_token(const char *name) {
  pthread_mutex_lock(&video_registry_lock);
  uint32_t token = video_view_find_locked(name);
  pthread_mutex_unlock(&video_registry_lock);
  return token;
}

size_t bend_view_names(char *out, size_t size) {
  size_t used = 0;
  if (size == 0) {
    return 0;
  }
  out[0] = '\0';
  pthread_mutex_lock(&video_registry_lock);
  for (size_t slot = 0; slot < VIDEO_CAPTURE_SLOTS; slot += 1u) {
    BendCapture *c = video_captures[slot];
    if (c != NULL && c->is_view) {
      int n = snprintf(out + used, size - used, "%s%s", used == 0 ? "" : " ", c->name);
      if (n < 0 || (size_t)n >= size - used) {
        break;
      }
      used += (size_t)n;
    }
  }
  pthread_mutex_unlock(&video_registry_lock);
  return used;
}

// Publishes width x height BGRA pixels (row-major, no padding) as the newest
// frame of the view `name`, creating the view on first use.
int bend_view_publish(const char *name, uint32_t width, uint32_t height, const uint32_t *pixels) {
  if (width == 0 || height == 0 || strlen(name) == 0 || strlen(name) > 32) {
    return EINVAL;
  }
  CVPixelBufferRef buffer = NULL;
  NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
  if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        (CFDictionaryRef)attributes, &buffer) != kCVReturnSuccess) {
    return ENOMEM;
  }
  CVPixelBufferLockBaseAddress(buffer, 0);
  uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
  size_t stride = CVPixelBufferGetBytesPerRow(buffer);
  for (uint32_t y = 0; y < height; y += 1u) {
    memcpy(base + (size_t)y * stride, pixels + (size_t)y * width, (size_t)width * 4u);
  }
  CVPixelBufferUnlockBaseAddress(buffer, 0);

  BendCapture *view = NULL;
  pthread_mutex_lock(&video_registry_lock);
  uint32_t token = video_view_find_locked(name);
  pthread_mutex_unlock(&video_registry_lock);
  if (token == 0) {
    if (video_capture_alloc(UINT32_MAX, &view) != 0) {
      CVPixelBufferRelease(buffer);
      return ENOMEM;
    }
    view->is_view = true;
    snprintf(view->name, sizeof view->name, "%s", name);
    pthread_mutex_lock(&video_registry_lock);
    size_t slot = 0;
    while (slot < VIDEO_CAPTURE_SLOTS && video_captures[slot] != NULL) {
      slot += 1u;
    }
    if (slot == VIDEO_CAPTURE_SLOTS) {
      pthread_mutex_unlock(&video_registry_lock);
      video_capture_destroy(view);
      CVPixelBufferRelease(buffer);
      return ENOSPC;
    }
    view->token = video_make_token(&video_capture_generations[slot], slot);
    video_captures[slot] = view;
    token = view->token;
    pthread_mutex_unlock(&video_registry_lock);
  }
  view = video_capture_get(token, true);
  if (view == NULL) {
    CVPixelBufferRelease(buffer);
    return EBADF;
  }
  video_capture_push(view, buffer);
  video_capture_unref(view);
  return 0;
}

// ---------------------------------------------------------------------------
// Encoding in Bend: one viewer claims each new frame, encodes it in Bend and
// stores the bytes; every viewer sends from the cache.

static bool video_cached_locked(BendCapture *capture, uint32_t wanted, uint32_t *cached) {
  pthread_mutex_lock(&capture->encode_lock);
  bool have = capture->jpeg != NULL && (int32_t)(capture->jpeg_sequence - wanted) >= 0;
  *cached = capture->jpeg_sequence;
  pthread_mutex_unlock(&capture->encode_lock);
  return have;
}

// Waits for a frame newer than `after`. If its JPEG is already cached, or
// another viewer is encoding it and finishes in time, answers *frame = 0.
// Otherwise claims it: *frame is a frame token (pixels retained) for Bend to
// encode, and the caller must store the result or release the frame.
int bend_video_peek(uint32_t token, uint32_t after, uint32_t timeout_ms, uint32_t *sequence,
    uint32_t *frame, char *message, size_t size) {
  *frame = 0;
  BendCapture *capture = video_capture_get(token, true);
  if (capture == NULL) {
    video_message(message, size, "The camera is no longer open.");
    return EBADF;
  }
  struct timespec deadline;
  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_sec += timeout_ms / 1000u;
  deadline.tv_nsec += (long)(timeout_ms % 1000u) * 1000000l;
  if (deadline.tv_nsec >= 1000000000l) {
    deadline.tv_sec += 1;
    deadline.tv_nsec -= 1000000000l;
  }
  int code = 0;
  pthread_mutex_lock(&capture->lock);
  while (!capture->closed && capture->error_code == 0
      && (capture->latest == NULL || (int32_t)(capture->sequence - after) <= 0)) {
    if (pthread_cond_timedwait(&capture->ready, &capture->lock, &deadline) == ETIMEDOUT) {
      code = ETIMEDOUT;
      break;
    }
  }
  if (code == 0 && capture->closed) {
    code = EPIPE;
  } else if (code == 0 && capture->error_code != 0) {
    code = capture->error_code;
  }
  uint32_t wanted = capture->sequence;
  bool claim = false;
  while (code == 0) {
    uint32_t cached = 0;
    if (video_cached_locked(capture, wanted, &cached)) {
      *sequence = cached;
      break;
    }
    if (capture->encoding_sequence != wanted) {
      claim = true;
      break;
    }
    // Another viewer is encoding this frame: wait for its result, and take
    // the claim over if it does not arrive in time.
    if (pthread_cond_timedwait(&capture->ready, &capture->lock, &deadline) == ETIMEDOUT) {
      claim = true;
      break;
    }
    if (capture->closed) {
      code = EPIPE;
    }
  }
  if (claim) {
    capture->encoding_sequence = wanted;
    CVPixelBufferRef pixels = capture->latest;
    CVPixelBufferRetain(pixels);
    BendVideoResult info;
    memset(&info, 0, sizeof info);
    info.width = (uint32_t)CVPixelBufferGetWidth(pixels);
    info.height = (uint32_t)CVPixelBufferGetHeight(pixels);
    info.stride = (uint32_t)CVPixelBufferGetBytesPerRow(pixels);
    info.sequence = wanted;
    *frame = video_frame_create(pixels, &info);
    *sequence = wanted;
    if (*frame == 0) {
      code = ENOSPC;
    }
  }
  pthread_mutex_unlock(&capture->lock);
  video_capture_unref(capture);
  if (code == ETIMEDOUT) {
    video_message(message, size, "No camera frame arrived in time.");
  } else if (code == EPIPE) {
    video_message(message, size, "The camera was released.");
  } else if (code == ENOSPC) {
    video_message(message, size, "Too many frames are retained.");
  } else if (code != 0) {
    video_message(message, size, "The camera stopped with an error.");
  }
  return code;
}

// Stores a JPEG encoded in Bend as frame `sequence`'s, if it is newer than the
// cache, and wakes viewers waiting for it.
int bend_video_store_jpeg(uint32_t token, uint32_t sequence, const uint8_t *bytes, size_t length) {
  BendCapture *capture = video_capture_get(token, true);
  if (capture == NULL) {
    return EBADF;
  }
  CFDataRef data = CFDataCreate(kCFAllocatorDefault, bytes, (CFIndex)length);
  pthread_mutex_lock(&capture->encode_lock);
  if (capture->jpeg == NULL || (int32_t)(capture->jpeg_sequence - sequence) < 0) {
    if (capture->jpeg != NULL) {
      CFRelease(capture->jpeg);
    }
    capture->jpeg = data;
    capture->jpeg_sequence = sequence;
    capture->encodes += 1u;
    data = NULL;
  }
  pthread_mutex_unlock(&capture->encode_lock);
  if (data != NULL) {
    CFRelease(data);
  }
  pthread_mutex_lock(&capture->lock);
  pthread_cond_broadcast(&capture->ready);
  pthread_mutex_unlock(&capture->lock);
  video_capture_unref(capture);
  return 0;
}

int bend_video_frame_drop(uint32_t token) {
  char message[8];
  return bend_video_frame_release(token, message, sizeof message);
}
