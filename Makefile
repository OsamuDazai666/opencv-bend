# opencv-bend build. Bend emits one C file per program; the macOS camera
# backend is Objective-C (manual retain/release) compiled and linked beside it.

BEND ?= $(shell command -v bend 2>/dev/null || echo $(HOME)/.bend/bin/bend)
BEND_VERSION := 2.0.40
CC ?= clang
BUILD := build

# Bend's own native flags (see `bend x.bend -o x`): -std=c11 -O3 -lpthread -lm.
BEND_CFLAGS := -std=c11 -O3 -Isrc -Wno-everything
OBJC_FLAGS := -fno-objc-arc -O2 -Wall -Wextra -Wpedantic -Werror -Wno-gnu-zero-variadic-macro-arguments
FRAMEWORKS := -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework Foundation \
  -framework CoreGraphics -framework ImageIO
LDFLAGS := $(FRAMEWORKS) -lpthread -lm -sectcreate __TEXT __info_plist Info.plist

NATIVE_SRC := src/native/videoio.c src/native/videoio_darwin.h src/native/videoio.js \
  src/native/viewer.c src/native/viewer.js src/native/bytes.c src/native/bytes.js
LIB_SRC := src/videoio.bend src/viewer.bend src/viewer_policy.bend src/layout.bend src/modes.bend \
  src/image.bend src/jpeg.bend src/jpeg_tables.bend src/bytes.bend $(NATIVE_SRC)

.PHONY: all camera stream modes process jpeg spike proof check clean bend-version

all: camera stream modes process jpeg

camera: $(BUILD)/camera

stream: $(BUILD)/stream

modes: $(BUILD)/modes

process: $(BUILD)/process

jpeg: $(BUILD)/jpeg

bend-version:
	@got="$$($(BEND) version 2>&1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"; \
	if [ "$$got" != "$(BEND_VERSION)" ]; then \
	  echo "error: native effects are pinned to Bend $(BEND_VERSION), found '$$got'." >&2; \
	  echo "Rebuild and re-verify src/native/ before changing BEND_VERSION." >&2; exit 1; fi

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/camera.c: examples/camera.bend examples/camera_args.bend $(LIB_SRC) | $(BUILD) bend-version
	$(BEND) examples/camera.bend -o $@

$(BUILD)/camera.o: $(BUILD)/camera.c src/native/videoio_darwin.h
	$(CC) $(BEND_CFLAGS) -c $< -o $@

$(BUILD)/videoio_darwin.o: src/native/videoio_darwin.m src/native/videoio_darwin.h | $(BUILD)
	$(CC) $(OBJC_FLAGS) -c $< -o $@

$(BUILD)/camera: $(BUILD)/camera.o $(BUILD)/videoio_darwin.o Info.plist
	$(CC) $(BUILD)/camera.o $(BUILD)/videoio_darwin.o $(LDFLAGS) -o $@

$(BUILD)/jpeg.c: examples/jpeg.bend $(LIB_SRC) | $(BUILD) bend-version
	$(BEND) examples/jpeg.bend -o $@

$(BUILD)/jpeg.o: $(BUILD)/jpeg.c src/native/videoio_darwin.h
	$(CC) $(BEND_CFLAGS) -c $< -o $@

$(BUILD)/jpeg: $(BUILD)/jpeg.o $(BUILD)/videoio_darwin.o Info.plist
	$(CC) $(BUILD)/jpeg.o $(BUILD)/videoio_darwin.o $(LDFLAGS) -o $@

src/jpeg_tables.bend: tools/gen_jpeg_tables.py
	python3 tools/gen_jpeg_tables.py > $@

$(BUILD)/process.c: examples/process.bend $(LIB_SRC) | $(BUILD) bend-version
	$(BEND) examples/process.bend -o $@

$(BUILD)/process.o: $(BUILD)/process.c src/native/videoio_darwin.h
	$(CC) $(BEND_CFLAGS) -c $< -o $@

$(BUILD)/process: $(BUILD)/process.o $(BUILD)/videoio_darwin.o Info.plist
	$(CC) $(BUILD)/process.o $(BUILD)/videoio_darwin.o $(LDFLAGS) -o $@

$(BUILD)/modes.c: examples/modes.bend $(LIB_SRC) | $(BUILD) bend-version
	$(BEND) examples/modes.bend -o $@

$(BUILD)/modes.o: $(BUILD)/modes.c src/native/videoio_darwin.h
	$(CC) $(BEND_CFLAGS) -c $< -o $@

$(BUILD)/modes: $(BUILD)/modes.o $(BUILD)/videoio_darwin.o Info.plist
	$(CC) $(BUILD)/modes.o $(BUILD)/videoio_darwin.o $(LDFLAGS) -o $@

$(BUILD)/stream.c: examples/stream.bend $(LIB_SRC) | $(BUILD) bend-version
	$(BEND) examples/stream.bend -o $@

$(BUILD)/stream.o: $(BUILD)/stream.c src/native/videoio_darwin.h
	$(CC) $(BEND_CFLAGS) -c $< -o $@

$(BUILD)/stream: $(BUILD)/stream.o $(BUILD)/videoio_darwin.o Info.plist
	$(CC) $(BUILD)/stream.o $(BUILD)/videoio_darwin.o $(LDFLAGS) -o $@

# Pixel-access spike: no camera needed.
spike: $(BUILD)/pixels

$(BUILD)/pixels: spikes/pixels/pixels.bend spikes/pixels/pixels.c spikes/pixels/pixels.js | $(BUILD) bend-version
	$(BEND) spikes/pixels/pixels.bend -o $(BUILD)/pixels.c
	$(CC) $(BEND_CFLAGS) $(BUILD)/pixels.c -lpthread -lm -o $@

proof:
	$(BEND) PROOF.bend

check: proof
	$(BEND) examples/camera.bend --check-only || true

clean:
	rm -rf $(BUILD)
