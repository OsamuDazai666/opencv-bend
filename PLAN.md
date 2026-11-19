# opencv-bend plan

An OpenCV-equivalent library written in Bend, built one milestone at a time,
with performance treated as a design constraint. This file carries forward
Kimi's original milestone-1 plan (`crystal-raven-maria-hill.md`, in Kimi's
session folder) and the changes made since.

## Where we deliberately differ from OpenCV

1. **No GUI windows.** There is no `imshow`, `namedWindow`, `waitKey` or
   highgui module. Images and video are viewed in a web browser instead.
2. **Opening a camera serves its stream automatically.** When a camera is
   opened, the library starts a small built-in web server (or reuses the
   running one) and prints a URL such as `http://127.0.0.1:8765/`. Open it
   in a browser to watch the live feed.
3. **Private by default (the "firewall").** The server is reachable only
   from this computer unless sharing is switched on. Sharing on the local
   network is a toggle, and it is **off by default**.
4. **Bend first.** All logic and computation is written in Bend. C and
   Objective-C remain only where Bend cannot reach the operating system
   itself (the camera framework, socket and network calls Base lacks), and
   that code only answers questions or moves bytes: it never makes a
   decision. Every "which", "whether" and "how" lives in Bend, where laws
   can cover it.

   Example (camera modes): C lists the modes as plain numbers and applies
   the one it is given; `src/modes.bend` builds the modes and picks one.

   Moved into Bend so far: camera-mode choice, all image processing, and
   JPEG encoding (milestone 4; ImageIO remains only as a fallback).
   Still to move: the test pattern and the snapshot writer (milestone 5).
   Native code that stays: AVFoundation capture, the socket write of frame
   bytes, peer/LAN/token helpers, frame and handle bookkeeping.

## Milestone 1: camera capture (macOS, AVFoundation)

Goal: `VideoCapture.open / read / is_opened / stats / release` and
`Frame.release`, capturing BGRA frames zero-copy into retained
`CVPixelBuffer`s, with latest-frame-wins delivery.

Done:
- Bend API (`src/videoio.bend`), C bridge, Objective-C backend, JS stub.
- `make` builds `build/camera`: Bend emits C; the Objective-C file is
  compiled separately with manual memory management; `Info.plist` is
  embedded so macOS can ask for camera permission; Bend is pinned to 2.0.40.
- Stats per window: captured, delivered, superseded, dropped by driver,
  average and max read latency.
- The snapshot comes from the last of the 30 warm-up frames.
- Pure logic lives in `src/layout.bend` and `examples/camera_args.bend`.
  `LAWS.bend` holds 9 proposed laws and `bend PROOF.bend` passes.
- Pixel-access test (`make spike`): copying a frame into `Array<U32>` costs
  about 0.05 ms; a Bend luma sum takes 4.5 ms serial and 1.8 ms with
  parallel calls, against 0.073 ms in plain C.

- First real-camera run (2026-11-19, from Terminal.app; the Claude app has
  no camera access): 1280x720 BGRA, stride 5120. 300 frames in 9998 ms
  (30.006 FPS), every frame delivered, none dropped by the driver.
  Callback-to-read latency averaged 21-27 us, max 631 us. Three back-to-back
  100-frame runs and a 1-frame run all opened and released cleanly.
- Fixed after that run: FPS decimals lost their leading zeros (law
  `fps_decimals_padded`), and "superseded" counted frames that had already
  been read.

Remaining:
- Rerun `./build/camera 300` to confirm "superseded" is now about 0 when the
  reader keeps up.
- Resolution (done 2026-11-19): the ignored 640x480 request is gone.
  `VideoCapture.open` lists the camera's modes and opens the largest (most
  pixels, then highest frame rate); `VideoCapture.open_with(index,
  M.Size{w, h})` asks for an exact size and fails with the list of offered
  sizes if the camera lacks it.
  - The choice is pure Bend (`src/modes.bend`) with 5 laws: empty list,
    single mode, this Mac's FaceTime HD list, a 4K webcam list, and the
    numbers-to-modes conversion.
  - Not proven yet: "Largest always picks a mode no other mode beats", for
    every list. That needs ordering lemmas over U32, which Base lacks.
  - The FaceTime HD camera on this MacBook Air (M1) offers 1280x720@30 and
    640x480@30, so the largest is what it already used.
  - Applying a non-default mode on real hardware still needs one check:
    `./build/stream --size=640x480` should show a 4:3 picture.
  - `make modes` lists a camera's modes without camera permission.
  At 1280x720 a frame fills 2^20 `Array<U32>` slots (12% padding, not 41%).
