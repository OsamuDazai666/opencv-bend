import Base
import ./viewer_policy.bend as P
import ./image.bend as I
import ./jpeg.bend as J
import ./imgproc.bend as IP

# The browser viewer: opencv-bend's replacement for imshow and highgui.
#
# Opening a camera starts this server (once per process). It prints a URL;
# open it in a browser to watch. It is private by default: it listens on
# 127.0.0.1, so other machines cannot connect. Viewer.share_on_lan(True{}),
# OPENCV_BEND_SHARE=lan, or the switch on the page (from this computer only)
# shares it on the local network, behind a random access token.
# Every access decision is P.Policy.check, proven in PROOF.bend.

# --- Native effects (src/native/viewer.c) ----------------------------------

def Viewer.next_jpeg(+capture: U32, +after: U32, +timeout_ms: U32) ->
  IO(Result<&1, &1, U32 & String, U32>):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.send_jpeg(sock: Socket, +capture: U32) ->
  IO(Socket & Result<&1, &1, U32 & String, U32>):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.peer_is_local(sock: Socket) -> IO(Socket & Bool):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.lan_addresses() -> IO(String):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.random_token() -> IO(String):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.claim() -> IO(Bool):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.unclaim() -> IO(Unit):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.request_sharing(on: Bool) -> IO(Unit):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.requested_sharing() -> IO(Bool):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.publish_state(on: Bool, +epoch: U32) -> IO(Unit):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.state() -> IO(Bool & U32):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.capture_count() -> IO(U32):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.cameras() -> IO(List<U32>):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.capture_for(+index: U32) -> IO(U32):
  import "./native/viewer.c"
  import "./native/viewer.js"

# How many JPEGs the viewer has encoded for this capture (0 while nobody watches).
def Viewer.encodes(+capture: U32) -> IO(U32):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.view_for(name: String) -> IO(U32):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.views() -> IO(String):
  import "./native/viewer.c"
  import "./native/viewer.js"

def View.publish_native(name: String, +width: U32, +height: U32, +swap_rb: U32, bands: List<(U32 & Array<U32>)>) ->
  IO(List<(U32 & Array<U32>)> & Result<&1, &1, U32 & String, Unit>):
  import "./native/viewer.c"
  import "./native/viewer.js"

# Waits for a frame newer than `after`: (sequence, 0) if its JPEG is cached
# (or another viewer encoded it), else (sequence, frame) claimed for this
# viewer to encode in Bend.
def Viewer.peek(+capture: U32, +after: U32, +timeout_ms: U32) -> IO(Result<&1, &1, U32 & String, U32 & U32>):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.frame_size(+frame: U32) -> IO(Result<&1, &1, U32 & String, U32 & U32>):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.frame_bands(+frame: U32, +rows_per_band: U32, +swap_rb: U32) ->
  IO(Result<&1, &1, U32 & String, List<(U32 & Array<U32>)>>):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.frame_drop(+frame: U32) -> IO(Unit):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.store_jpeg(+capture: U32, +sequence: U32, segments: List<(Array<U32> & U32)>) ->
  IO(List<(Array<U32> & U32)> & Result<&1, &1, U32 & String, Unit>):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.base_port() -> IO(U32):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.stream_enter() -> IO(Bool):
  import "./native/viewer.c"
  import "./native/viewer.js"

def Viewer.stream_leave() -> IO(Unit):
  import "./native/viewer.c"
  import "./native/viewer.js"

# --- Public API -------------------------------------------------------------

# Shares the viewer on the local network (True{}) or makes it private again
# (False{}). Takes effect within a quarter second; turning sharing off
# disconnects every viewer on another machine.
def Viewer.share_on_lan(on: Bool) -> IO(Unit):
  Viewer.request_sharing(on)

# --- Server state -------------------------------------------------------------

# token: the LAN access token, new each time sharing is switched on.
# csrf: a per-run secret the sharing switch must echo back.
# epoch: increments on every re-bind; network streams from an older epoch stop.
type Server is Data:
  Server{sharing: P.Sharing, port: U32, token: String, csrf: String, epoch: U32}

def Viewer.forever() -> Nat:
  4294967295n

def Viewer.frame_timeout_ms() -> U32:
  2000

# --- HTTP responses (pages are ASCII, so length in chars is length in bytes) --

def Http.phrase_if(hit: Bool, phrase: String, other: String) -> String:
  match hit:
    case True{}:
      phrase
    case False{}:
      other

def Http.phrase(+status: U32) -> String:
  Http.phrase_if(U32.is_eq(status, 200), "OK",
    Http.phrase_if(U32.is_eq(status, 403), "Forbidden",
      Http.phrase_if(U32.is_eq(status, 404), "Not Found",
        Http.phrase_if(U32.is_eq(status, 431), "Request Header Fields Too Large", "Service Unavailable"))))

# Referrer-Policy is same-origin, not no-referrer: with no-referrer browsers
# send "Origin: null" on form posts, which the sharing switch must refuse.
def Http.response(+status: U32, ctype: String, +body: String) -> String:
  "HTTP/1.1 " ++ U32.show(status) ++ " " ++ Http.phrase(status) ++
    "\r\nContent-Type: " ++ ctype ++
    "\r\nContent-Length: " ++ Nat.show(String.length(body)) ++
    "\r\nCache-Control: no-store\r\nX-Frame-Options: DENY" ++
    "\r\nContent-Security-Policy: default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'" ++
    "\r\nReferrer-Policy: same-origin\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n" ++
    body

