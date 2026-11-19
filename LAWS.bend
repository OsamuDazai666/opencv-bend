import Base
import ./src/layout.bend as L
import ./examples/camera_args.bend as A
import ./src/viewer_policy.bend as P
import ./src/modes.bend as M
import ./src/image.bend as I
import ./src/jpeg.bend as J
import ./src/jpeg_tables.bend as JT

# Project laws. By Bend convention the human owns this file and the AI
# proves it in PROOF.bend. These were PROPOSED by Claude while finishing
# milestone 1 (camera capture): review, edit or delete them; the proofs
# must then follow.
#
# Only pure modules are imported here. Anything that imports
# src/videoio.bend depends on foreign effects, which can never pass the
# `bend PROOF.bend` gate.

# --- Frame layout (BGRA, 4 bytes per pixel, rows may be padded) ---

# Each extra pixel of width needs exactly 4 more bytes per row.
law stride_per_pixel:
  for w: Nat
  {L.Layout.min_stride(1n+w) == Nat.add(4n, L.Layout.min_stride(w)) : Nat}

# A tightly packed row is a valid stride.
law stride_tight:
  for w: Nat
  {L.Layout.stride_ok(w, L.Layout.min_stride(w)) == True{} : Bool}

# Any amount of row padding is still a valid stride.
law stride_padded:
  for w: Nat
  for pad: Nat
  {L.Layout.stride_ok(w, Nat.add(L.Layout.min_stride(w), pad)) == True{} : Bool}

# A row even one byte shorter than needed is rejected.
law stride_short:
  for have: Nat
  for missing: Nat
  {L.Layout.covers(Nat.add(have, 1n+missing), have) == False{} : Bool}

# --- Camera example arguments: camera [frame-count] [snapshot.ppm] ---

# No argv at all (not even the program name) is rejected.
law config_needs_program:
  {A.Camera.config(Nil{}) == None{} : Maybe<&2, A.CameraConfig>}

# With no arguments, read 300 frames and save no snapshot.
law config_default:
  for prog: String
  {A.Camera.config([prog]) == Some{A.CameraConfig{300n, None{}}} : Maybe<&2, A.CameraConfig>}

# A count and a path are both taken.
law config_count_and_snapshot:
  for prog: String
  for path: String
  {A.Camera.config([prog, "120", path]) == Some{A.CameraConfig{120n, Some{path}}} : Maybe<&2, A.CameraConfig>}

# A zero frame count is rejected, whatever follows.
law config_rejects_zero:
  for prog: String
  for rest: List<String>
  {A.Camera.config(Con{prog, Con{"0", rest}}) == None{} : Maybe<&2, A.CameraConfig>}

# The FPS report keeps leading zeros in its three decimals
# (regression: 30.006 FPS once printed as "30.6 FPS").
law fps_decimals_padded:
  {(A.Camera.pad3(6n), A.Camera.pad3(42n), A.Camera.pad3(120n)) ==
    ("006", "042", "120") : String & String & String}

# --- Error bookkeeping ---

# When a cleanup step also fails, the first error is the one reported.
law first_error_kept:
  for first: U32 & String
  for later: U32 & String
  {A.Camera.first_error(Some{first}, later) == Some{first} : Maybe<&1, U32 & String>}

# --- Browser viewer: privacy (milestone 2) ---
# P.Policy.check(sharing, peer, port, token, csrf, route, request) decides
# every request; P.Policy.keep_streaming decides, frame by frame, whether a
# running stream may continue.

# The viewer starts private: it listens on the loopback address only.
law viewer_private_by_default:
  {P.Policy.bind_host(P.Policy.default_sharing()) == "127.0.0.1" : String}

# While private, every request from another machine is refused.
law viewer_private_refuses_network:
  for port: U32
  for token: String
  for csrf: String
  for route: P.Route
  for req: P.Request
  {P.Policy.allowed(P.Policy.check(P.Private{}, P.Remote{}, port, token, csrf, route, req)) == False{} : Bool}

# The sharing switch never works from another machine, shared or not.
law viewer_switch_is_local_only:
  for sharing: P.Sharing
  for on: Bool
  for port: U32
  for token: String
  for csrf: String
  for req: P.Request
  {P.Policy.allowed(P.Policy.check(sharing, P.Remote{}, port, token, csrf, P.SetSharing{on}, req)) == False{} : Bool}