- The latency stat measures the hand-off from capture callback to `read`,
  not glass-to-glass; the viewer milestone measures the latter.
- Error paths: denied permission, invalid index, timeout, stale handles,
  release during a pending read.
- Run a sanitizer build, and repeat open/read/release cycles to confirm
  memory stays flat.
- Run `bend PROOF.bend --verdict` once Lean v4.34.0 is installed.

Repository: git, first commit 2026-11-19; hosted privately on GitHub at
OsamuDazai666/opencv-bend.

## Milestone 2: browser viewer (replaces highgui)

### What the user sees

- `VideoCapture.open(index)` registers the stream `/camera/<index>` on the
  process's viewer server. The first open starts the server and prints its
  URL. The last `release` stops it.
- `http://127.0.0.1:<port>/` lists the live streams. Each stream page shows
  the video, FPS, latency, the number of viewers, and whether sharing is on
  or off.
- The server encodes only while someone is watching. With no viewers it does
  no encoding, so it costs nothing in headless runs and benchmarks.
- Port: 8765 by default, overridable with `OPENCV_BEND_PORT` or the API. If
  the port is taken, the next free one is used and printed.

### Private by default, with a sharing toggle

The "firewall" is enforced by **which network address the server listens
on**. The macOS firewall is not used:

| | Firewall ON (default) | Firewall OFF (sharing) |
|---|---|---|
| Listens on | `127.0.0.1` only | `0.0.0.0` (all interfaces) |
| Who can connect | Only programs on this computer; other machines cannot reach the socket at all | Any device on the local network |
| Access token | Not needed | Always required (`?token=…`, printed in the console); cannot be switched off |
| Console output | Local URL | Local URL, LAN URL(s) with token, and a warning that the stream is unencrypted |

Ways to toggle:
- **In code:** `Viewer.share_on_lan(True{})` or `Viewer.share_on_lan(False{})`.
- **When launching:** `--share-lan` or `OPENCV_BEND_SHARE=lan`.
- **In the browser:** a switch on the page. It is honoured **only from a
  browser on this computer**, sent as a POST with a per-session token, so a
  LAN viewer can never change the setting.

Turning sharing **off** re-binds the server to `127.0.0.1` and immediately
disconnects every viewer that isn't on this computer.

Hardening that applies even in private mode:
- Requests must name this server in their `Host` header (`127.0.0.1:<port>`
  or `localhost:<port>`). This blocks DNS-rebinding attacks, where a
  malicious website open in your browser tries to read the localhost stream.
- No CORS headers. Cross-origin POSTs are rejected by checking `Origin`.
- The sharing token is 128 random bits from `SecRandomCopyBytes`, regenerated
  each time sharing is switched on.

Not covered:
- The OS firewall's settings are left alone: changing them needs admin
  rights and affects the whole system. Listening on loopback already keeps
  other machines out.
- When sharing is on, macOS may itself ask to "accept incoming connections"
  for the binary.
- No TLS in this milestone: a shared stream can be read by anyone on the
  same network who can see the traffic. The console warning says so.

### Architecture

- **HTTP server in Bend.** Built on Base `TCP.listen`, `TCP.try_accept`,
  `TCP.recv` and `TCP.send`, with one `IO.fork` per viewer. It handles
  routing, header parsing, the Host, Origin and token checks, and the
  sharing state. The decisions (parse request, choose route, allow or deny)
  are pure functions in their own module, so laws can cover them.
- **Bulk bytes in native code.** `TCP.send_bytes` takes one list cell per
  byte, which is too slow for video. `Viewer.send_jpeg(socket, frame, quality)`
  JPEG-encodes the retained `CVPixelBuffer` with ImageIO / VideoToolbox
  (hardware) and writes it straight to the socket. Bend allows custom
  effects on Base handle types such as `Socket`.