def Html.page(title: String, body: String) -> String:
  "<!doctype html><html><head><meta charset=\"utf-8\">" ++
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" ++
    "<title>" ++ title ++ "</title><style>" ++
    "body{font:16px/1.5 system-ui,sans-serif;margin:0;padding:16px;background:#111;color:#eee}" ++
    "a{color:#8cf}img{display:block;max-width:100%;height:auto;background:#000;margin:12px 0}" ++
    "button{font:inherit;padding:6px 14px;cursor:pointer}.note{color:#aaa}" ++
    ".private{color:#7d7}.shared{color:#fc6}code{word-break:break-all}" ++
    "</style></head><body>" ++ body ++ "</body></html>"

def Http.html(+status: U32, page: String) -> String:
  Http.response(status, "text/html; charset=utf-8", page)

def Http.error(+status: U32, reason: String) -> String:
  Http.html(status, Html.page("opencv-bend viewer", "<h1>" ++ U32.show(status) ++ "</h1><p>" ++ reason ++ "</p>"))

def Http.see_other() -> String:
  "HTTP/1.1 303 See Other\r\nLocation: /\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"

def Http.stream_head() -> String:
  "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame" ++
    "\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"

# --- Pages ------------------------------------------------------------------

# Viewers on another machine carry the token in every link they follow.
def Viewer.token_query(peer: P.Peer, +token: String) -> String:
  match peer:
    case P.Local{}:
      ""
    case P.Remote{}:
      "?token=" ++ token

def Viewer.camera_links(cams: List<U32>, +query: String) -> String:
  match cams:
    case Nil{}:
      ""
    case Con{+c, rest}:
      "<li><a href=\"/camera/" ++ U32.show(c) ++ query ++ "\">Camera " ++ U32.show(c) ++
        "</a></li>" ++ Viewer.camera_links(rest, query)

def Viewer.lan_links(addrs: List<&2, String>, +port: U32, +token: String) -> String:
  match addrs:
    case Nil{}:
      ""
    case Con{addr, rest}:
      "<li><code>http://" ++ addr ++ ":" ++ U32.show(port) ++ "/?token=" ++ token ++ "</code></li>" ++
        Viewer.lan_links(rest, port, token)

def Viewer.switch_button(+csrf: String, on: Bool) -> String:
  match on:
    case True{}:
      "<form method=\"post\" action=\"/sharing?share=on&amp;csrf=" ++ csrf ++
        "\"><button>Share on the local network</button></form>"
    case False{}:
      "<form method=\"post\" action=\"/sharing?share=off&amp;csrf=" ++ csrf ++
        "\"><button>Stop sharing</button></form>"

# The status block. Only a viewer on this computer sees the switch and the links.
def Viewer.status(peer: P.Peer, server: Server, lan: String) -> String:
  match peer server:
    case P.Remote{} _:
      "<p class=\"shared\">Shared from another computer on this network.</p>"
    case P.Local{} Server{P.Private{}, _, _, +csrf, _}:
      "<p class=\"private\">Private: only this computer can open this viewer.</p>" ++
        Viewer.switch_button(csrf, True{})
    case P.Local{} Server{P.Shared{}, +port, +token, +csrf, _}:
      "<p class=\"shared\">Shared on the local network. Other devices can watch with:</p><ul>" ++
        Viewer.lan_links(String.split(lan, ' '), port, token) ++
        "</ul><p class=\"note\">The stream is not encrypted: anyone on this network who has the link can watch it.</p>" ++
        Viewer.switch_button(csrf, False{})

def Viewer.view_link(empty: Bool, +name: String, +query: String) -> String:
  match empty:
    case True{}:
      ""
    case False{}:
      "<li><a href=\"/view/" ++ name ++ query ++ "\">" ++ name ++ "</a></li>"

# View names were validated by View.publish (P.Http.name_ok), so they are safe in HTML.
def Viewer.view_links(names: List<&2, String>, +query: String) -> String:
  match names:
    case Nil{}:
      ""
    case Con{+name, rest}:
      Viewer.view_link(String.is_empty(name), name, query) ++ Viewer.view_links(rest, query)

# --- View.publish: the replacement for imshow ------------------------------

def View.rebuilt(+width: U32, +height: U32,
  returned: List<(U32 & Array<U32>)> & Result<&1, &1, U32 & String, Unit>) ->
  I.Mat & Result<&1, &1, U32 & String, Unit>:
  (pieces, result) = returned
  (I.Mat.from_bands(width, height, pieces), result)

def View.publish_valid(+name: String, +width: U32, +height: U32, bands: I.Bands<Array<U32>>, valid: Bool) ->
  IO(I.Mat & Result<&1, &1, U32 & String, Unit>):
  match valid:
    case False{}:
      IO.pure(I.Mat & Result<&1, &1, U32 & String, Unit>, (I.Mat{width, height, bands},
        Fail{(22, "View names are 1 to 32 letters, digits, '-' or '_'.")}))
    case True{}:
      IO.bind(List<(U32 & Array<U32>)> & Result<&1, &1, U32 & String, Unit>,
        I.Mat & Result<&1, &1, U32 & String, Unit>,
        View.publish_native(name, width, height, I.Mat.swap_from_camera(), I.Bands.pieces(Array<U32>, bands)), returned =>
        IO.pure(I.Mat & Result<&1, &1, U32 & String, Unit>, View.rebuilt(width, height, returned)))

# Shows `image` in the browser viewer as the live view `name` (at
# /view/<name>), replacing its previous frame. The image is handed back
# unchanged. Views follow the same privacy rules as cameras, and appear while
# a camera keeps the viewer running.
def View.publish(+name: String, image: I.Mat) -> IO(I.Mat & Result<&1, &1, U32 & String, Unit>):
  match image:
    case I.Mat{+w, +h, bands}:
      View.publish_valid(name, w, h, bands, P.Http.name_ok(name))

