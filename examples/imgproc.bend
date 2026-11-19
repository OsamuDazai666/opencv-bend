import Base
import ../src/videoio.bend as V
import ../src/image.bend as I
import ../src/imgproc.bend as IP
import ../src/viewer.bend as W
import ../src/draw.bend as D

# Usage: imgproc [frames]   live: publish views "threshold", "inverted",
#                           "mirror", "crop" and "boxes" of the camera
#        imgproc bench      time each operation on one 1280x720 frame

# --- The operations shown -----------------------------------------------------------

def Ip.green() -> U32:
  I.Pixel.pack(40, 220, 90, 255)

def Ip.crop_pick(image: I.Mat, crop: Maybe<&1, I.Mat>) -> I.Mat:
  match crop:
    case Some{c}:
      c
    case None{}:
      image

def Ip.crop_or(pair: I.Mat & Maybe<&1, I.Mat>) -> I.Mat:
  (image, crop) = pair
  Ip.crop_pick(image, crop)

def Ip.centre_crop_at(mat: I.Mat, size: U32 & U32) -> I.Mat:
  (+w, +h) = size
  Ip.crop_or(IP.Mat.crop(mat, (w / 4 : U32), (h / 4 : U32), (w / 2 : U32), (h / 2 : U32)))

def Ip.centre_crop_sized(sized: I.Mat & (U32 & U32)) -> I.Mat:
  (mat, size) = sized
  Ip.centre_crop_at(mat, size)

def Ip.centre_crop(mat: I.Mat) -> I.Mat:
  Ip.centre_crop_sized(I.Mat.size(mat))

# Modern overlays: translucent rounded boxes, a circle, a line, and a box
# partly past the right edge (drawing clips).
def Ip.boxes(mat: I.Mat) -> I.Mat:
  D.Mat.draw_all([D.Draw.box(100, 100, 400, 300, D.Draw.green()), D.Draw.box(620, 160, 300, 220, D.Draw.blue()),
    D.Draw.circle(400, 560, 80, D.Draw.violet()), D.Draw.line(560, 600, 820, 480, 4, D.Draw.amber()),
    D.Draw.box(1100, 480, 400, 300, D.Draw.red())], mat)

def Ip.apply_if(is0: Bool, is1: Bool, is2: Bool, is3: Bool, mat: I.Mat) -> I.Mat:
  match is0 is1 is2 is3:
    case True{} _ _ _:
      IP.Mat.threshold(I.Mat.gray(mat), 128, 255)
    case False{} True{} _ _:
      IP.Mat.invert(mat)
    case False{} False{} True{} _:
      IP.Mat.flip_x(mat)
    case False{} False{} False{} True{}:
      Ip.centre_crop(mat)
    case False{} False{} False{} False{}:
      Ip.boxes(mat)

# 0 threshold, 1 inverted, 2 mirror, 3 crop, 4 boxes.
def Ip.apply(+op: U32, mat: I.Mat) -> I.Mat:
  Ip.apply_if(U32.is_eq(op, 0), U32.is_eq(op, 1), U32.is_eq(op, 2), U32.is_eq(op, 3), mat)

def Ip.name_if(is0: Bool, is1: Bool, is2: Bool, is3: Bool) -> String:
  match is0 is1 is2 is3:
    case True{} _ _ _:
      "threshold"
    case False{} True{} _ _:
      "inverted"
    case False{} False{} True{} _:
      "mirror"
    case False{} False{} False{} True{}:
      "crop"
    case False{} False{} False{} False{}:
      "boxes"

def Ip.name(+op: U32) -> String:
  Ip.name_if(U32.is_eq(op, 0), U32.is_eq(op, 1), U32.is_eq(op, 2), U32.is_eq(op, 3))

# --- Live: each view from its own copy of the frame -------------------------------