# While shared, a request from another machine without the right token is refused.
law viewer_token_required:
  for port: U32
  for token: String
  for csrf: String
  for route: P.Route
  for req: P.Request
  for wrong: {String.eq(P.Request.token(req), token) == False{} : Bool}
  {P.Policy.allowed(P.Policy.check(P.Shared{}, P.Remote{}, port, token, csrf, route, req)) == False{} : Bool}

# A local request naming any host other than this server is refused (DNS rebinding).
law viewer_foreign_host_refused:
  for sharing: P.Sharing
  for port: U32
  for token: String
  for csrf: String
  for route: P.Route
  for req: P.Request
  for foreign: {P.Policy.local_host_ok(port, P.Request.host(req)) == False{} : Bool}
  {P.Policy.allowed(P.Policy.check(sharing, P.Local{}, port, token, csrf, route, req)) == False{} : Bool}

# A local request the browser marks as coming from another website is refused.
law viewer_cross_site_refused:
  for sharing: P.Sharing
  for port: U32
  for token: String
  for csrf: String
  for route: P.Route
  for req: P.Request
  for host_ok: {P.Policy.local_host_ok(port, P.Request.host(req)) == True{} : Bool}
  for cross: {String.eq(P.Request.fetch_site(req), "cross-site") == True{} : Bool}
  {P.Policy.allowed(P.Policy.check(sharing, P.Local{}, port, token, csrf, route, req)) == False{} : Bool}

# Turning sharing off stops every stream watched from another machine.
law viewer_private_stops_network_streams:
  for now: U32
  for since: U32
  {P.Policy.keep_streaming(P.Remote{}, P.Private{}, now, since) == False{} : Bool}

# Re-sharing (a new epoch, with a new token) also stops older network streams.
law viewer_new_epoch_stops_network_streams:
  for now: U32
  for since: U32
  for changed: {U32.is_eq(now, since) == False{} : Bool}
  {P.Policy.keep_streaming(P.Remote{}, P.Shared{}, now, since) == False{} : Bool}

# View URLs: a published view's page and stream; names outside
# [A-Za-z0-9_-] (here an HTML tag) are not found.
law viewer_view_routes:
  {(P.Http.route_of("GET /view/gray HTTP/1.1\r\n\r\n"),
    P.Http.route_of("GET /view/edges_2.mjpg HTTP/1.1\r\n\r\n"),
    P.Http.route_of("GET /view/<b>x</b> HTTP/1.1\r\n\r\n"),
    P.Http.route_of("GET /view/ HTTP/1.1\r\n\r\n")) ==
   (P.ViewPage{"gray"}, P.ViewStream{"edges_2"}, P.NotFound{}, P.NotFound{}) :
   P.Route & P.Route & P.Route & P.Route}

# URL examples.
law viewer_routes:
  {(P.Http.route_of("GET /camera/0.mjpg?token=t HTTP/1.1\r\nHost: h\r\n\r\n"),
    P.Http.route_of("GET /camera/3 HTTP/1.1\r\n\r\n"),
    P.Http.route_of("POST /sharing?share=on HTTP/1.1\r\n\r\n"),
    P.Http.route_of("GET /camera/../etc HTTP/1.1\r\n\r\n")) ==
   (P.Stream{0}, P.Page{3}, P.SetSharing{True{}}, P.NotFound{}) :
   P.Route & P.Route & P.Route & P.Route}

# --- Camera mode choice ---
# Native code lists a camera's modes; M.Modes.pick chooses one.

# With no modes listed, nothing is picked, whatever was asked for.
law modes_none_from_nothing:
  for want: M.Want
  {M.Modes.pick(want, Nil{}) == None{} : Maybe<&2, M.Mode>}

# A camera with a single mode gets that mode.
law modes_single_mode:
  for mode: M.Mode
  {M.Modes.pick(M.Largest{}, [mode]) == Some{mode} : Maybe<&2, M.Mode>}