def Viewer.index_page(+peer: P.Peer, +server: Server, cams: List<U32>, lan: String, views: String) -> String:
  match server:
    case Server{_, _, +token, _, _}:
      +q = Viewer.token_query(peer, token)
      Html.page("opencv-bend viewer",
        "<h1>opencv-bend viewer</h1>" ++ Viewer.status(peer, server, lan) ++
          "<h2>Cameras</h2><ul>" ++ Viewer.camera_links(cams, q) ++ "</ul>" ++
          "<h2>Views</h2><ul>" ++ Viewer.view_links(String.split(views, ' '), q) ++ "</ul>" ++
          "<p class=\"note\">Views appear when a program calls View.publish.</p>")

# The stream URL's query: a value unique to this page load, so a reload always
# opens a new stream (Safari otherwise reuses the previous, still-running
# download of the same URL), plus the token for viewers on another machine.
def Viewer.stream_query(peer: P.Peer, +token: String, +unique: Nat) -> String:
  match peer:
    case P.Local{}:
      "?v=" ++ Nat.show(unique)
    case P.Remote{}:
      "?v=" ++ Nat.show(unique) ++ "&amp;token=" ++ token

def Viewer.view_page(+peer: P.Peer, +server: Server, +name: String, +unique: Nat, missing: Bool) -> String:
  match server missing:
    case _ True{}:
      Http.error(404, "No view by that name has been published.")
    case Server{_, _, +token, _, _} False{}:
      +q = Viewer.token_query(peer, token)
      Http.html(200, Html.page(name,
        "<p><a href=\"/" ++ q ++ "\">All streams</a></p><h1>" ++ name ++ "</h1>" ++
          "<img src=\"/view/" ++ name ++ ".mjpg" ++ Viewer.stream_query(peer, token, unique) ++
          "\" alt=\"Live view " ++ name ++ "\">"))

def Viewer.camera_page(+peer: P.Peer, +server: Server, +camera: U32, +unique: Nat, missing: Bool) -> String:
  match server missing:
    case _ True{}:
      Http.error(404, "That camera is not open.")
    case Server{_, _, +token, _, _} False{}:
      +q = Viewer.token_query(peer, token)
      Http.html(200, Html.page("Camera " ++ U32.show(camera),
        "<p><a href=\"/" ++ q ++ "\">All cameras</a></p><h1>Camera " ++ U32.show(camera) ++ "</h1>" ++
          "<img src=\"/camera/" ++ U32.show(camera) ++ ".mjpg" ++ Viewer.stream_query(peer, token, unique) ++
          "\" alt=\"Live camera " ++ U32.show(camera) ++ "\">"))

# --- Connections ------------------------------------------------------------

def Viewer.closed(sent: Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>) -> IO(Unit):
  (sock, result) = sent
  Socket.close(sock)

def Viewer.send_close(sock: Socket, text: String) -> IO(Unit):
  IO.bind(Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>, Unit,
    TCP.send(sock, text), sent => Viewer.closed(sent))

# --- Request log (OPENCV_BEND_VIEWER_LOG=1) -----------------------------------------

def Viewer.log_on(on: Bool, +now: Nat, text: String) -> IO(Unit):
  match on:
    case True{}:
      IO.print_err("[viewer " ++ Nat.show(now) ++ " ms] " ++ text)
    case False{}:
      IO.pure(Unit, Unit{})

def Viewer.log_env(setting: Result<&1, &1, U32 & String, String>, +now: Nat, text: String) -> IO(Unit):
  match setting:
    case Done{value}:
      Viewer.log_on(String.eq(value, "1"), now, text)
    case Fail{_}:
      IO.pure(Unit, Unit{})

# Prints a line to stderr when OPENCV_BEND_VIEWER_LOG=1.
def Viewer.log(text: String) -> IO(Unit):
  do IO<Unit>:
    +now : Nat <- IO.now()
    setting : Result<&1, &1, U32 & String, String> <- IO.get_env("OPENCV_BEND_VIEWER_LOG")
    Viewer.log_env(setting, now, text)

def Viewer.stream_sent_result(sock: Socket, result: Result<&1, &1, U32 & String, U32>,
  next: Socket -> U32 -> IO(Unit)) -> IO(Unit):
  match result:
    case Fail{(code, message)}:
      do IO<Unit>:
        Viewer.log("stream ended: sending failed (" ++ U32.show(code) ++ ", " ++ message ++ ")")
        Socket.close(sock)
    case Done{sequence}:
      next(sock, sequence)

def Viewer.stream_sent(sent: Socket & Result<&1, &1, U32 & String, U32>,
  next: Socket -> U32 -> IO(Unit)) -> IO(Unit):
  (sock, result) = sent
  Viewer.stream_sent_result(sock, result, next)

# No new frame within 2 s. While a camera is open the stream waits on (a
# paused camera, or a view not republished yet). Once no camera is open the
# program is finishing, so the stream ends; otherwise a view stream, which
# has no camera to close, would wait forever and keep the program alive.
def Viewer.stream_waiting(sock: Socket, +after: U32, serving: Bool, next: Socket -> U32 -> IO(Unit)) -> IO(Unit):
  match serving:
    case True{}:
      do IO<Unit>:
        Viewer.log("no frame within 2 s; still waiting")
        next(sock, after)
    case False{}:
      do IO<Unit>:
        Viewer.log("stream ended: no camera is open any more")
        Socket.close(sock)