def Ip.published(done: I.Mat & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (mat, result) = done
  IO.pure(Unit, Unit{})

def Ip.show_mat(+op: U32, result: Result<&1, &1, U32 & String, I.Mat>) -> IO(Unit):
  match result:
    case Fail{_}:
      IO.pure(Unit, Unit{})
    case Done{mat}:
      IO.bind(I.Mat & Result<&1, &1, U32 & String, Unit>, Unit, W.View.publish(Ip.name(op), Ip.apply(op, mat)),
        done => Ip.published(done))

def Ip.show_after(+op: U32, converted: V.Frame & Result<&1, &1, U32 & String, I.Mat>) -> IO(V.Frame):
  (frame, result) = converted
  do IO<V.Frame>:
    Ip.show_mat(op, result)
    return frame

def Ip.show(frame: V.Frame, +op: U32) -> IO(V.Frame):
  IO.bind(V.Frame & Result<&1, &1, U32 & String, I.Mat>, V.Frame, V.Frame.to_mat(frame), converted =>
    Ip.show_after(op, converted))

def Ip.show_all(frame: V.Frame) -> IO(V.Frame):
  do IO<V.Frame>:
    f0 : V.Frame <- Ip.show(frame, 0)
    f1 : V.Frame <- Ip.show(f0, 1)
    f2 : V.Frame <- Ip.show(f1, 2)
    f3 : V.Frame <- Ip.show(f2, 3)
    f4 : V.Frame <- Ip.show(f3, 4)
    return f4

def Ip.on_read(capture: V.Capture, result: Result<&1, &1, U32 & String, V.Frame>, next: V.Capture -> IO(Unit)) ->
  IO(Unit):
  match result:
    case Fail{_}:
      next(capture)
    case Done{frame}:
      do IO<Unit>:
        done : V.Frame <- Ip.show_all(frame)
        _ : Result<&1, &1, U32 & String, Unit> <- V.Frame.release(done)
        next(capture)

def Ip.after_read(pair: V.Capture & Result<&1, &1, U32 & String, V.Frame>, next: V.Capture -> IO(Unit)) -> IO(Unit):
  (capture, result) = pair
  Ip.on_read(capture, result, next)

def Ip.loop(n: Nat, capture: V.Capture) -> IO(Unit):
  match n:
    case 0n:
      do IO<Unit>:
        _ : Result<&1, &1, U32 & String, Unit> <- V.VideoCapture.release(capture)
        return Unit{}
    case 1n+p:
      IO.bind(V.Capture & Result<&1, &1, U32 & String, V.Frame>, Unit, V.VideoCapture.read(capture, 2000), pair =>
        Ip.after_read(pair, next => Ip.loop(p, next)))

# --- Bench: each operation 50 times on one frame ------------------------------------

def Ip.add_bin(pair: I.Mat & Array<U32>, +acc: U32) -> I.Mat & U32:
  (mat, counts) = pair
  (mat, (acc + IP.Hist.bin(counts, 128) : U32))

def Ip.keep_after_crop(pair: I.Mat & Maybe<&1, I.Mat>, +acc: U32) -> I.Mat & U32:
  (mat, crop) = pair
  (mat, (acc + IP.Mat.crop_pixel(crop, 10, 10) : U32))

def Ip.add_pixel_got(got: I.Mat & U32, +acc: U32) -> I.Mat & U32:
  (mat, +p) = got
  (mat, (acc + p : U32))

def Ip.add_pixel(mat: I.Mat, +acc: U32) -> I.Mat & U32:
  Ip.add_pixel_got(I.Mat.get(mat, 7, 7), acc)

def Ip.bench_map_if(a: Bool, b: Bool, c: Bool, d: Bool, e: Bool, mat: I.Mat) -> I.Mat:
  match a b c d e:
    case True{} _ _ _ _:
      IP.Mat.invert(mat)
    case False{} True{} _ _ _:
      IP.Mat.threshold(mat, 128, 255)
    case False{} False{} True{} _ _:
      IP.Mat.fill(mat, 4278190080)
    case False{} False{} False{} True{} _:
      IP.Mat.flip_x(mat)
    case False{} False{} False{} False{} True{}:
      IP.Mat.rectangle(mat, IP.Rect{100, 100, 900, 600, Ip.green(), 6})
    case False{} False{} False{} False{} False{}:
      IP.Mat.rectangle(mat, IP.Rect{100, 100, 900, 600, Ip.green(), 0})

# 10 invert, 11 threshold, 12 fill, 13 flip, 14 rectangle outline, 15 filled rectangle.
def Ip.bench_map(+op: U32, mat: I.Mat) -> I.Mat:
  Ip.bench_map_if(U32.is_eq(op, 10), U32.is_eq(op, 11), U32.is_eq(op, 12), U32.is_eq(op, 13), U32.is_eq(op, 14), mat)

def Ip.bench_if(is_hist: Bool, is_crop: Bool, +op: U32, mat: I.Mat, +acc: U32) -> I.Mat & U32:
  match is_hist is_crop:
    case True{} _:
      Ip.add_bin(IP.Mat.histogram(mat), acc)
    case False{} True{}:
      Ip.keep_after_crop(IP.Mat.crop(mat, 320, 180, 640, 360), acc)
    case False{} False{}:
      Ip.add_pixel(Ip.bench_map(op, mat), acc)

def Ip.bench_go(n: Nat, +op: U32, state: I.Mat & U32) -> I.Mat & U32:
  match n:
    case 0n:
      state
    case 1n+p:
      (mat, +acc) = state
      Ip.bench_go(p, op, Ip.bench_if(U32.is_eq(op, 20), U32.is_eq(op, 21), op, mat, acc))

def Ip.bench_label_if(a: Bool, b: Bool, c: Bool, d: Bool, e: Bool, f: Bool, g: Bool) -> String:
  match a b c d e f g:
    case True{} _ _ _ _ _ _:
      "invert            "
    case False{} True{} _ _ _ _ _:
      "threshold         "
    case False{} False{} True{} _ _ _ _:
      "fill              "
    case False{} False{} False{} True{} _ _ _:
      "flip_x            "
    case False{} False{} False{} False{} True{} _ _:
      "rectangle outline "
    case False{} False{} False{} False{} False{} True{} _:
      "rectangle filled  "
    case False{} False{} False{} False{} False{} False{} True{}:
      "histogram         "
    case False{} False{} False{} False{} False{} False{} False{}:
      "crop 640x360      "

def Ip.bench_label(+op: U32) -> String:
  Ip.bench_label_if(U32.is_eq(op, 10), U32.is_eq(op, 11), U32.is_eq(op, 12), U32.is_eq(op, 13), U32.is_eq(op, 14),
    U32.is_eq(op, 15), U32.is_eq(op, 20))

def Ip.report(+op: U32, +t0: Nat, +t1: Nat, result: I.Mat & U32) -> IO(I.Mat):
  (mat, +acc) = result
  +hundredths = Nat.div(Nat.mul(Nat.sub(t1, t0), 100n), 50n)
  do IO<I.Mat>:
    IO.print(Ip.bench_label(op) ++ Nat.show(Nat.div(hundredths, 100n)) ++ "." ++
      Nat.show(Nat.div(Nat.mod(hundredths, 100n), 10n)) ++ Nat.show(Nat.mod(hundredths, 10n)) ++
      " ms   (check " ++ U32.show((acc % 1000 : U32)) ++ ")")
    return mat

def Ip.time_after(+op: U32, +t0: Nat, result: I.Mat & U32) -> IO(I.Mat):
  IO.bind(Nat, I.Mat, IO.now(), t1 => Ip.report(op, t0, t1, result))

def Ip.time_op(mat: I.Mat, +op: U32) -> IO(I.Mat):
  do IO<I.Mat>:
    +t0 : Nat <- IO.now()
    result : I.Mat & U32 = Ip.bench_go(50n, op, (mat, 0))
    Ip.time_after(op, t0, result)

def Ip.bench_mat(mat: I.Mat) -> IO(Unit):
  do IO<Unit>:
    IO.print("1280x720, average of 50 runs:")
    m1 : I.Mat <- Ip.time_op(mat, 10)
    m2 : I.Mat <- Ip.time_op(m1, 11)
    m3 : I.Mat <- Ip.time_op(m2, 13)
    m4 : I.Mat <- Ip.time_op(m3, 14)
    m5 : I.Mat <- Ip.time_op(m4, 15)
    m6 : I.Mat <- Ip.time_op(m5, 20)
    m7 : I.Mat <- Ip.time_op(m6, 21)
    m8 : I.Mat <- Ip.time_op(m7, 12)
    return Unit{}

def Ip.bench_result(result: Result<&1, &1, U32 & String, I.Mat>) -> IO(Unit):
  match result:
    case Fail{_}:
      IO.print_err("to_mat failed")
    case Done{mat}:
      Ip.bench_mat(mat)

def Ip.bench_converted(capture: V.Capture, converted: V.Frame & Result<&1, &1, U32 & String, I.Mat>) -> IO(Unit):
  (frame, result) = converted
  do IO<Unit>:
    _ : Result<&1, &1, U32 & String, Unit> <- V.Frame.release(frame)
    Ip.bench_result(result)
    _ : Result<&1, &1, U32 & String, Unit> <- V.VideoCapture.release(capture)
    return Unit{}

def Ip.bench_frame(capture: V.Capture, result: Result<&1, &1, U32 & String, V.Frame>) -> IO(Unit):
  match result:
    case Fail{_}:
      IO.print_err("read failed")
    case Done{frame}:
      IO.bind(V.Frame & Result<&1, &1, U32 & String, I.Mat>, Unit, V.Frame.to_mat(frame), converted =>
        Ip.bench_converted(capture, converted))

def Ip.bench_read(pair: V.Capture & Result<&1, &1, U32 & String, V.Frame>) -> IO(Unit):
  (capture, result) = pair
  Ip.bench_frame(capture, result)

# --- main -----------------------------------------------------------------------------

def Ip.start(capture: V.Capture, bench: Bool, +frames: Nat) -> IO(Unit):
  match bench:
    case True{}:
      IO.bind(V.Capture & Result<&1, &1, U32 & String, V.Frame>, Unit, V.VideoCapture.read(capture, 2000), pair =>
        Ip.bench_read(pair))
    case False{}:
      Ip.loop(frames, capture)

def Ip.opened(result: Result<&1, &1, U32 & String, V.Capture>, +bench: Bool, +frames: Nat) -> IO(Unit):
  match result:
    case Fail{(code, message)}:
      do IO<Unit>:
        IO.print_err("Camera error " ++ U32.show(code) ++ ": " ++ message)
        IO.exit(1)
    case Done{capture}:
      Ip.start(capture, bench, frames)

def Ip.pick(parsed: Maybe<&2, Nat>, fallback: Nat) -> Nat:
  match parsed:
    case Some{n}:
      n
    case None{}:
      fallback

def Ip.option(+arg: String, parsed: Bool & Nat) -> Bool & Nat:
  (bench, frames) = parsed
  (Bool.or(String.eq(arg, "bench"), bench), Ip.pick(Nat.read(arg), frames))

def Ip.options(args: List<String>) -> Bool & Nat:
  match args:
    case Nil{}:
      (False{}, 4294967295n)
    case Con{+arg, rest}:
      Ip.option(arg, Ip.options(rest))

def Ip.main(options: Bool & Nat) -> IO(Unit):
  (+bench, +frames) = options
  IO.bind(Result<&1, &1, U32 & String, V.Capture>, Unit, V.VideoCapture.open(0), opened =>
    Ip.opened(opened, bench, frames))

def main() -> IO(Unit):
  IO.bind(List<String>, Unit, IO.args(), args => Ip.main(Ip.options(args)))
