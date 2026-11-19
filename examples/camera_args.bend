import Base

# Pure parts of the camera example: argument parsing and error bookkeeping.
# Kept apart from camera.bend (which uses foreign effects) so the laws can
# import them.

type CameraConfig is Data:
  CameraConfig{frames: Nat, snapshot: Maybe<&2, String>}

def Camera.default_frames() -> Nat:
  300n

def Camera.config_tail(frames: Nat, args: List<String>) -> Maybe<&2, CameraConfig>:
  match args:
    case Nil{}:
      Some{CameraConfig{frames, None{}}}
    case Con{path, Nil{}}:
      Some{CameraConfig{frames, Some{path}}}
    case _:
      None{}

def Camera.config_count(args: List<String>, parsed: Maybe<&2, Nat>) -> Maybe<&2, CameraConfig>:
  match parsed:
    case None{}:
      None{}
    case Some{0n}:
      None{}
    case Some{frames}:
      Camera.config_tail(frames, args)

def Camera.config_rest(args: List<String>) -> Maybe<&2, CameraConfig>:
  match args:
    case Nil{}:
      Some{CameraConfig{Camera.default_frames(), None{}}}
    case Con{count, rest}:
      Camera.config_count(rest, Nat.read(count))

# argv: program, then optional [frame-count] [snapshot.ppm].
def Camera.config(args: List<String>) -> Maybe<&2, CameraConfig>:
  match args:
    case Nil{}:
      None{}
    case Con{_, rest}:
      Camera.config_rest(rest)

# Keeps the earliest error when a later step (a release) also fails.
def Camera.first_error(prior: Maybe<&1, U32 & String>, later: U32 & String) ->
  Maybe<&1, U32 & String>:
  match prior:
    case None{}:
      Some{later}
    case Some{error}:
      Some{error}

def Camera.error_text(error: U32 & String) -> String:
  (code, message) = error
  "Camera error " ++ U32.show(code) ++ ": " ++ message

# Three-digit fractional part: 6 -> "006", 42 -> "042", 120 -> "120".
def Camera.pad3_by(+n: Nat, below_10: Bool, below_100: Bool) -> String:
  match below_10 below_100:
    case True{} _:
      "00" ++ Nat.show(n)
    case False{} True{}:
      "0" ++ Nat.show(n)
    case False{} False{}:
      Nat.show(n)

def Camera.pad3(+n: Nat) -> String:
  Camera.pad3_by(n, Nat.is_lt(n, 10n), Nat.is_lt(n, 100n))

# Frames per second with three decimals, from a frame count and milliseconds.
def Camera.fps_text(+frames: Nat, +duration_ms: Nat) -> String:
  +fps_milli = Nat.div(Nat.mul(frames, 1000000n), duration_ms)
  Nat.show(Nat.div(fps_milli, 1000n)) ++ "." ++ Camera.pad3(Nat.mod(fps_milli, 1000n)) ++ " FPS"