# A camera that pauses (timeout) keeps the stream open; anything else ends it.
def Viewer.stream_failed(sock: Socket, +after: U32, timed_out: Bool,
  next: Socket -> U32 -> IO(Unit)) -> IO(Unit):
  match timed_out:
    case True{}:
      IO.bind(U32, Unit, Viewer.capture_count(), count =>
        Viewer.stream_waiting(sock, after, U32.is_gt(count, 0), next))
    case False{}:
      do IO<Unit>:
        Viewer.log("stream ended: the camera failed or closed")
        Socket.close(sock)

def Viewer.stream_frame(sock: Socket, +capture: U32, +after: U32,
  ready: Result<&1, &1, U32 & String, U32>, next: Socket -> U32 -> IO(Unit)) -> IO(Unit):
  match ready:
    case Fail{(+code, _)}:
      Viewer.stream_failed(sock, after, U32.is_eq(code, 60), next)
    case Done{_}:
      IO.bind(Socket & Result<&1, &1, U32 & String, U32>, Unit,
        Viewer.send_jpeg(sock, capture), sent => Viewer.stream_sent(sent, next))

def Viewer.stream_send(sock: Socket, +capture: U32, next: Socket -> U32 -> IO(Unit)) -> IO(Unit):
  IO.bind(Socket & Result<&1, &1, U32 & String, U32>, Unit, Viewer.send_jpeg(sock, capture), sent =>
    Viewer.stream_sent(sent, next))

# ImageIO (native) for this frame, when the Bend encoder could not be used.
def Viewer.stream_fallback(sock: Socket, +capture: U32, +after: U32, next: Socket -> U32 -> IO(Unit)) ->
  IO(Unit):
  IO.bind(Result<&1, &1, U32 & String, U32>, Unit,
    Viewer.next_jpeg(capture, after, Viewer.frame_timeout_ms()), ready =>
    Viewer.stream_frame(sock, capture, after, ready, next))

def Viewer.stream_stored_result(sock: Socket, +capture: U32, +after: U32,
  result: Result<&1, &1, U32 & String, Unit>, next: Socket -> U32 -> IO(Unit)) -> IO(Unit):
  match result:
    case Done{_}:
      Viewer.stream_send(sock, capture, next)
    case Fail{_}:
      Viewer.stream_fallback(sock, capture, after, next)

def Viewer.stream_stored(sock: Socket, +capture: U32, +after: U32,
  stored: List<(Array<U32> & U32)> & Result<&1, &1, U32 & String, Unit>, next: Socket -> U32 -> IO(Unit)) ->
  IO(Unit):
  (segs, result) = stored
  Viewer.stream_stored_result(sock, capture, after, result, next)

def Viewer.store_encoded(sock: Socket, +capture: U32, +after: U32, +sequence: U32,
  encoded: I.Mat & List<(Array<U32> & U32)>, next: Socket -> U32 -> IO(Unit)) -> IO(Unit):
  (mat, segs) = encoded
  IO.bind(List<(Array<U32> & U32)> & Result<&1, &1, U32 & String, Unit>, Unit,
    Viewer.store_jpeg(capture, sequence, segs), stored => Viewer.stream_stored(sock, capture, after, stored, next))

def Viewer.preview_k_by(full: Bool, half: Bool, quarter: Bool) -> U32:
  match full half quarter:
    case True{} _ _:
      1
    case False{} True{} _:
      2
    case False{} False{} True{}:
      4
    case False{} False{} False{}:
      8

# --- Preview size ----------------------------------------------------------------
# Browsers cannot show 4K or 8K pixels anyway, and encoding them takes 16-64
# ms. Frames larger than 1920x1080 are shrunk by 2, 4 or 8 (area average)
# before encoding; the program's own images are never touched.

def Viewer.preview_k(+w: U32, +h: U32) -> U32:
  Viewer.preview_k_by(Bool.and(U32.is_le(w, 1920), U32.is_le(h, 1080)),
    Bool.and(U32.is_le(w, 3840), U32.is_le(h, 2160)), Bool.and(U32.is_le(w, 7680), U32.is_le(h, 4320)))

def Viewer.preview_or(original: I.Mat, small: Maybe<&1, I.Mat>) -> I.Mat:
  match small:
    case Some{s}:
      s
    case None{}:
      original

def Viewer.preview_pick(shrunk: I.Mat & Maybe<&1, I.Mat>) -> I.Mat:
  (original, small) = shrunk
  Viewer.preview_or(original, small)

def Viewer.preview_if(keep: Bool, mat: I.Mat, +k: U32) -> I.Mat:
  match keep:
    case True{}:
      mat
    case False{}:
      Viewer.preview_pick(IP.Mat.downscale(mat, k))

def Viewer.preview_at(mat: I.Mat, size: U32 & U32) -> I.Mat:
  (+w, +h) = size
  +k = Viewer.preview_k(w, h)
  Viewer.preview_if(U32.is_eq(k, 1), mat, k)

def Viewer.preview_sized(sized: I.Mat & (U32 & U32)) -> I.Mat:
  (mat, size) = sized
  Viewer.preview_at(mat, size)

# The image the viewer encodes: at most about 1920x1080.
def Viewer.preview(mat: I.Mat) -> I.Mat:
  Viewer.preview_sized(I.Mat.size(mat))

