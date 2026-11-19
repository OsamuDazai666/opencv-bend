import Base
import ../src/image.bend as I
import ../src/imgproc.bend as IP
import ../src/jpeg.bend as J
import ../src/draw.bend as D

# Usage: bench [720|4k|8k]
# Times every operation on a synthetic image (no camera): creation, a
# pattern fill, invert, threshold, flip, rectangle, histogram, crop, grey,
# and JPEG encoding. Run with +RTS --threads N to compare core counts.

def B.pattern_px(+k: U32, +x: U32, +y: U32, +p: U32) -> U32:
  I.Pixel.pack((x .&. 255 : U32), (y .&. 255 : U32), ((x + y) .&. 255 : U32), 255)

def B.pattern(mat: I.Mat) -> I.Mat:
  IP.Mat.map_xy(~U32, ~(k => x => y => p => B.pattern_px(k, x, y, p)), 0, mat)

def B.sample_got(got: I.Mat & U32, +acc: U32) -> I.Mat & U32:
  (mat, +p) = got
  (mat, (acc + p : U32))

def B.sample(mat: I.Mat, +acc: U32) -> I.Mat & U32:
  B.sample_got(I.Mat.get(mat, 5, 5), acc)

def B.seg_len(seg: Array<U32> & U32) -> U32:
  (a, n) = seg
  n

def B.seg_bytes(segs: List<(Array<U32> & U32)>) -> U32:
  match segs:
    case Nil{}:
      0
    case Con{seg, rest}:
      (B.seg_len(seg) + B.seg_bytes(rest) : U32)

def B.jpeg_done(encoded: I.Mat & List<(Array<U32> & U32)>, +acc: U32) -> I.Mat & U32:
  (mat, segs) = encoded
  (mat, (acc + B.seg_bytes(segs) : U32))

def B.hist_done(pair: I.Mat & Array<U32>, +acc: U32) -> I.Mat & U32:
  (mat, counts) = pair
  (mat, (acc + IP.Hist.bin(counts, 100) : U32))

def B.crop_done(pair: I.Mat & Maybe<&1, I.Mat>, +acc: U32) -> I.Mat & U32:
  (mat, crop) = pair
  (mat, (acc + IP.Mat.crop_pixel(crop, 3, 3) : U32))

def B.crop_at(mat: I.Mat, size: U32 & U32, +acc: U32) -> I.Mat & U32:
  (+w, +h) = size
  B.crop_done(IP.Mat.crop(mat, (w / 4 : U32), (h / 4 : U32), (w / 2 : U32), (h / 2 : U32)), acc)

def B.crop_sized(sized: I.Mat & (U32 & U32), +acc: U32) -> I.Mat & U32:
  (mat, size) = sized
  B.crop_at(mat, size, acc)

def B.crop_quarter(mat: I.Mat, +acc: U32) -> I.Mat & U32:
  B.crop_sized(I.Mat.size(mat), acc)

# op: 0 invert, 1 threshold, 2 flip, 3 rectangle (half the image, filled),
# 4 histogram, 5 crop (centre quarter), 6 grey, 7 JPEG, 8 pattern fill.
def B.run_if(a: Bool, b: Bool, c: Bool, d: Bool, e: Bool, f: Bool, g: Bool, h: Bool, mat: I.Mat, +acc: U32) ->
  I.Mat & U32:
  match a b c d e f g h:
    case True{} _ _ _ _ _ _ _:
      B.sample(IP.Mat.invert(mat), acc)
    case False{} True{} _ _ _ _ _ _:
      B.sample(IP.Mat.threshold(mat, 128, 255), acc)
    case False{} False{} True{} _ _ _ _ _:
      B.sample(IP.Mat.flip_x(mat), acc)
    case False{} False{} False{} True{} _ _ _ _:
      B.sample(IP.Mat.rectangle(mat, IP.Rect{0, 0, 3839, 2159, 4278190335, 0}), acc)
    case False{} False{} False{} False{} True{} _ _ _:
      B.hist_done(IP.Mat.histogram(mat), acc)
    case False{} False{} False{} False{} False{} True{} _ _:
      B.crop_quarter(mat, acc)
    case False{} False{} False{} False{} False{} False{} True{} _:
      B.sample(I.Mat.gray(mat), acc)
    case False{} False{} False{} False{} False{} False{} False{} True{}:
      B.jpeg_done(J.Jpeg.encode(mat), acc)
    case False{} False{} False{} False{} False{} False{} False{} False{}:
      B.sample(B.pattern(mat), acc)

def B.shrink_k(+w: U32) -> U32:
  IP.U.pick(U32.is_gt(w, 3840), 4, IP.U.pick(U32.is_gt(w, 1920), 2, 1))

