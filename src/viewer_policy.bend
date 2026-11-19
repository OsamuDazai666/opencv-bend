import Base

# Pure rules of the browser viewer: who may connect, what each URL means,
# and when a running stream must stop. No effects here, so LAWS.bend can
# import this module and prove the privacy guarantees.

# Where a connection comes from: this computer (loopback) or the network.
type Peer is Data:
  Local{}
  Remote{}

# The sharing toggle. Private is the "firewall on" default.
type Sharing is Data:
  Private{}
  Shared{}

type Route is Data:
  Index{}
  Page{camera: U32}
  Stream{camera: U32}
  ViewPage{name: String}
  ViewStream{name: String}
  SetSharing{on: Bool}
  NotFound{}

# The parts of an HTTP request the policy reads. Missing values are "".
# token, csrf and share come from the query string.
type Request is Data:
  Request{method: String, path: String, host: String, origin: String,
    fetch_site: String, token: String, csrf: String, share: String}

type Verdict is Data:
  Allow{}
  Deny{status: U32, reason: String}

def Policy.default_sharing() -> Sharing:
  Private{}

# The address the server listens on. Private binds loopback only, so other
# machines cannot even open a connection.
def Policy.bind_host(sharing: Sharing) -> String:
  match sharing:
    case Private{}:
      "127.0.0.1"
    case Shared{}:
      "0.0.0.0"

def Policy.sharing_of(on: Bool) -> Sharing:
  match on:
    case True{}:
      Shared{}
    case False{}:
      Private{}

def Policy.is_shared(sharing: Sharing) -> Bool:
  match sharing:
    case Private{}:
      False{}
    case Shared{}:
      True{}

def Policy.allowed(verdict: Verdict) -> Bool:
  match verdict:
    case Allow{}:
      True{}
    case Deny{_, _}:
      False{}

def Request.host(req: Request) -> String:
  match req:
    case Request{_, _, host, _, _, _, _, _}:
      host

def Request.path(req: Request) -> String:
  match req:
    case Request{_, path, _, _, _, _, _, _}:
      path

def Request.token(req: Request) -> String:
  match req:
    case Request{_, _, _, _, _, token, _, _}:
      token

def Request.fetch_site(req: Request) -> String:
  match req:
    case Request{_, _, _, _, fetch_site, _, _, _}:
      fetch_site

def Request.method(req: Request) -> String:
  match req:
    case Request{method, _, _, _, _, _, _, _}:
      method

def Request.origin(req: Request) -> String:
  match req:
    case Request{_, _, _, origin, _, _, _, _}:
      origin

def Request.csrf(req: Request) -> String:
  match req:
    case Request{_, _, _, _, _, _, csrf, _}:
      csrf

# A browser on this computer names the server by its loopback address.
# Anything else is refused: it blocks DNS-rebinding attacks, where a
# malicious site points its own hostname at 127.0.0.1.
def Policy.local_host_ok(+port: U32, +host: String) -> Bool:
  +p = U32.show(port)
  Bool.or(String.eq(host, "127.0.0.1:" ++ p), String.eq(host, "localhost:" ++ p))

def Policy.local_origin_ok(+port: U32, +origin: String) -> Bool:
  +p = U32.show(port)
  Bool.or(String.eq(origin, "http://127.0.0.1:" ++ p), String.eq(origin, "http://localhost:" ++ p))

def Policy.token_gate(ok: Bool) -> Verdict:
  match ok:
    case True{}:
      Allow{}
    case False{}:
      Deny{403, "A valid access token is required."}

def Policy.toggle_gate(ok: Bool) -> Verdict:
  match ok:
    case True{}:
      Allow{}
    case False{}:
      Deny{403, "The sharing switch only works from this computer's viewer page."}

def Policy.check_remote(sharing: Sharing, +token: String, route: Route, +req: Request) -> Verdict:
  match sharing:
    case Private{}:
      Deny{403, "This viewer is private to the computer running it."}
    case Shared{}:
      match route:
        case SetSharing{_}:
          Deny{403, "Sharing can only be changed from the computer running the viewer."}
        case _:
          Policy.token_gate(String.eq(Request.token(req), token))