def Viewer.stream_banded(sock: Socket, +capture: U32, +after: U32, +sequence: U32, +frame: U32, +w: U32, +h: U32,
  banded: Result<&1, &1, U32 & String, List<(U32 & Array<U32>)>>, next: Socket -> U32 -> IO(Unit)) -> IO(Unit):
  match banded:
    case Fail{_}:
      do IO<Unit>:
        Viewer.frame_drop(frame)
        Viewer.stream_fallback(sock, capture, after, next)
    case Done{pieces}:
      do IO<Unit>:
        Viewer.frame_drop(frame)
        Viewer.store_encoded(sock, capture, after, sequence, J.Jpeg.encode(Viewer.preview(I.Mat.from_bands(w, h, pieces))), next)

def Viewer.stream_sized(sock: Socket, +capture: U32, +after: U32, +sequence: U32, +frame: U32,
  sized: Result<&1, &1, U32 & String, U32 & U32>, next: Socket -> U32 -> IO(Unit)) -> IO(Unit):
  match sized:
    case Fail{_}:
      do IO<Unit>:
        Viewer.frame_drop(frame)
        Viewer.stream_fallback(sock, capture, after, next)
    case Done{(+w, +h)}:
      IO.bind(Result<&1, &1, U32 & String, List<(U32 & Array<U32>)>>, Unit,
        Viewer.frame_bands(frame, I.Mat.rows_per_band(w, h), I.Mat.swap_from_camera()), banded =>
        Viewer.stream_banded(sock, capture, after, sequence, frame, w, h, banded, next))

# The frame is cached already, or this viewer encodes it with the Bend encoder.
def Viewer.stream_claimed(sock: Socket, +capture: U32, +after: U32, +sequence: U32, +frame: U32, cached: Bool,
  next: Socket -> U32 -> IO(Unit)) -> IO(Unit):
  match cached:
    case True{}:
      Viewer.stream_send(sock, capture, next)
    case False{}:
      IO.bind(Result<&1, &1, U32 & String, U32 & U32>, Unit, Viewer.frame_size(frame), sized =>
        Viewer.stream_sized(sock, capture, after, sequence, frame, sized, next))

def Viewer.stream_peeked(sock: Socket, +capture: U32, +after: U32,
  peeked: Result<&1, &1, U32 & String, U32 & U32>, next: Socket -> U32 -> IO(Unit)) -> IO(Unit):
  match peeked:
    case Fail{(+code, _)}:
      Viewer.stream_failed(sock, after, U32.is_eq(code, 60), next)
    case Done{(+sequence, +frame)}:
      Viewer.stream_claimed(sock, capture, after, sequence, frame, U32.is_eq(frame, 0), next)

def Viewer.stream_gate(sock: Socket, +capture: U32, +after: U32, keep: Bool,
  next: Socket -> U32 -> IO(Unit)) -> IO(Unit):
  match keep:
    case False{}:
      do IO<Unit>:
        Viewer.log("stream ended: sharing changed")
        Socket.close(sock)
    case True{}:
      IO.bind(Result<&1, &1, U32 & String, U32 & U32>, Unit,
        Viewer.peek(capture, after, Viewer.frame_timeout_ms()), peeked =>
        Viewer.stream_peeked(sock, capture, after, peeked, next))

def Viewer.stream_step(sock: Socket, +capture: U32, +after: U32, +peer: P.Peer, +epoch: U32,
  state: Bool & U32, next: Socket -> U32 -> IO(Unit)) -> IO(Unit):
  (on, +now) = state
  Viewer.stream_gate(sock, capture, after,
    P.Policy.keep_streaming(peer, P.Policy.sharing_of(on), now, epoch), next)

# Sends frames until the browser leaves, the camera closes, or the policy
# says this viewer may no longer watch.
def Viewer.log_progress(due: Bool, +sent: U32) -> IO(Unit):
  match due:
    case True{}:
      Viewer.log("stream: " ++ U32.show(sent) ++ " frames sent")
    case False{}:
      IO.pure(Unit, Unit{})

# Logs the first frame of a stream, then every 150 frames (about 5 s).
def Viewer.progress(+sent: U32) -> IO(Unit):
  Viewer.log_progress(Bool.or(U32.is_eq(sent, 1),
    Bool.and(U32.is_gt(sent, 0), U32.is_eq((sent % 150 : U32), 0))), sent)

def Viewer.count_if(same: Bool, +sent: U32) -> U32:
  match same:
    case True{}:
      sent
    case False{}:
      (sent + 1 : U32)

# A frame was sent when the sequence moved on (a camera timeout keeps it).
def Viewer.next_count(+before: U32, +now: U32, +sent: U32) -> U32:
  Viewer.count_if(U32.is_eq(before, now), sent)

# Sends frames until the browser leaves, the camera closes, or the policy
# says this viewer may no longer watch. `sent` counts frames sent so far.
def Viewer.stream_loop(fuel: Nat, sock: Socket, +capture: U32, +after: U32,
  +peer: P.Peer, +epoch: U32, +sent: U32) -> IO(Unit):
  match fuel:
    case 0n:
      Socket.close(sock)
    case 1n+p:
      do IO<Unit>:
        Viewer.progress(sent)
        state : Bool & U32 <- Viewer.state()
        Viewer.stream_step(sock, capture, after, peer, epoch, state, next_sock => +sequence =>
          Viewer.stream_loop(p, next_sock, capture, sequence, peer, epoch, Viewer.next_count(after, sequence, sent)))

def Viewer.stream_go(sock: Socket, +peer: P.Peer, +epoch: U32, +capture: U32,
  head: Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>) -> IO(Unit):
  match head:
    case Fail{_}:
      do IO<Unit>:
        Viewer.stream_leave()
        Socket.close(sock)
    case Done{_}:
      do IO<Unit>:
        Viewer.log("stream started")
        Viewer.stream_loop(Viewer.forever(), sock, capture, 0, peer, epoch, 0)
        Viewer.stream_leave()