def B.jpeg_size(encoded: I.Mat & List<(Array<U32> & U32)>) -> U32:
  (mat, segs) = encoded
  B.seg_bytes(segs)

def B.small_value(small: Maybe<&1, I.Mat>, encode: Bool) -> U32:
  match small encode:
    case None{} _:
      0
    case Some{s} True{}:
      B.jpeg_size(J.Jpeg.encode(s))
    case Some{s} False{}:
      I.Mat.pixel_at(s, 3, 3)

def B.down_done(pair: I.Mat & Maybe<&1, I.Mat>, +acc: U32, +encode: Bool) -> I.Mat & U32:
  (mat, small) = pair
  (mat, (acc + B.small_value(small, encode) : U32))

def B.down_at(mat: I.Mat, size: U32 & U32, +acc: U32, +encode: Bool) -> I.Mat & U32:
  (+w, +h) = size
  B.down_done(IP.Mat.downscale(mat, B.shrink_k(w)), acc, encode)

def B.down_sized(sized: I.Mat & (U32 & U32), +acc: U32, +encode: Bool) -> I.Mat & U32:
  (mat, size) = sized
  B.down_at(mat, size, acc, encode)

# A grid of n x n boxes, 300 x 200 each, 700 px apart.
def B.grid(n: Nat, +i: U32, +side: U32) -> List<&2, D.Shape>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      Con{D.Draw.box(((i % side) * 700 + 100 : U32), ((i / side) * 420 + 60 : U32), 300, 200, D.Draw.blue()),
        B.grid(p, (i + 1 : U32), side)}

def B.run_draw(one: Bool, mat: I.Mat, +acc: U32) -> I.Mat & U32:
  match one:
    case True{}:
      B.sample(D.Mat.draw(mat, D.Draw.box(1000, 800, 3000, 2000, D.Draw.blue())), acc)
    case False{}:
      B.sample(D.Mat.draw_all(B.grid(100n, 0, 10), mat), acc)

def B.run_extra2(drawing: Bool, +op: U32, mat: I.Mat, +acc: U32) -> I.Mat & U32:
  match drawing:
    case True{}:
      B.run_draw(U32.is_eq(op, 11), mat, acc)
    case False{}:
      B.down_sized(I.Mat.size(mat), acc, U32.is_eq(op, 10))

def B.run_extra(extra: Bool, +op: U32, mat: I.Mat, +acc: U32) -> I.Mat & U32:
  match extra:
    case True{}:
      B.run_extra2(U32.is_ge(op, 11), op, mat, acc)
    case False{}:
      B.run_if(U32.is_eq(op, 0), U32.is_eq(op, 1), U32.is_eq(op, 2), U32.is_eq(op, 3), U32.is_eq(op, 4),
        U32.is_eq(op, 5), U32.is_eq(op, 6), U32.is_eq(op, 7), mat, acc)

# 9: downscale to about 1920 wide; 10: that plus JPEG (the viewer's preview).
def B.run(+op: U32, mat: I.Mat, +acc: U32) -> I.Mat & U32:
  B.run_extra(U32.is_ge(op, 9), op, mat, acc)

def B.reps(n: Nat, +op: U32, state: I.Mat & U32) -> I.Mat & U32:
  match n:
    case 0n:
      state
    case 1n+p:
      (mat, +acc) = state
      B.reps(p, op, B.run(op, mat, acc))

def B.label_if(a: Bool, b: Bool, c: Bool, d: Bool, e: Bool, f: Bool, g: Bool, h: Bool) -> String:
  match a b c d e f g h:
    case True{} _ _ _ _ _ _ _:
      "invert      "
    case False{} True{} _ _ _ _ _ _:
      "threshold   "
    case False{} False{} True{} _ _ _ _ _:
      "flip_x      "
    case False{} False{} False{} True{} _ _ _ _:
      "rectangle   "
    case False{} False{} False{} False{} True{} _ _ _:
      "histogram   "
    case False{} False{} False{} False{} False{} True{} _ _:
      "crop 1/4    "
    case False{} False{} False{} False{} False{} False{} True{} _:
      "grey        "
    case False{} False{} False{} False{} False{} False{} False{} True{}:
      "jpeg encode "
    case False{} False{} False{} False{} False{} False{} False{} False{}:
      "pattern fill"

def B.label_plain(+op: U32) -> String:
  B.label_if(U32.is_eq(op, 0), U32.is_eq(op, 1), U32.is_eq(op, 2), U32.is_eq(op, 3), U32.is_eq(op, 4),
    U32.is_eq(op, 5), U32.is_eq(op, 6), U32.is_eq(op, 7))

def B.label_extra2(down: Bool, preview: Bool, +op: U32) -> String:
  match down preview:
    case True{} _:
      "downscale   "
    case False{} True{}:
      "preview+jpg "
    case False{} False{}:
      B.label_plain(op)

