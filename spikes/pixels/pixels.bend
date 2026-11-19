import Base

# Spike: can Bend process camera pixels, and how fast?
# A native effect copies a padded 640x480 BGRA frame into an Array<U32>
# (one pixel per U32). Bend then sums each pixel's luma, sequentially and
# with parallel calls, and the result is compared with a plain C loop.
#
#   make spike && ./build/pixels +RTS --threads 8

def Spike.frame_native() -> IO(Array<U32>):
  import "./pixels.c"
  import "./pixels.js"

def Spike.native_native(+reps: U32) -> IO(U32 & U32):
  import "./pixels.c"
  import "./pixels.js"

def Spike.reps() -> Nat:
  30n

def Px.luma(+px: U32) -> U32:
  +b = (px .&. 255 : U32)
  +g = ((px >> 8n) .&. 255 : U32)
  +r = ((px >> 16n) .&. 255 : U32)
  +y = (77 * r + 150 * g + 29 * b : U32)
  (y >> 8n : U32)

def Px.sum_seq(a: Array<U32>) -> U32:
  match a:
    case ALeaf{v}:
      Px.luma(v)
    case ANode{xs, ys}:
      l = Px.sum_seq(xs)
      r = Px.sum_seq(ys)
      (l + r : U32)

# Splits in parallel for `depth` levels (2^depth tasks), then runs sequentially.
def Px.sum_par(+depth: Nat, a: Array<U32>) -> U32:
  match depth:
    case 0n:
      Px.sum_seq(a)
    case 1n+d:
      match a:
        case ALeaf{v}:
          Px.luma(v)
        case ANode{xs, ys}:
          l r = Px.sum_par(d, xs) Px.sum_par(d, ys)
          (l + r : U32)

def Spike.copy_loop(n: Nat, acc: U32) -> IO(U32):
  match n:
    case 0n:
      IO.pure(U32, acc)
    case 1n+p:
      do IO<U32>:
        a : Array<U32> <- Spike.frame_native()
        Spike.copy_loop(p, acc)

def Spike.seq_loop(n: Nat, acc: U32) -> IO(U32):
  match n:
    case 0n:
      IO.pure(U32, acc)
    case 1n+p:
      do IO<U32>:
        a : Array<U32> <- Spike.frame_native()
        Spike.seq_loop(p, Px.sum_seq(a))

def Spike.par_loop(n: Nat, +depth: Nat, acc: U32) -> IO(U32):
  match n:
    case 0n:
      IO.pure(U32, acc)
    case 1n+p:
      do IO<U32>:
        a : Array<U32> <- Spike.frame_native()
        Spike.par_loop(p, depth, Px.sum_par(depth, a))

def Spike.ms_per_frame(+total_ms: Nat) -> String:
  +tenths = Nat.div(Nat.mul(total_ms, 10n), Spike.reps())
  Nat.show(Nat.div(tenths, 10n)) ++ "." ++ Nat.show(Nat.mod(tenths, 10n)) ++ " ms/frame"

def Spike.report(+t0: Nat, +t1: Nat, +t2: Nat, +t3: Nat, +seq: U32, +par: U32,
  native: U32 & U32) -> String:
  (sum, +us) = native
  +native_us = Nat.div(U32.to_nat(us), Spike.reps())
  "frames: " ++ Nat.show(Spike.reps()) ++ " x 640x480 BGRA (stride 2624)\n" ++
    "copy into Array<U32>:     " ++ Spike.ms_per_frame(Nat.sub(t1, t0)) ++ "\n" ++
    "copy + Bend sum, serial:  " ++ Spike.ms_per_frame(Nat.sub(t2, t1)) ++
    "  (luma sum " ++ U32.show(seq) ++ ")\n" ++
    "copy + Bend sum, parallel:" ++ Spike.ms_per_frame(Nat.sub(t3, t2)) ++
    "  (luma sum " ++ U32.show(par) ++ ")\n" ++
    "plain C sum (no copy):    " ++ Nat.show(native_us) ++ " us/frame  (luma sum " ++
    U32.show(sum) ++ ")"

def main() -> IO(Unit):
  do IO<Unit>:
    t0 : Nat <- IO.now()
    copied : U32 <- Spike.copy_loop(Spike.reps(), 0)
    t1 : Nat <- IO.now()
    seq : U32 <- Spike.seq_loop(Spike.reps(), 0)
    t2 : Nat <- IO.now()
    par : U32 <- Spike.par_loop(Spike.reps(), 6n, 0)
    t3 : Nat <- IO.now()
    native : U32 & U32 <- Spike.native_native(30)
    IO.print(Spike.report(t0, t1, t2, t3, seq, par, native))