def Viewer.stream_begin(sent: Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>,
  +peer: P.Peer, +epoch: U32, +capture: U32) -> IO(Unit):
  (sock, head) = sent
  Viewer.stream_go(sock, peer, epoch, capture, head)

def Viewer.stream_admit(sock: Socket, +peer: P.Peer, +epoch: U32, +capture: U32, admitted: Bool) ->
  IO(Unit):
  match admitted:
    case False{}:
      Viewer.send_close(sock, Http.error(503, "Too many viewers are watching. Try again later."))
    case True{}:
      IO.bind(Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>, Unit,
        TCP.send(sock, Http.stream_head()), sent => Viewer.stream_begin(sent, peer, epoch, capture))

def Viewer.stream_start(sock: Socket, +peer: P.Peer, +epoch: U32, +capture: U32, missing: Bool) ->
  IO(Unit):
  match missing:
    case True{}:
      Viewer.send_close(sock, Http.error(404, "That camera is not open."))
    case False{}:
      IO.bind(Bool, Unit, Viewer.stream_enter(), admitted =>
        Viewer.stream_admit(sock, peer, epoch, capture, admitted))

def Viewer.epoch_of(server: Server) -> U32:
  match server:
    case Server{_, _, _, _, epoch}:
      epoch

def Viewer.serve_route(sock: Socket, +peer: P.Peer, route: P.Route, +server: Server) -> IO(Unit):
  match route:
    case P.Index{}:
      do IO<Unit>:
        cams : List<U32> <- Viewer.cameras()
        lan : String <- Viewer.lan_addresses()
        views : String <- Viewer.views()
        Viewer.send_close(sock, Http.html(200, Viewer.index_page(peer, server, cams, lan, views)))
    case P.Page{+camera}:
      do IO<Unit>:
        +capture : U32 <- Viewer.capture_for(camera)
        +unique : Nat <- IO.now()
        Viewer.send_close(sock, Viewer.camera_page(peer, server, camera, unique, U32.is_eq(capture, 0)))
    case P.Stream{+camera}:
      do IO<Unit>:
        +capture : U32 <- Viewer.capture_for(camera)
        Viewer.stream_start(sock, peer, Viewer.epoch_of(server), capture, U32.is_eq(capture, 0))
    case P.ViewPage{+name}:
      do IO<Unit>:
        +capture : U32 <- Viewer.view_for(name)
        +unique : Nat <- IO.now()
        Viewer.send_close(sock, Viewer.view_page(peer, server, name, unique, U32.is_eq(capture, 0)))
    case P.ViewStream{+name}:
      do IO<Unit>:
        +capture : U32 <- Viewer.view_for(name)
        Viewer.stream_start(sock, peer, Viewer.epoch_of(server), capture, U32.is_eq(capture, 0))
    case P.SetSharing{on}:
      do IO<Unit>:
        Viewer.request_sharing(on)
        Viewer.send_close(sock, Http.see_other())
    case P.NotFound{}:
      Viewer.send_close(sock, Http.error(404, "Not found."))

def Viewer.peer_name(peer: P.Peer) -> String:
  match peer:
    case P.Local{}:
      "local"
    case P.Remote{}:
      "remote"

def Viewer.answer(sock: Socket, +peer: P.Peer, +route: P.Route, +server: Server, +path: String,
  verdict: P.Verdict) -> IO(Unit):
  match verdict:
    case P.Deny{+status, +reason}:
      do IO<Unit>:
        Viewer.log(Viewer.peer_name(peer) ++ " " ++ path ++ " -> " ++ U32.show(status) ++ " (" ++ reason ++ ")")
        Viewer.send_close(sock, Http.error(status, reason))
    case P.Allow{}:
      do IO<Unit>:
        Viewer.log(Viewer.peer_name(peer) ++ " " ++ path ++ " -> allowed")
        Viewer.serve_route(sock, peer, route, server)

def Viewer.check(+peer: P.Peer, server: Server, +route: P.Route, +req: P.Request) -> P.Verdict:
  match server:
    case Server{sharing, +port, +token, +csrf, _}:
      P.Policy.check(sharing, peer, port, token, csrf, route, req)

def Viewer.decide(sock: Socket, +peer: P.Peer, +server: Server, parsed: P.Request & P.Route) ->
  IO(Unit):
  (+req, +route) = parsed
  Viewer.answer(sock, peer, route, server, P.Request.path(req), Viewer.check(peer, server, route, req))

def Viewer.dispatch(sock: Socket, +peer: P.Peer, +server: Server, parsed: P.Request & P.Route) ->
  IO(Unit):
  match server:
    case Server{+sharing, +port, +token, +csrf, +epoch}:
      Viewer.decide(sock, peer, Server{sharing, port, token, csrf, epoch}, parsed)

def Viewer.peer_of(local: Bool) -> P.Peer:
  match local:
    case True{}:
      P.Local{}
    case False{}:
      P.Remote{}

def Viewer.with_peer(located: Socket & Bool, raw: String, +server: Server) -> IO(Unit):
  (sock, local) = located
  Viewer.dispatch(sock, Viewer.peer_of(local), server, P.Http.parse(raw))

def Viewer.still_serving(sock: Socket, serving: Bool, again: Socket -> IO(Unit)) -> IO(Unit):
  match serving:
    case True{}:
      again(sock)
    case False{}:
      Socket.close(sock)

# Requests longer than this are refused (a request line and headers only).
def Viewer.max_request() -> Nat:
  16384n