def B.label_draw(big: Bool, many: Bool, down: Bool, preview: Bool, +op: U32) -> String:
  match big many:
    case True{} _:
      "draw 1 box  "
    case False{} True{}:
      "draw 100 box"
    case False{} False{}:
      B.label_extra2(down, preview, op)

def B.label_extra(down: Bool, preview: Bool, +op: U32) -> String:
  B.label_draw(U32.is_eq(op, 11), U32.is_eq(op, 12), down, preview, op)

def B.label(+op: U32) -> String:
  B.label_extra(U32.is_eq(op, 9), U32.is_eq(op, 10), op)

def B.ms(+total: Nat, +reps: Nat) -> String:
  +hundredths = Nat.div(Nat.mul(total, 100n), reps)
  Nat.show(Nat.div(hundredths, 100n)) ++ "." ++ Nat.show(Nat.div(Nat.mod(hundredths, 100n), 10n)) ++
    Nat.show(Nat.mod(hundredths, 10n)) ++ " ms"

def B.report(+op: U32, +reps: Nat, +t0: Nat, +t1: Nat, result: I.Mat & U32) -> IO(I.Mat):
  (mat, +acc) = result
  do IO<I.Mat>:
    IO.print("  " ++ B.label(op) ++ "  " ++ B.ms(Nat.sub(t1, t0), reps) ++ "   (check " ++ U32.show((acc % 997 : U32)) ++ ")")
    return mat

def B.after(+op: U32, +reps: Nat, +t0: Nat, result: I.Mat & U32) -> IO(I.Mat):
  IO.bind(Nat, I.Mat, IO.now(), t1 => B.report(op, reps, t0, t1, result))

def B.time(mat: I.Mat, +op: U32, +reps: Nat) -> IO(I.Mat):
  do IO<I.Mat>:
    +t0 : Nat <- IO.now()
    result : I.Mat & U32 = B.reps(reps, op, (mat, 0))
    B.after(op, reps, t0, result)

def B.made(+t0: Nat, +t1: Nat, mat: I.Mat, +reps: Nat) -> IO(Unit):
  do IO<Unit>:
    IO.print("  create blank  " ++ B.ms(Nat.sub(t1, t0), 1n))
    m0 : I.Mat <- B.time(mat, 8, reps)
    m1 : I.Mat <- B.time(m0, 6, reps)
    m2 : I.Mat <- B.time(m1, 0, reps)
    m3 : I.Mat <- B.time(m2, 1, reps)
    m4 : I.Mat <- B.time(B.pattern(m3), 2, reps)
    m5 : I.Mat <- B.time(m4, 4, reps)
    m6 : I.Mat <- B.time(m5, 5, reps)
    m7 : I.Mat <- B.time(m6, 7, reps)
    m8 : I.Mat <- B.time(m7, 9, reps)
    m9 : I.Mat <- B.time(m8, 10, reps)
    m10 : I.Mat <- B.time(m9, 3, reps)
    m11 : I.Mat <- B.time(m10, 11, reps)
    m12 : I.Mat <- B.time(m11, 12, reps)
    return Unit{}

def B.created_sized(+t0: Nat, sized: I.Mat & (U32 & U32), +reps: Nat) -> IO(Unit):
  (mat, size) = sized
  IO.bind(Nat, Unit, IO.now(), t1 => B.made(t0, t1, mat, reps))

def B.created(+t0: Nat, mat: I.Mat, +reps: Nat) -> IO(Unit):
  B.created_sized(t0, I.Mat.size(mat), reps)

def B.size(+w: U32, +h: U32, +reps: Nat) -> IO(Unit):
  do IO<Unit>:
    IO.print(U32.show(w) ++ "x" ++ U32.show(h) ++ " (" ++ U32.show((w * h / 1000000 : U32)) ++ " Mpx), average of " ++ Nat.show(reps) ++ ":")
    +t0 : Nat <- IO.now()
    mat : I.Mat = I.Mat.blank(w, h, 4278190080)
    B.created(t0, mat, reps)

def B.pick(is720: Bool, is4k: Bool) -> IO(Unit):
  match is720 is4k:
    case True{} _:
      B.size(1280, 720, 20n)
    case False{} True{}:
      B.size(3840, 2160, 6n)
    case False{} False{}:
      B.size(7680, 4320, 3n)

def B.which(args: List<String>) -> IO(Unit):
  match args:
    case Con{_, Con{+arg, _}}:
      B.pick(String.eq(arg, "720"), String.eq(arg, "4k"))
    case _:
      B.pick(False{}, True{})

def main() -> IO(Unit):
  IO.bind(List<String>, Unit, IO.args(), args => B.which(args))