def Policy.check_local_route(+port: U32, +csrf: String, route: Route, +req: Request) -> Verdict:
  match route:
    case SetSharing{_}:
      Policy.toggle_gate(Bool.and(Bool.and(String.eq(Request.method(req), "POST"),
        Policy.local_origin_ok(port, Request.origin(req))), String.eq(Request.csrf(req), csrf)))
    case _:
      Allow{}

def Policy.check_local_site(+port: U32, +csrf: String, route: Route, +req: Request,
  cross_site: Bool) -> Verdict:
  match cross_site:
    case True{}:
      Deny{403, "Requests from other websites are refused."}
    case False{}:
      Policy.check_local_route(port, csrf, route, req)

def Policy.check_local(+port: U32, +csrf: String, route: Route, +req: Request, host_ok: Bool) -> Verdict:
  match host_ok:
    case False{}:
      Deny{403, "Unexpected Host header."}
    case True{}:
      Policy.check_local_site(port, csrf, route, req,
        String.eq(Request.fetch_site(req), "cross-site"))

# The whole access decision for one request.
# token: the LAN access token (only meaningful while shared).
# csrf: the per-run secret that the sharing switch must echo back.
def Policy.check(sharing: Sharing, peer: Peer, +port: U32, +token: String, +csrf: String,
  route: Route, +req: Request) -> Verdict:
  match peer:
    case Local{}:
      Policy.check_local(port, csrf, route, req, Policy.local_host_ok(port, Request.host(req)))
    case Remote{}:
      Policy.check_remote(sharing, token, route, req)

# Whether a running stream may keep sending frames. A stream started by a
# remote viewer stops as soon as sharing is turned off, or turned off and on
# again (a new epoch, with a new token).
def Policy.keep_streaming(peer: Peer, sharing: Sharing, +epoch_now: U32, +epoch_then: U32) -> Bool:
  match peer:
    case Local{}:
      True{}
    case Remote{}:
      match sharing:
        case Private{}:
          False{}
        case Shared{}:
          U32.is_eq(epoch_now, epoch_then)

# --- Parsing ---------------------------------------------------------------

def Http.trim_cr(line: String) -> String:
  String.trim_end(line)

def Http.header_if(hit: Bool, rest: List<&2, String>) -> Maybe<&2, String>:
  match hit:
    case True{}:
      Some{String.trim(String.join(rest, ":"))}
    case False{}:
      None{}

# "Name: value" with the value rejoined, since a Host value has a colon.
def Http.header_value(parts: List<&2, String>, +want: String) -> Maybe<&2, String>:
  match parts:
    case Nil{}:
      None{}
    case Con{name, rest}:
      Http.header_if(String.eq(String.to_lower(String.trim(name)), want), rest)

def Http.header_pick(found: Maybe<&2, String>, +lines: List<&2, String>, +want: String,
  next: List<&2, String> -> String -> String) -> String:
  match found:
    case Some{value}:
      value
    case None{}:
      next(lines, want)

# The first header named `want` (lower case), or "".
def Http.header(lines: List<&2, String>, +want: String) -> String:
  match lines:
    case Nil{}:
      ""
    case Con{line, +rest}:
      Http.header_pick(Http.header_value(String.split(Http.trim_cr(line), ':'), want),
        rest, want, more => key => Http.header(rest, key))

def Http.param_value(parts: List<&2, String>, +want: String) -> Maybe<&2, String>:
  match parts:
    case Nil{}:
      None{}
    case Con{name, rest}:
      Http.header_if(String.eq(name, want), rest)

# The first query parameter named `want`, or "".
def Http.param(items: List<&2, String>, +want: String) -> String:
  match items:
    case Nil{}:
      ""
    case Con{item, +rest}:
      Http.header_pick(Http.param_value(String.split(item, '='), want),
        rest, want, more => key => Http.param(rest, key))

def Http.second(parts: List<&2, String>) -> String:
  match parts:
    case Con{_, Con{x, _}}:
      x
    case _:
      ""

def Http.first(parts: List<&2, String>) -> String:
  match parts:
    case Con{x, _}:
      x
    case _:
      ""

def Http.camera_number(digits: String) -> Maybe<&2, U32>:
  U32.read(digits)

