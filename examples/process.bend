import Base
import ../src/videoio.bend as V
import ../src/image.bend as I
import ../src/viewer.bend as W

# Usage: process [frames]     process frames live; publish a grey copy as the
#                             view "gray"; print a summary every 30th frame
#        process bench        time copy-in + processing on one frame, 100 times
# Each frame becomes a Mat (bands of rows, processed in parallel): mean
# brightness, the centre pixel, and a grey copy whose brightness must match.

def Proc.show_px(+p: U32) -> String:
  "R" ++ U32.show(I.Pixel.r(p)) ++ " G" ++ U32.show(I.Pixel.g(p)) ++ " B" ++ U32.show(I.Pixel.b(p))

def Proc.describe_done(+sequence: U32, +mean: U32, +w: U32, +h: U32, +centre: U32, gray: I.Mat & U32) -> String:
  (mat, +gray_mean) = gray
  "frame " ++ U32.show(sequence) ++ ": " ++ U32.show(w) ++ "x" ++ U32.show(h) ++
    ", mean luma " ++ U32.show(mean) ++ ", centre " ++ Proc.show_px(centre) ++
    ", grey copy mean " ++ U32.show(gray_mean)

def Proc.describe_gray(+sequence: U32, +mean: U32, +w: U32, +h: U32, got: I.Mat & U32) -> String:
  (mat, +centre) = got
  Proc.describe_done(sequence, mean, w, h, centre, I.Mat.mean_luma(I.Mat.gray(mat)))

def Proc.describe_centre(+sequence: U32, +mean: U32, size: U32 & U32, mat: I.Mat) -> String:
  (+w, +h) = size
  Proc.describe_gray(sequence, mean, w, h, I.Mat.get(mat, (w / 2 : U32), (h / 2 : U32)))

def Proc.describe_size(+sequence: U32, +mean: U32, sized: I.Mat & (U32 & U32)) -> String:
  (mat, size) = sized
  Proc.describe_centre(sequence, mean, size, mat)

def Proc.describe_mean(+sequence: U32, measured: I.Mat & U32) -> String:
  (mat, +mean) = measured
  Proc.describe_size(sequence, mean, I.Mat.size(mat))

def Proc.describe(mat: I.Mat, +sequence: U32) -> String:
  Proc.describe_mean(sequence, I.Mat.mean_luma(mat))

def Proc.sequence(frame: V.Frame) -> V.Frame & U32:
  match frame:
    case V.Frame{id, w, h, s, +sequence, t}:
      (V.Frame{id, w, h, s, sequence, t}, sequence)

def Proc.print_result(+sequence: U32, result: Result<&1, &1, U32 & String, I.Mat>) -> IO(Unit):
  match result:
    case Fail{(code, message)}:
      IO.print_err("to_mat failed (" ++ U32.show(code) ++ "): " ++ message)
    case Done{mat}:
      IO.print(Proc.describe(mat, sequence))