- **Small native helpers:**
  - `Net.peer_is_loopback(socket)` uses `getpeername`; it is used to drop
    LAN viewers when sharing turns off.
  - `Net.lan_addresses()` uses `getifaddrs`, for the printed LAN URLs.
  - `Rand.token()` generates the sharing token.
- **Format.** MJPEG over `multipart/x-mixed-replace`: works in every browser
  with a plain `<img>` and no JavaScript. H.264 over WebSocket / WebCodecs
  can come later if LAN bandwidth matters.
- **Frame flow.** The capture callback fills the existing latest-frame slot.
  Each frame is encoded at most once and the result is shared by all
  viewers. Each viewer takes the newest frame (latest wins), so a slow
  browser skips frames and never slows capture or the program's own `read`.
- Bend's `TCP.listen` takes IPv4 literals, so the printed URL uses
  `127.0.0.1` rather than `localhost`, which can resolve to `::1` first.

### Laws (in LAWS.bend, proven in PROOF.bend)

Nine viewer laws, over `src/viewer_policy.bend`:
- `viewer_private_by_default`: the default binds `127.0.0.1`.
- `viewer_private_refuses_network`: while private, every remote request is refused.
- `viewer_switch_is_local_only`: the sharing switch never works from a remote peer.
- `viewer_token_required`: while shared, a remote request with the wrong token is refused.
- `viewer_foreign_host_refused`: a local request with a foreign `Host` is refused.
- `viewer_cross_site_refused`: a local request marked `Sec-Fetch-Site: cross-site` is refused.
- `viewer_private_stops_network_streams`: switching sharing off stops remote streams.
- `viewer_new_epoch_stops_network_streams`: re-sharing (new token) stops older remote streams.
- `viewer_routes`: URL parsing examples, including `/camera/../etc` -> not found.

Planting a bug in the policy (allowing remote requests while private,
skipping the Host check, or keeping remote streams after switch-off) makes
the matching law fail, so the gate does real work.

### Status (2026-11-19): built and verified on the test pattern

Built:
- `src/viewer_policy.bend` (pure: parsing, routes, access decision),
  `src/viewer.bend` (server), `src/native/viewer.c` (JPEG part writer,
  peer check, LAN addresses, tokens, shared state).
- Additions to `src/native/videoio_darwin.m`:
  - ImageIO JPEG encoding, cached per frame;
  - a non-consuming frame peek;
  - camera index tracking;
  - `OPENCV_BEND_TEST_PATTERN=1`, a synthetic 1280x720 30 FPS source for
    testing without a camera.
- `VideoCapture.open` starts the viewer; `examples/stream.bend` (`make stream`).
- Limit: 16 concurrent streams (each briefly uses one of Bend's 64 IO
  helper threads); further viewers get 503.

Verified (`OPENCV_BEND_TEST_PATTERN=1`, curl and the built-in browser):
- Listens on `127.0.0.1:8765` by default; `*:8765` only while shared.
- Local page 200. Foreign Host, cross-site fetch, switch without the CSRF
  secret, switch with the wrong Origin, and switch via GET: all 403.
- Unknown path or camera: 404.
- MJPEG: 61 frames in 2 s, all valid 1280x720 JPEGs of about 51 KB each.
- Shared, as a LAN client: no token 403, wrong token 403, right token 200.
  The switch from the LAN with a valid token: 403. A LAN page shows no switch.
- Switch-off cut an active LAN stream 0.34 s later. The local stream kept
  running. The LAN address then refused connections.
- Re-sharing issues a new token; the old one gets 403.
- With no viewer, 0 JPEGs are encoded. One viewer for 2.5 s: 75 encodes.
- Reads are unaffected by two viewers: 30.006 FPS, 0 dropped, 0 superseded,
  average latency 26-27 us.
- Port fallback (8765, then 8766), `--share-lan`, `OPENCV_BEND_SHARE=lan`
  and `OPENCV_BEND_PORT` all work. Programs exit cleanly; the server stops
  within 250 ms of the last `release`.

Fixed during verification:
- `Referrer-Policy: no-referrer` made browsers send `Origin: null` on the
  switch's form post, so the real button got 403. It is now `same-origin`.