def Viewer.too_long(sock: Socket, too_long: Bool, +text: String, +server: Server,
  again: Socket -> String -> IO(Unit)) -> IO(Unit):
  match too_long:
    case True{}:
      do IO<Unit>:
        Viewer.log("a request's headers were longer than 16 KB")
        Viewer.send_close(sock, Http.error(431, "Request headers too large."))
    case False{}:
      again(sock, text)

# The headers end with a blank line. Until it arrives, keep reading: browsers
# may send one request in several pieces.
def Viewer.with_text(sock: Socket, complete: Bool, +text: String, +server: Server,
  again: Socket -> String -> IO(Unit)) -> IO(Unit):
  match complete:
    case True{}:
      IO.bind(Socket & Bool, Unit, Viewer.peer_is_local(sock), located =>
        Viewer.with_peer(located, text, server))
    case False{}:
      Viewer.too_long(sock, Nat.is_gt(String.length(text), Viewer.max_request()), text, server, again)

# Waiting ended: bytes arrived, the connection closed, or a 1 s slice ran out
# (then keep waiting while the viewer is still serving a camera).
def Viewer.on_request(sock: Socket,
  polled: Poll<&1, &1, Result<&1, &1, U32 & String, Maybe<&1, String>>, Unit>, +so_far: String,
  +server: Server, again: Socket -> String -> IO(Unit)) -> IO(Unit):
  match polled:
    case Ready{Done{Some{+chunk}}}:
      +text = so_far ++ chunk
      Viewer.with_text(sock, String.contains(text, "\r\n\r\n"), text, server, again)
    case Wait{_}:
      IO.bind(U32, Unit, Viewer.capture_count(), count =>
        Viewer.still_serving(sock, U32.is_gt(count, 0), next => again(next, so_far)))
    case _:
      do IO<Unit>:
        Viewer.log("a connection closed without a complete request")
        Socket.close(sock)

def Viewer.received(got: Socket & Poll<&1, &1, Result<&1, &1, U32 & String, Maybe<&1, String>>, Unit>,
  +so_far: String, +server: Server, again: Socket -> String -> IO(Unit)) -> IO(Unit):
  (sock, polled) = got
  Viewer.on_request(sock, polled, so_far, server, again)

# How long a connection may stay idle before its request is complete, in 1 s
# slices. Browsers (Safari especially) open spare connections early and use
# them seconds later; closing them after 5 s made Safari send the stream
# request down a dead connection. Waiting in slices lets the program exit
# promptly once no camera is open.
def Viewer.idle_seconds() -> Nat:
  120n

def Viewer.wait_request(fuel: Nat, sock: Socket, +so_far: String, +server: Server) -> IO(Unit):
  match fuel:
    case 0n:
      do IO<Unit>:
        Viewer.log("a connection stayed idle without a complete request")
        Socket.close(sock)
    case 1n+p:
      IO.bind(Socket & Poll<&1, &1, Result<&1, &1, U32 & String, Maybe<&1, String>>, Unit>, Unit,
        TCP.try_recv(sock, 8192, 1000), got =>
        Viewer.received(got, so_far, server, next => text => Viewer.wait_request(p, next, text, server)))

# One browser connection: wait for the request, decide, answer.
def Viewer.handle(sock: Socket, +server: Server) -> IO(Unit):
  Viewer.wait_request(Viewer.idle_seconds(), sock, "", server)

# --- Listener -----------------------------------------------------------------

def Viewer.stop(listener: Listener, +epoch: U32) -> IO(Unit):
  do IO<Unit>:
    Listener.close(listener)
    Viewer.publish_state(False{}, epoch)
    Viewer.unclaim()

def Viewer.lan_lines(addrs: List<&2, String>, +port: U32, +token: String) -> String:
  match addrs:
    case Nil{}:
      ""
    case Con{addr, rest}:
      "\n  http://" ++ addr ++ ":" ++ U32.show(port) ++ "/?token=" ++ token ++
        Viewer.lan_lines(rest, port, token)

def Viewer.announce_text(server: Server, lan: String) -> String:
  match server:
    case Server{P.Private{}, +port, _, _, _}:
      "Viewer: http://127.0.0.1:" ++ U32.show(port) ++
        "/  (private: only this computer can connect)"
    case Server{P.Shared{}, +port, +token, _, _}:
      "Viewer: http://127.0.0.1:" ++ U32.show(port) ++
        "/  SHARED on the local network. Other devices can watch at:" ++
        Viewer.lan_lines(String.split(lan, ' '), port, token) ++
        "\n  The stream is not encrypted: anyone on this network with the link can watch."

def Viewer.announce(+server: Server) -> IO(Unit):
  match server:
    case Server{+sharing, _, _, _, +epoch}:
      do IO<Unit>:
        lan : String <- Viewer.lan_addresses()
        IO.print(Viewer.announce_text(server, lan))
        Viewer.publish_state(P.Policy.is_shared(sharing), epoch)

def Viewer.with_port(server: Server, +port: U32) -> Server:
  match server:
    case Server{sharing, _, token, csrf, epoch}:
      Server{sharing, port, token, csrf, epoch}

def Viewer.port_of(server: Server) -> U32:
  match server:
    case Server{_, port, _, _, _}:
      port

def Viewer.host_of(server: Server) -> String:
  match server:
    case Server{sharing, _, _, _, _}:
      P.Policy.bind_host(sharing)

def Viewer.listen_failed_go(+code: U32, message: String, +server: Server, in_use: Bool,
  again: Server -> IO(Unit)) -> IO(Unit):
  match in_use:
    case True{}:
      again(Viewer.with_port(server, (Viewer.port_of(server) + 1 : U32)))
    case False{}:
      do IO<Unit>:
        IO.print_err("Viewer: could not listen on " ++ Viewer.host_of(server) ++ ":" ++
          U32.show(Viewer.port_of(server)) ++ " (error " ++ U32.show(code) ++ "). The viewer is off.")
        Viewer.publish_state(False{}, 0)
        Viewer.unclaim()