# This MacBook Air's FaceTime HD camera: the largest mode wins, in either order;
# an exact size is honoured; a size the camera lacks is refused.
law modes_facetime_hd:
  {(M.Modes.pick(M.Largest{}, [M.Mode{1280, 720, 30}, M.Mode{640, 480, 30}]),
    M.Modes.pick(M.Largest{}, [M.Mode{640, 480, 30}, M.Mode{1280, 720, 30}]),
    M.Modes.pick(M.Size{640, 480}, [M.Mode{1280, 720, 30}, M.Mode{640, 480, 30}]),
    M.Modes.pick(M.Size{1920, 1080}, [M.Mode{1280, 720, 30}, M.Mode{640, 480, 30}])) ==
   (Some{M.Mode{1280, 720, 30}}, Some{M.Mode{1280, 720, 30}}, Some{M.Mode{640, 480, 30}}, None{}) :
   Maybe<&2, M.Mode> & Maybe<&2, M.Mode> & Maybe<&2, M.Mode> & Maybe<&2, M.Mode>}

# A 4K webcam: the most pixels win over a higher frame rate at a smaller size,
# and among equal sizes the higher frame rate wins.
law modes_4k_webcam:
  {M.Modes.pick(M.Largest{}, [M.Mode{1920, 1080, 30}, M.Mode{3840, 2160, 15},
    M.Mode{1280, 720, 60}, M.Mode{3840, 2160, 30}]) == Some{M.Mode{3840, 2160, 30}} :
   Maybe<&2, M.Mode>}

# Native code lists modes as flat numbers; a trailing incomplete group is ignored.
law modes_from_numbers:
  {M.Modes.from_numbers([1280, 720, 30, 640, 480, 30, 99]) ==
    [M.Mode{1280, 720, 30}, M.Mode{640, 480, 30}] : List<&2, M.Mode>}

# --- Images (Mat) ---
# A Mat is a full tree of 8 row bands, each an Array<U32> of BGRA pixels.

# Packing and unpacking a BGRA pixel round-trips its channels.
law image_pixel_channels:
  {(I.Pixel.b(I.Pixel.pack(1, 2, 3, 4)), I.Pixel.g(I.Pixel.pack(1, 2, 3, 4)),
    I.Pixel.r(I.Pixel.pack(1, 2, 3, 4)), I.Pixel.a(I.Pixel.pack(1, 2, 3, 4))) ==
   (1, 2, 3, 4) : U32 & U32 & U32 & U32}

# Black has luma 0, white 255, and a grey pixel keeps its level.
law image_luma_range:
  {(I.Pixel.luma(I.Pixel.pack(0, 0, 0, 255)), I.Pixel.luma(I.Pixel.pack(255, 255, 255, 255)),
    I.Pixel.luma(I.Pixel.gray(I.Pixel.pack(10, 200, 90, 255))), I.Pixel.luma(I.Pixel.pack(10, 200, 90, 255))) ==
   (0, 255, 145, 145) : U32 & U32 & U32 & U32}

# Bands hold ceil(height / 8) rows rounded up to a multiple of 16 (whole JPEG
# macroblock rows); the last band may hold fewer.
law image_rows_per_band:
  {(I.Mat.rows_per_band(720), I.Mat.rows_per_band(721), I.Mat.rows_per_band(480), I.Mat.rows_per_band(2)) ==
   (96, 96, 64, 16) : U32 & U32 & U32 & U32}

# Building the band tree keeps the bands in order (empty padding adds nothing).
law image_bands_keep_order:
  {I.Bands.contents(U32, I.Bands.build(U32, 3n, [(1, 10), (1, 20), (1, 30)])) == [10, 20, 30] : List<U32>}

# Every pixel of a 2x2 image (two one-row bands) reads back where it was put.
law image_get_2x2:
  {(I.Mat.pixel_at(I.Mat.from_list(2, 2, [1, 2, 3, 4]), 0, 0),
    I.Mat.pixel_at(I.Mat.from_list(2, 2, [1, 2, 3, 4]), 1, 0),
    I.Mat.pixel_at(I.Mat.from_list(2, 2, [1, 2, 3, 4]), 0, 1),
    I.Mat.pixel_at(I.Mat.from_list(2, 2, [1, 2, 3, 4]), 1, 1)) ==
   (1, 2, 3, 4) : U32 & U32 & U32 & U32}

