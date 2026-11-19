import Base

# Choosing a camera mode. Native code only lists the modes a camera offers
# and applies the one chosen here; the choice itself is pure Bend, so
# LAWS.bend can state what it picks.

# One capture mode: frame size and the highest frame rate it supports.
type Mode is Data:
  Mode{width: U32, height: U32, fps: U32}

# What the program asks for.
type Want is Data:
  Largest{}
  Size{width: U32, height: U32}

def Mode.pixels(mode: Mode) -> U32:
  match mode:
    case Mode{+w, +h, _}:
      (w * h : U32)

def Mode.fps(mode: Mode) -> U32:
  match mode:
    case Mode{_, _, fps}:
      fps

def Mode.has_size(mode: Mode, +w: U32, +h: U32) -> Bool:
  match mode:
    case Mode{mw, mh, _}:
      Bool.and(U32.is_eq(mw, w), U32.is_eq(mh, h))

# a beats b: more pixels, or as many pixels and a higher frame rate.
def Modes.beats(+a: Mode, +b: Mode) -> Bool:
  +pa = Mode.pixels(a)
  +pb = Mode.pixels(b)
  Bool.or(U32.is_gt(pa, pb), Bool.and(U32.is_eq(pa, pb), U32.is_gt(Mode.fps(a), Mode.fps(b))))

def Modes.keep(beats: Bool, +challenger: Mode, +champion: Mode) -> Mode:
  match beats:
    case True{}:
      challenger
    case False{}:
      champion

# The best of `champion` and every mode in `rest`; ties keep the earlier one.
def Modes.best_from(rest: List<&2, Mode>, +champion: Mode) -> Mode:
  match rest:
    case Nil{}:
      champion
    case Con{+m, tail}:
      Modes.best_from(tail, Modes.keep(Modes.beats(m, champion), m, champion))

def Modes.best(modes: List<&2, Mode>) -> Maybe<&2, Mode>:
  match modes:
    case Nil{}:
      None{}
    case Con{+m, tail}:
      Some{Modes.best_from(tail, m)}

def Modes.sized_keep(hit: Bool, +m: Mode, rest: List<&2, Mode>) -> List<&2, Mode>:
  match hit:
    case True{}:
      Con{m, rest}
    case False{}:
      rest

# Only the modes of exactly this size.
def Modes.sized(modes: List<&2, Mode>, +w: U32, +h: U32) -> List<&2, Mode>:
  match modes:
    case Nil{}:
      Nil{}
    case Con{+m, tail}:
      Modes.sized_keep(Mode.has_size(m, w, h), m, Modes.sized(tail, w, h))

# Largest: the most pixels, then the highest frame rate.
# Size: that exact size at its highest frame rate, or None if the camera lacks it.
def Modes.pick(want: Want, modes: List<&2, Mode>) -> Maybe<&2, Mode>:
  match want:
    case Largest{}:
      Modes.best(modes)
    case Size{+w, +h}:
      Modes.best(Modes.sized(modes, w, h))

def Mode.show(mode: Mode) -> String:
  match mode:
    case Mode{w, h, fps}:
      U32.show(w) ++ "x" ++ U32.show(h) ++ "@" ++ U32.show(fps)

def Modes.show(modes: List<&2, Mode>) -> String:
  match modes:
    case Nil{}:
      ""
    case Con{m, Nil{}}:
      Mode.show(m)
    case Con{m, tail}:
      Mode.show(m) ++ ", " ++ Modes.show(tail)

# Native code lists modes as flat numbers: width, height, fps, ...
def Modes.from_numbers(numbers: List<&2, U32>) -> List<&2, Mode>:
  match numbers:
    case Con{w, Con{h, Con{fps, rest}}}:
      Con{Mode{w, h, fps}, Modes.from_numbers(rest)}
    case _:
      Nil{}