def Viewer.listen_failed(error: U32 & String, +server: Server, retry: Bool,
  again: Server -> IO(Unit)) -> IO(Unit):
  (+code, message) = error
  Viewer.listen_failed_go(code, message, server, Bool.and(retry, U32.is_eq(code, 48)), again)

def Viewer.listened(result: Result<&1, &1, U32 & String, Listener>, +server: Server, retry: Bool,
  again: Server -> IO(Unit), run: Listener -> Server -> IO(Unit)) -> IO(Unit):
  match result:
    case Fail{error}:
      Viewer.listen_failed(error, server, retry, again)
    case Done{listener}:
      do IO<Unit>:
        Viewer.announce(server)
        run(listener, server)

# Re-binds after the sharing switch: same port, new token and epoch.
def Viewer.rebind(+server: Server, want: Bool, run: Listener -> Server -> IO(Unit)) -> IO(Unit):
  match server:
    case Server{_, +port, _, +csrf, +epoch}:
      do IO<Unit>:
        token : String <- Viewer.random_token()
        +next : Server = Server{P.Policy.sharing_of(want), port, token, csrf, (epoch + 1 : U32)}
        result : Result<&1, &1, U32 & String, Listener> <- TCP.listen(Viewer.host_of(next), port)
        Viewer.listened(result, next, False{}, unused => IO.pure(Unit, Unit{}), run)

def Viewer.tick(listener: Listener, +server: Server, idle: Bool, changed: Bool, +want: Bool,
  next: Listener -> Server -> IO(Unit)) -> IO(Unit):
  match idle changed:
    case True{} _:
      Viewer.stop(listener, Viewer.epoch_of(server))
    case False{} True{}:
      do IO<Unit>:
        Listener.close(listener)
        Viewer.rebind(server, want, next)
    case False{} False{}:
      next(listener, server)

def Viewer.sharing_of(server: Server) -> P.Sharing:
  match server:
    case Server{sharing, _, _, _, _}:
      sharing

def Viewer.on_tick(listener: Listener, +server: Server, +count: U32, +want: Bool,
  next: Listener -> Server -> IO(Unit)) -> IO(Unit):
  Viewer.tick(listener, server, U32.is_eq(count, 0),
    Bool.xor(want, P.Policy.is_shared(Viewer.sharing_of(server))), want, next)

def Viewer.on_poll(listener: Listener,
  polled: Poll<&1, &1, Result<&1, &1, U32 & String, Socket>, Unit>, +server: Server,
  next: Listener -> Server -> IO(Unit)) -> IO(Unit):
  match polled:
    case Ready{Done{sock}}:
      do IO<Unit>:
        IO.spawn(Unit, Viewer.handle(sock, server))
        next(listener, server)
    case Ready{Fail{_}}:
      next(listener, server)
    case Wait{_}:
      do IO<Unit>:
        +count : U32 <- Viewer.capture_count()
        +want : Bool <- Viewer.requested_sharing()
        Viewer.on_tick(listener, server, count, want, next)

def Viewer.after_poll(got: Listener & Poll<&1, &1, Result<&1, &1, U32 & String, Socket>, Unit>,
  +server: Server, next: Listener -> Server -> IO(Unit)) -> IO(Unit):
  (listener, polled) = got
  Viewer.on_poll(listener, polled, server, next)

# Accepts connections; every quarter second it checks whether any camera is
# still open (if not, it stops) and whether the sharing switch moved.
def Viewer.loop(fuel: Nat, listener: Listener, +server: Server) -> IO(Unit):
  match fuel:
    case 0n:
      Viewer.stop(listener, Viewer.epoch_of(server))
    case 1n+p:
      IO.bind(Listener & Poll<&1, &1, Result<&1, &1, U32 & String, Socket>, Unit>, Unit,
        TCP.try_accept(listener, 250), got =>
        Viewer.after_poll(got, server, l => s => Viewer.loop(p, l, s)))

# The first bind: if the port is taken, try the next one (10 ports at most).
def Viewer.listen_first(tries: Nat, +server: Server) -> IO(Unit):
  match tries:
    case 0n:
      do IO<Unit>:
        IO.print_err("Viewer: no free port found. The viewer is off.")
        Viewer.unclaim()
    case 1n+t:
      IO.bind(Result<&1, &1, U32 & String, Listener>, Unit,
        TCP.listen(Viewer.host_of(server), Viewer.port_of(server)), result =>
        Viewer.listened(result, server, True{}, moved => Viewer.listen_first(t, moved),
          l => s => Viewer.loop(Viewer.forever(), l, s)))

def Viewer.serve() -> IO(Unit):
  do IO<Unit>:
    csrf : String <- Viewer.random_token()
    token : String <- Viewer.random_token()
    want : Bool <- Viewer.requested_sharing()
    port : U32 <- Viewer.base_port()
    Viewer.listen_first(10n, Server{P.Policy.sharing_of(want), port, token, csrf, 1})

def Viewer.start_if(won: Bool) -> IO(Unit):
  match won:
    case True{}:
      IO.spawn(Unit, Viewer.serve())
    case False{}:
      IO.pure(Unit, Unit{})

# Called by VideoCapture.open: starts the viewer unless it is already running.
def Viewer.start() -> IO(Unit):
  IO.bind(Bool, Unit, Viewer.claim(), won => Viewer.start_if(won))