- Safari showed a black camera page until reloaded twice (reported
  2026-11-19). Cause: the server closed a connection that sent no request
  within 5 s, but Safari opens spare connections early and later sends the
  stream request down one. A request on a connection idle for 6 s got
  "connection reset". Fix: wait up to 120 s for the first request, in 1 s
  slices that stop once no camera is open, so programs still exit promptly
  (3.9 s for a 3 s run with an idle connection, against 20.9 s for a single
  long wait). Requests after 6 s and 30 s of idle now stream. Confirmation
  in Safari is pending.
- Requests are now read until their headers are complete (the blank line),
  up to 16 KB (431 beyond). Before, only the first network read was parsed,
  so a request arriving in pieces could lose its Host header and get 403.
  Tested with a request sent in three pieces. Still a candidate for the
  Safari black page, pending the user's log.
- The user's Safari log (2026-11-19) showed the stream request arriving
  and `stream started` while the page stayed black, then five reloads that
  never requested the stream again: Safari reused the still-running download
  of the same URL. Fix: each camera/view page gives its stream URL a unique
  `?v=<time>`, so a reload always opens a new stream.
  Resolved: with this build (idle connections kept, full-header reads,
  unique stream URLs) the user confirmed Safari shows the camera on the first
  click (2026-11-19). Which of the three changes mattered most is not
  known; no log of the failing first draw was captured after the fixes.
- `OPENCV_BEND_VIEWER_LOG=1` prints each request with its result, and why
  each stream ended, to stderr.
  It also logs each stream's first frame and every 150th.

Findings and remaining:
- "Shared on the local network" binds `0.0.0.0`, which includes VPN
  interfaces (this Mac also listed a `100.x` Tailscale-style address).
  Devices on a VPN with this Mac can reach it, still behind the token.
  Option: bind only to the chosen LAN interface's address.
- Not yet run with a real camera (needs Terminal.app):
  `./build/stream` and open the URL.
- Not yet measured: glass-to-glass latency, CPU per viewer, Safari, and a
  deliberately throttled viewer.
- Tokens are compared with ordinary string equality (not constant-time).
- The token travels in the URL, so it lands in browser history on the
  viewing device.

## Milestone 3: image type and pixel access in Bend

### Status (2026-11-19): built and verified on the test pattern

Design, chosen by measurement (1280x720, luma sum per frame):

| Approach | 1 thread | 4 threads |
|---|---|---|
| Split the array by `match` down to pixels (the spike) | 12 ms | 4.7 ms |
| One indexed loop (`Array.get`) | 0.71 ms | 0.48 ms |
| 8 row bands, indexed loop per band, bands in parallel | 0.43 ms | 0.22 ms |

Splitting an `Array` by `match` copies both halves; separate bands split
for free. So a `Mat` is a full tree of 8 row bands, each its own
`Array<U32>` (one BGRA pixel per U32), and work runs on the bands in parallel.
Bend picks the band size; native code only copies rows into the arrays.

Built:
- `src/image.bend` (pure):
  - pixels: `Pixel.b/g/r/a/pack/luma/gray`;
  - the band tree (`Bands`);
  - `Mat` with `from_list`, `from_bands`, `size`, `get`/`pixel_at`, `map`
    (in place), `sum`, `gray`, `mean_luma`/`brightness`.
- `Frame.to_mat` (native copy-in: about 0.1-0.2 ms per frame).
- `View.publish(name, mat)`, the replacement for `imshow`: the image becomes
  the live view `/view/<name>` in the viewer, under the same privacy rules
  as cameras. View names are 1-32 letters, digits, `-` or `_` (checked in
  pure Bend; they appear in pages).
- `examples/process.bend` (`make process`): live per-frame processing that
  publishes a grey copy as the view `gray`; `process bench` times it.

Verified:
- Mean luma and the centre pixel match an independent Python computation of
  the test pattern formula exactly ([124, 125, 126, 128]; B128 G120 R125 ...).
  The grey copy keeps the mean.
- Copy-in + mean + grey copy + mean: 0.95-0.98 ms per frame with 4 threads,
  2.0 ms with 1. The same pipeline in plain C at -O3, 1 thread: 0.88 ms.
- The `gray` view streams at 30 FPS (1280x720, visibly grey).
- Unknown or invalid view names get 404 (including an HTML tag).
- With sharing on, a LAN request for a view without the token gets 403.
- Bug found while writing laws: images under 5 rows got fewer bands, so
  `Mat.get` walked the wrong half. The tree is now always padded to its full
  shape; law `image_get_two_bands` fails without the fix.