# A 1x9 column (one band of 9 rows, the rest empty): rows read back.
law image_get_column:
  {(I.Mat.pixel_at(I.Mat.from_list(1, 9, [10, 11, 12, 13, 14, 15, 16, 17, 18]), 0, 0),
    I.Mat.pixel_at(I.Mat.from_list(1, 9, [10, 11, 12, 13, 14, 15, 16, 17, 18]), 0, 3),
    I.Mat.pixel_at(I.Mat.from_list(1, 9, [10, 11, 12, 13, 14, 15, 16, 17, 18]), 0, 7),
    I.Mat.pixel_at(I.Mat.from_list(1, 9, [10, 11, 12, 13, 14, 15, 16, 17, 18]), 0, 8)) ==
   (10, 13, 17, 18) : U32 & U32 & U32 & U32}

# A Mat from only two bands, as the native copy-in makes for a 20-row frame
# (16 + 4 rows), still reads back correctly on both sides of the band edge:
# the band tree is padded to its full shape.
law image_get_two_bands:
  {(I.Mat.pixel_at(I.Mat.from_bands(1, 20, I.Mat.pieces(2n, 1, 16, 20,
      [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19])), 0, 15),
    I.Mat.pixel_at(I.Mat.from_bands(1, 20, I.Mat.pieces(2n, 1, 16, 20,
      [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19])), 0, 16),
    I.Mat.pixel_at(I.Mat.from_bands(1, 20, I.Mat.pieces(2n, 1, 16, 20,
      [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19])), 0, 19)) ==
   (15, 16, 19) : U32 & U32 & U32}

# Brightness of half white, half black; the grey copy keeps it.
law image_brightness:
  {(I.Mat.brightness(I.Mat.from_list(2, 2, [4294967295, 4294967295, 4278190080, 4278190080])),
    I.Mat.brightness(I.Mat.gray(I.Mat.from_list(2, 2, [4294967295, 4294967295, 4278190080, 4278190080])))) ==
   (127, 127) : U32 & U32}

# --- JPEG encoder (pure Bend) ---

# The zigzag order is a permutation of the 64 block positions.
law jpeg_zigzag_permutation:
  {J.Jpeg.zigzag_ok() == True{} : Bool}

# Standard Huffman codes, packed as (code << 5) | length: luma DC 0 is 00,
# luma EOB is 1010, luma ZRL is 11111111001, chroma DC 0 and EOB are 00.
law jpeg_huffman_codes:
  {(JT.Jt.dc_luma(0n), JT.Jt.ac_luma(0n), JT.Jt.ac_luma(240n), JT.Jt.dc_chroma(0n), JT.Jt.ac_chroma(0n)) ==
   (2, 324, 65323, 2, 2) : U32 & U32 & U32 & U32 & U32}

# Magnitude categories, and value bits for magnitude m in `size` bits: m
# itself, or for a negative value its ones' complement (-1 -> 0, -2 -> 01,
# 5 -> 101, -5 -> 010). The sign comes in as a Bool here because the checker
# leaves F32 comparisons unevaluated.
law jpeg_coefficient_bits:
  {(J.Enc.size(0), J.Enc.size(1), J.Enc.size(255), J.Enc.size(1023),
    J.Enc.bits_if(True{}, 1, 1), J.Enc.bits_if(True{}, 2, 2), J.Enc.bits_if(False{}, 5, 3),
    J.Enc.bits_if(True{}, 5, 3)) ==
   (0, 1, 8, 10, 0, 1, 5, 2) : U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32}

# A 0xFF data byte is followed by 0x00 (bytes FF 00: two bytes, word 0x00FF).
law jpeg_byte_stuffing:
  {(J.Bits.peek(J.Bits.byte(J.Bits.new(8), 255)), J.Bits.peek(J.Bits.byte(J.Bits.new(8), 254))) ==
   ((2, 255), (1, 254)) : (U32 & U32) & (U32 & U32)}

# Each band is one restart interval: 80 x 6 macroblocks at 1280x720.
law jpeg_restart_interval:
  {(J.Jpeg.restart_interval(1280, 720), J.Jpeg.restart_interval(640, 480), J.Jpeg.restart_interval(16, 16)) ==
   (480, 160, 1) : U32 & U32 & U32}
