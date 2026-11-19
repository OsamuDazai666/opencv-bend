import Base
import ../src/videoio.bend as V
import ../src/viewer.bend as W
import ../src/modes.bend as M

# Usage: stream [seconds] [--share-lan] [--size=WIDTHxHEIGHT]
# Opens the default camera and reads frames the way an application would,
# while the browser viewer serves it. With no seconds it runs until Ctrl-C.
# --share-lan (or OPENCV_BEND_SHARE=lan) starts with sharing switched on.
# --size picks an exact camera mode; by default the largest one is used.

def Stream.pick(parsed: Maybe<&2, Nat>, fallback: Nat) -> Nat:
  match parsed:
    case Some{n}:
      n
    case None{}:
      fallback

def Stream.frames(+seconds: Nat) -> Nat:
  match seconds:
    case 0n:
      4294967295n
    case _:
      Nat.mul(seconds, 30n)

def Stream.on_frame(capture: V.Capture, result: Result<&1, &1, U32 & String, V.Frame>,
  next: V.Capture -> IO(V.Capture & Maybe<&1, U32 & String>)) ->
  IO(V.Capture & Maybe<&1, U32 & String>):
  match result:
    case Fail{error}:
      IO.pure(V.Capture & Maybe<&1, U32 & String>, (capture, Some{error}))
    case Done{frame}:
      IO.bind(Result<&1, &1, U32 & String, Unit>, V.Capture & Maybe<&1, U32 & String>,
        V.Frame.release(frame), released => next(capture))

def Stream.after_read(pair: V.Capture & Result<&1, &1, U32 & String, V.Frame>,
  next: V.Capture -> IO(V.Capture & Maybe<&1, U32 & String>)) ->
  IO(V.Capture & Maybe<&1, U32 & String>):
  (capture, result) = pair
  Stream.on_frame(capture, result, next)

def Stream.loop(remaining: Nat, capture: V.Capture) -> IO(V.Capture & Maybe<&1, U32 & String>):
  match remaining:
    case 0n:
      IO.pure(V.Capture & Maybe<&1, U32 & String>, (capture, None{}))
    case 1n+p:
      IO.bind(V.Capture & Result<&1, &1, U32 & String, V.Frame>, V.Capture & Maybe<&1, U32 & String>,
        V.VideoCapture.read(capture, 2000), pair => Stream.after_read(pair, next => Stream.loop(p, next)))

def Stream.finish_with(capture: V.Capture, error: Maybe<&1, U32 & String>) -> IO(Unit):
  match error:
    case None{}:
      do IO<Unit>:
        +token : U32 <- W.Viewer.capture_for(0)
        +encoded : U32 <- W.Viewer.encodes(token)
        _ : Result<&1, &1, U32 & String, Unit> <- V.VideoCapture.release(capture)
        IO.print("Done. The viewer encoded " ++ U32.show(encoded) ++ " JPEG frames.")
    case Some{(code, message)}:
      do IO<Unit>:
        _ : Result<&1, &1, U32 & String, Unit> <- V.VideoCapture.release(capture)
        IO.print_err("Camera error " ++ U32.show(code) ++ ": " ++ message)
        IO.exit(1)

def Stream.finish(pair: V.Capture & Maybe<&1, U32 & String>) -> IO(Unit):
  (capture, error) = pair
  Stream.finish_with(capture, error)

def Stream.run(opened: Result<&1, &1, U32 & String, V.Capture>, +frames: Nat) -> IO(Unit):
  match opened:
    case Fail{(code, message)}:
      do IO<Unit>:
        IO.print_err("Camera error " ++ U32.show(code) ++ ": " ++ message)
        IO.exit(1)
    case Done{capture}:
      IO.bind(V.Capture & Maybe<&1, U32 & String>, Unit, Stream.loop(frames, capture), pair =>
        Stream.finish(pair))

def Stream.maybe_share(share: Bool) -> IO(Unit):
  match share:
    case True{}:
      W.Viewer.share_on_lan(True{})
    case False{}:
      IO.pure(Unit, Unit{})

def Stream.size_of(width: Maybe<&2, U32>, height: Maybe<&2, U32>, fallback: M.Want) -> M.Want:
  match width height:
    case Some{w} Some{h}:
      M.Size{w, h}
    case _ _:
      fallback

def Stream.size_want(parts: List<&2, String>, fallback: M.Want) -> M.Want:
  match parts:
    case Con{w, Con{h, Nil{}}}:
      Stream.size_of(U32.read(w), U32.read(h), fallback)
    case _:
      fallback

def Stream.want_if(hit: Bool, +arg: String, fallback: M.Want) -> M.Want:
  match hit:
    case True{}:
      Stream.size_want(String.split(String.drop(arg, 7n), 'x'), fallback)
    case False{}:
      fallback

def Stream.option_rest(+arg: String, share: Bool, rest: Nat & M.Want) -> Bool & Nat & M.Want:
  (seconds, want) = rest
  (Bool.or(String.eq(arg, "--share-lan"), share), (Stream.pick(Nat.read(arg), seconds),
    Stream.want_if(String.starts_with(arg, "--size="), arg, want)))

def Stream.option(+arg: String, parsed: Bool & Nat & M.Want) -> Bool & Nat & M.Want:
  (share, rest) = parsed
  Stream.option_rest(arg, share, rest)

# (--share-lan given, the first numeric argument or 0, the wanted mode),
# in one pass over argv.
def Stream.options(args: List<String>) -> Bool & Nat & M.Want:
  match args:
    case Nil{}:
      (False{}, (0n, M.Largest{}))
    case Con{+arg, rest}:
      Stream.option(arg, Stream.options(rest))

def Stream.open(+seconds: Nat, want: M.Want) -> IO(Unit):
  IO.bind(Result<&1, &1, U32 & String, V.Capture>, Unit, V.VideoCapture.open_with(0, want),
    opened => Stream.run(opened, Stream.frames(seconds)))

def Stream.start_rest(share: Bool, rest: Nat & M.Want) -> IO(Unit):
  (+seconds, want) = rest
  do IO<Unit>:
    Stream.maybe_share(share)
    Stream.open(seconds, want)

def Stream.start(options: Bool & Nat & M.Want) -> IO(Unit):
  (share, rest) = options
  Stream.start_rest(share, rest)

def main() -> IO(Unit):
  IO.bind(List<String>, Unit, IO.args(), args => Stream.start(Stream.options(args)))