def Proc.publish_result(result: Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  match result:
    case Done{_}:
      IO.pure(Unit, Unit{})
    case Fail{(code, message)}:
      IO.print_err("publish failed (" ++ U32.show(code) ++ "): " ++ message)

def Proc.published(published: I.Mat & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (mat, result) = published
  Proc.publish_result(result)

def Proc.publish_gray(result: Result<&1, &1, U32 & String, I.Mat>) -> IO(Unit):
  match result:
    case Fail{_}:
      IO.pure(Unit, Unit{})
    case Done{mat}:
      IO.bind(I.Mat & Result<&1, &1, U32 & String, Unit>, Unit, W.View.publish("gray", I.Mat.gray(mat)),
        published => Proc.published(published))

def Proc.maybe_print(+sequence: U32, due: Bool, result: Result<&1, &1, U32 & String, I.Mat>) -> IO(Unit):
  match due:
    case True{}:
      Proc.print_result(sequence, result)
    case False{}:
      IO.pure(Unit, Unit{})

def Proc.after_gray(capture: V.Capture, converted: V.Frame & Result<&1, &1, U32 & String, I.Mat>,
  next: V.Capture -> IO(Unit)) -> IO(Unit):
  (frame, result) = converted
  do IO<Unit>:
    _ : Result<&1, &1, U32 & String, Unit> <- V.Frame.release(frame)
    Proc.publish_gray(result)
    next(capture)

def Proc.after_mat(capture: V.Capture, +sequence: U32, converted: V.Frame & Result<&1, &1, U32 & String, I.Mat>,
  next: V.Capture -> IO(Unit)) -> IO(Unit):
  (frame, result) = converted
  do IO<Unit>:
    Proc.maybe_print(sequence, U32.is_eq((sequence % 30 : U32), 1), result)
    again : V.Frame & Result<&1, &1, U32 & String, I.Mat> <- V.Frame.to_mat(frame)
    Proc.after_gray(capture, again, next)

def Proc.with_sequence(capture: V.Capture, numbered: V.Frame & U32, next: V.Capture -> IO(Unit)) -> IO(Unit):
  (frame, +sequence) = numbered
  IO.bind(V.Frame & Result<&1, &1, U32 & String, I.Mat>, Unit, V.Frame.to_mat(frame), converted =>
    Proc.after_mat(capture, sequence, converted, next))

def Proc.on_read(capture: V.Capture, result: Result<&1, &1, U32 & String, V.Frame>, next: V.Capture -> IO(Unit)) ->
  IO(Unit):
  match result:
    case Fail{(code, message)}:
      do IO<Unit>:
        IO.print_err("read failed (" ++ U32.show(code) ++ "): " ++ message)
        next(capture)
    case Done{frame}:
      Proc.with_sequence(capture, Proc.sequence(frame), next)

def Proc.after_read(pair: V.Capture & Result<&1, &1, U32 & String, V.Frame>, next: V.Capture -> IO(Unit)) -> IO(Unit):
  (capture, result) = pair
  Proc.on_read(capture, result, next)

def Proc.loop(n: Nat, capture: V.Capture) -> IO(Unit):
  match n:
    case 0n:
      do IO<Unit>:
        _ : Result<&1, &1, U32 & String, Unit> <- V.VideoCapture.release(capture)
        return Unit{}
    case 1n+p:
      IO.bind(V.Capture & Result<&1, &1, U32 & String, V.Frame>, Unit, V.VideoCapture.read(capture, 2000), pair =>
        Proc.after_read(pair, next => Proc.loop(p, next)))

def Proc.work_done(+a: U32, measured: I.Mat & U32) -> U32:
  (mat, +b) = measured
  (a + b : U32)

def Proc.work_gray(measured: I.Mat & U32) -> U32:
  (mat, +a) = measured
  Proc.work_done(a, I.Mat.mean_luma(I.Mat.gray(mat)))

# --- bench: one frame, converted and processed 100 times ---------------------

def Proc.work(mat: I.Mat) -> U32:
  Proc.work_gray(I.Mat.mean_luma(mat))

def Proc.bench_value(result: Result<&1, &1, U32 & String, I.Mat>, copy_only: Bool) -> U32:
  match result copy_only:
    case Fail{_} _:
      0
    case Done{mat} True{}:
      0
    case Done{mat} False{}:
      Proc.work(mat)

def Proc.bench_one(converted: V.Frame & Result<&1, &1, U32 & String, I.Mat>, +copy_only: Bool) -> V.Frame & U32:
  (frame, result) = converted
  (frame, Proc.bench_value(result, copy_only))

def Proc.bench_next(stepped: V.Frame & U32, next: V.Frame -> U32 -> IO(V.Frame & U32)) -> IO(V.Frame & U32):
  (frame, value) = stepped
  next(frame, value)

def Proc.bench_loop(n: Nat, frame: V.Frame, +copy_only: Bool, acc: U32) -> IO(V.Frame & U32):
  match n:
    case 0n:
      IO.pure(V.Frame & U32, (frame, acc))
    case 1n+p:
      IO.bind(V.Frame & Result<&1, &1, U32 & String, I.Mat>, V.Frame & U32, V.Frame.to_mat(frame), converted =>
        Proc.bench_next(Proc.bench_one(converted, copy_only), next => value => Proc.bench_loop(p, next, copy_only, value)))

def Proc.bench_report(+label: String, +t0: Nat, +t1: Nat) -> IO(Unit):
  +hundredths = Nat.sub(t1, t0)
  IO.print(label ++ Nat.show(Nat.div(hundredths, 100n)) ++ "." ++
    Nat.show(Nat.div(Nat.mod(hundredths, 100n), 10n)) ++ Nat.show(Nat.mod(hundredths, 10n)) ++ " ms per frame")

def Proc.bench_close(capture: V.Capture, worked: V.Frame & U32) -> IO(Unit):
  (frame, _) = worked
  do IO<Unit>:
    _ : Result<&1, &1, U32 & String, Unit> <- V.Frame.release(frame)
    _ : Result<&1, &1, U32 & String, Unit> <- V.VideoCapture.release(capture)
    return Unit{}

def Proc.bench_finish(capture: V.Capture, copied: V.Frame & U32) -> IO(Unit):
  (frame, _) = copied
  do IO<Unit>:
    t1 : Nat <- IO.now()
    worked : V.Frame & U32 <- Proc.bench_loop(100n, frame, False{}, 0)
    t2 : Nat <- IO.now()
    Proc.bench_report("copy + mean + grey copy + mean (Bend):   ", t1, t2)
    Proc.bench_close(capture, worked)

def Proc.bench_frame(capture: V.Capture, frame: V.Frame) -> IO(Unit):
  do IO<Unit>:
    t0 : Nat <- IO.now()
    copied : V.Frame & U32 <- Proc.bench_loop(100n, frame, True{}, 0)
    t1 : Nat <- IO.now()
    Proc.bench_report("copy into Mat:                          ", t0, t1)
    Proc.bench_finish(capture, copied)

def Proc.bench_got(capture: V.Capture, result: Result<&1, &1, U32 & String, V.Frame>) -> IO(Unit):
  match result:
    case Fail{(code, message)}:
      IO.print_err("read failed (" ++ U32.show(code) ++ "): " ++ message)
    case Done{frame}:
      Proc.bench_frame(capture, frame)

def Proc.bench_read(pair: V.Capture & Result<&1, &1, U32 & String, V.Frame>) -> IO(Unit):
  (capture, result) = pair
  Proc.bench_got(capture, result)

def Proc.start(capture: V.Capture, bench: Bool, +frames: Nat) -> IO(Unit):
  match bench:
    case True{}:
      IO.bind(V.Capture & Result<&1, &1, U32 & String, V.Frame>, Unit, V.VideoCapture.read(capture, 2000), pair =>
        Proc.bench_read(pair))
    case False{}:
      Proc.loop(frames, capture)

# --- main ----------------------------------------------------------------------

def Proc.opened(result: Result<&1, &1, U32 & String, V.Capture>, +bench: Bool, +frames: Nat) -> IO(Unit):
  match result:
    case Fail{(code, message)}:
      do IO<Unit>:
        IO.print_err("Camera error " ++ U32.show(code) ++ ": " ++ message)
        IO.exit(1)
    case Done{capture}:
      Proc.start(capture, bench, frames)

def Proc.pick(parsed: Maybe<&2, Nat>, fallback: Nat) -> Nat:
  match parsed:
    case Some{n}:
      n
    case None{}:
      fallback

def Proc.option(+arg: String, parsed: Bool & Nat) -> Bool & Nat:
  (bench, frames) = parsed
  (Bool.or(String.eq(arg, "bench"), bench), Proc.pick(Nat.read(arg), frames))

def Proc.options(args: List<String>) -> Bool & Nat:
  match args:
    case Nil{}:
      (False{}, 5n)
    case Con{+arg, rest}:
      Proc.option(arg, Proc.options(rest))

def Proc.main(options: Bool & Nat) -> IO(Unit):
  (+bench, +frames) = options
  IO.bind(Result<&1, &1, U32 & String, V.Capture>, Unit, V.VideoCapture.open(0), opened =>
    Proc.opened(opened, bench, frames))

def main() -> IO(Unit):
  IO.bind(List<String>, Unit, IO.args(), args => Proc.main(Proc.options(args)))