Laws (9 new, 33 in all): pixel channels, luma range, rows per band, band
order, `get` on 2x2, 1x9 and two-band images, brightness and grey on a small
image, and view URLs. Image laws are concrete examples: general laws over
U32 arithmetic need ordering lemmas Base lacks.

Remaining:
- Run `./build/process 300` with the real camera.
- Setting pixels (`Mat.set`) and drawing; more operations (blur, threshold,
  resize) as `imgproc` begins.
- Views keep the viewer running only while a camera is open; a program that
  only publishes images (no camera) has no viewer yet.
- The two native copies (copy-in, and publish's copy-out) are about 0.1 ms
  each; fine for now.

## Milestone 4: JPEG encoder in Bend

### Status (2026-11-19): built, verified, and now used by the viewer

`src/jpeg.bend` is a baseline JPEG encoder in pure Bend:
- YCbCr 4:2:0, the float AAN DCT (as in libjpeg), quantisation at quality
  75, zigzag order, the standard Huffman tables, byte stuffing.
- Each band is an independent restart interval, so the 8 bands encode in
  parallel and are joined with RSTn markers. To allow this, bands are now a
  multiple of 16 rows (96 at 720p).
- Tables are pure functions generated from T.81 Annex K by
  `tools/gen_jpeg_tables.py` (`src/jpeg_tables.bend`); a lookup is a `match`
  on a Nat literal, about 2 ns.
- Output is byte segments; native code only writes them (`src/bytes.bend`
  for files; the viewer's JPEG cache).

Measured (1280x720, test pattern, 30 encodes):

| | Bend 1 thread | Bend 4 threads | ImageIO | Bend size | ImageIO size |
|---|---|---|---|---|---|
| Camera-like (smooth) | 11.4 ms | 4.6 ms | 2.3 ms | 30.5 KB | 39.7 KB |
| Worst case (per-pixel noise) | 29.9 ms | 12.6 ms | 8.4 ms | 506 KB | 718 KB |

Verified:
- macOS's decoder (`sips`) decodes the output. PSNR against the lossless
  source is 46.3 / 50.1 / 43.1 dB (R/G/B); ImageIO's "75" gives 49.7 / 51.8 /
  46.1 dB at 60% larger files.
- On worst-case noise, the error is even across all 8 restart intervals
  (G 20.2-20.4 dB), so there is no bitstream corruption.
- The viewer now encodes with Bend. Two viewers each got 91 frames in 3 s,
  all Bend-encoded, with 93 encodes in total (shared, one per frame).
  Camera reads stay at 30 FPS with 0 dropped.
- Laws (5 new, 38 in all): zigzag is a permutation; standard Huffman codes;
  magnitude categories and ones'-complement value bits; 0xFF byte stuffing;
  one restart interval per band. A corrupted zigzag entry fails its law.
  The four Huffman tables were checked prefix-free by the generator.

Costs and limits:
- CPU: about 90% of one core extra while a viewer watches (13% idle, 103%
  watching). ImageIO is roughly 2x faster per frame and may use hardware.
- Quality is fixed at 75 (baked into the generated tables).
- The checker leaves F32 comparisons unevaluated, so laws over F32 values
  (DCT output, rounding) are not possible yet; the DCT is verified by
  decoding and PSNR instead.
- Not yet run on real camera images; detail costs more than the test
  pattern (worst case above: 12.6 ms).
- A fallback to ImageIO exists for encoder overflow; it has not been
  triggered in testing (the writer holds 1 byte per pixel, and the worst
  case used 0.55).

## Milestone 5: shrink the native code

- Test pattern and snapshot (PPM) writer move into Bend.
- Review what remains native against rule 4 and move anything that decides
  something.

## Later milestones

Basic `imgproc`; video codecs; video analysis, features and calibration;
then DNN and model execution. Each milestone keeps the existing API, the
proofs and the performance baseline before the next one starts.

## Open questions and decisions

None right now.

Decided (2026-11-19):
- The access token is mandatory whenever sharing is on, with no option to
  turn it off.
- Default port 8765.
- Keep the in-browser sharing switch, honoured only from this computer.