def Http.route_camera(number: Maybe<&2, U32>, is_stream: Bool) -> Route:
  match number is_stream:
    case None{} _:
      NotFound{}
    case Some{n} True{}:
      Stream{n}
    case Some{n} False{}:
      Page{n}

def Http.stream_or_page(+name: String, is_stream: Bool) -> Route:
  match is_stream:
    case True{}:
      Http.route_camera(Http.camera_number(String.take(name, Nat.sub(String.length(name), 5n))), True{})
    case False{}:
      Http.route_camera(Http.camera_number(name), False{})

def Http.route_sharing(is_sharing: Bool, +share: String) -> Route:
  match is_sharing:
    case True{}:
      SetSharing{String.eq(share, "on")}
    case False{}:
      NotFound{}

def Http.route_root(is_root: Bool, +path: String, +share: String) -> Route:
  match is_root:
    case True{}:
      Index{}
    case False{}:
      Http.route_sharing(String.eq(path, "/sharing"), share)

# View names: 1 to 32 letters, digits, '-' or '_'. They appear in pages, so
# nothing else is accepted, from URLs or from View.publish.
def Http.name_char_ok(+c: Char) -> Bool:
  +x = Char.to_u32(c)
  Bool.or(Char.is_alpha(c), Bool.or(Char.is_digit(c), Bool.or(U32.is_eq(x, 45), U32.is_eq(x, 95))))

def Http.name_chars_ok(chars: List<&2, Char>) -> Bool:
  match chars:
    case Nil{}:
      True{}
    case Con{+c, rest}:
      Bool.and(Http.name_char_ok(c), Http.name_chars_ok(rest))

def Http.name_ok(+name: String) -> Bool:
  +n = String.length(name)
  Bool.and(Bool.and(Nat.is_lt(0n, n), Nat.is_le(n, 32n)), Http.name_chars_ok(String.to_list(name)))

def Http.view_named(+name: String, is_stream: Bool, ok: Bool) -> Route:
  match is_stream ok:
    case _ False{}:
      NotFound{}
    case True{} True{}:
      ViewStream{name}
    case False{} True{}:
      ViewPage{name}

def Http.view_route(+name: String, is_stream: Bool) -> Route:
  match is_stream:
    case True{}:
      +bare = String.take(name, Nat.sub(String.length(name), 5n))
      Http.view_named(bare, True{}, Http.name_ok(bare))
    case False{}:
      Http.view_named(name, False{}, Http.name_ok(name))

def Http.route_view(is_view: Bool, +path: String, +share: String) -> Route:
  match is_view:
    case True{}:
      +name = String.drop(path, 6n)
      Http.view_route(name, String.ends_with(name, ".mjpg"))
    case False{}:
      Http.route_root(String.eq(path, "/"), path, share)

def Http.route_plain(+path: String, +share: String) -> Route:
  Http.route_view(String.starts_with(path, "/view/"), path, share)

def Http.route_under(+path: String, under_camera: Bool, +share: String) -> Route:
  match under_camera:
    case True{}:
      +name = String.drop(path, 8n)
      Http.stream_or_page(name, String.ends_with(name, ".mjpg"))
    case False{}:
      Http.route_plain(path, share)

def Http.route(+path: String, +share: String) -> Route:
  Http.route_under(path, String.starts_with(path, "/camera/"), share)

# Parses the request line, headers and query of a raw HTTP request.
def Http.parse(raw: String) -> Request & Route:
  +lines = String.lines(raw)
  +request_line = String.split(Http.trim_cr(Http.first(lines)), ' ')
  +target = String.split(Http.second(request_line), '?')
  +path = Http.first(target)
  +query = String.split(Http.second(target), '&')
  +share = Http.param(query, "share")
  (Request{Http.first(request_line), path, Http.header(lines, "host"),
    Http.header(lines, "origin"), Http.header(lines, "sec-fetch-site"),
    Http.param(query, "token"), Http.param(query, "csrf"), share},
    Http.route(path, share))

def Http.route_part(pair: Request & Route) -> Route:
  (req, route) = pair
  route

# Just the route of a raw request.
def Http.route_of(raw: String) -> Route:
  Http.route_part(Http.parse(raw))
