import Base
import ../src/videoio.bend as V
import ../src/image.bend as I
import ../src/jpeg.bend as J
import ../src/bytes.bend as B

# Usage: jpeg [out.jpg] [source.ppm] [noisy]
# "noisy" scrambles every pixel first (a near worst case for JPEG).
# Encodes one camera frame with the pure-Bend JPEG encoder, writes it, writes
# the same frame losslessly as a PPM for comparison, then times 30 encodes.

def Ex.fail(+what: String, error: U32 & String) -> IO(Unit):
  (code, message) = error
  IO.print_err(what ++ " failed (" ++ U32.show(code) ++ "): " ++ message)

def Ex.written_result(+path: String, result: Result<&1, &1, U32 & String, U32>) -> IO(Unit):
  match result:
    case Fail{error}:
      Ex.fail("writing " ++ path, error)
    case Done{+bytes}:
      IO.print("wrote " ++ path ++ " (" ++ U32.show(bytes) ++ " bytes)")

def Ex.written(+path: String, done: List<(Array<U32> & U32)> & Result<&1, &1, U32 & String, U32>) -> IO(Unit):
  (segs, result) = done
  Ex.written_result(path, result)

def Ex.write(+path: String, encoded: I.Mat & List<(Array<U32> & U32)>) -> IO(I.Mat):
  (mat, segs) = encoded
  do IO<I.Mat>:
    done : List<(Array<U32> & U32)> & Result<&1, &1, U32 & String, U32> <- B.Bytes.write_file(path, segs)
    Ex.written(path, done)
    return mat

def Ex.seg_len(seg: Array<U32> & U32) -> U32:
  (array, n) = seg
  n

def Ex.seg_bytes(segs: List<(Array<U32> & U32)>) -> U32:
  match segs:
    case Nil{}:
      0
    case Con{seg, rest}:
      (Ex.seg_len(seg) + Ex.seg_bytes(rest) : U32)

def Ex.time_step(encoded: I.Mat & List<(Array<U32> & U32)>, +acc: U32) -> I.Mat & U32:
  (mat, segs) = encoded
  (mat, (acc + Ex.seg_bytes(segs) : U32))

# Encodes n times, adding up the bytes produced (so no encode can be skipped).
def Ex.time_go(n: Nat, state: I.Mat & U32) -> I.Mat & U32:
  match n:
    case 0n:
      state
    case 1n+p:
      (mat, +acc) = state
      Ex.time_go(p, Ex.time_step(J.Jpeg.encode(mat), acc))

def Ex.timed(+t0: Nat, +t1: Nat, result: I.Mat & U32) -> IO(Unit):
  (mat, +bytes) = result
  +total = Nat.sub(t1, t0)
  IO.print("pure-Bend JPEG encode (1280x720 4:2:0, quality 75): " ++ Nat.show(Nat.div(total, 30n)) ++ "." ++
    Nat.show(Nat.div(Nat.mul(Nat.mod(total, 30n), 10n), 30n)) ++ " ms per frame (30 frames, " ++
    U32.show((bytes / 30 : U32)) ++ " bytes each)")

def Ex.after_time(+t0: Nat, result: I.Mat & U32) -> IO(Unit):
  IO.bind(Nat, Unit, IO.now(), t1 => Ex.timed(t0, t1, result))

# A cheap integer hash of the pixel: high-entropy content for benchmarking.
def Ex.noise(+p: U32) -> U32:
  +a = ((p .^. (p >> 13n)) * 2654435761 : U32)
  ((a .^. (a >> 16n)) .|. 4278190080 : U32)

# Camera warm-up stand-ins: all black, and very dark (a quarter of each channel).
def Ex.dark(+p: U32) -> U32:
  ((p >> 2n) .&. 1061109567 .|. 4278190080 : U32)

def Ex.mode_noisy(noisy: Bool, black: Bool, dark: Bool, mat: I.Mat) -> I.Mat:
  match noisy black dark:
    case True{} _ _:
      I.Mat.map(~(p => Ex.noise(p)), mat)
    case False{} True{} _:
      I.Mat.map(~(p => 4278190080), mat)
    case False{} False{} True{}:
      I.Mat.map(~(p => Ex.dark(p)), mat)
    case False{} False{} False{}:
      mat

def Ex.maybe_noisy(+mode: String, mat: I.Mat) -> I.Mat:
  Ex.mode_noisy(String.eq(mode, "noisy"), String.eq(mode, "black"), String.eq(mode, "dark"), mat)

def Ex.with_mat(+out: String, mat: I.Mat) -> IO(Unit):
  do IO<Unit>:
    kept : I.Mat <- Ex.write(out, J.Jpeg.encode(mat))
    t0 : Nat <- IO.now()
    result : I.Mat & U32 = Ex.time_go(30n, (kept, 0))
    Ex.after_time(t0, result)

def Ex.snap_result(+ppm: String, result: Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  match result:
    case Fail{error}:
      Ex.fail("snapshot", error)
    case Done{_}:
      IO.print("wrote " ++ ppm ++ " (lossless source)")

def Ex.snapped(+ppm: String, snap: V.Frame & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (frame, result) = snap
  do IO<Unit>:
    _ : Result<&1, &1, U32 & String, Unit> <- V.Frame.release(frame)
    Ex.snap_result(ppm, result)

def Ex.encode(+out: String, +noisy: String, result: Result<&1, &1, U32 & String, I.Mat>) -> IO(Unit):
  match result:
    case Fail{error}:
      Ex.fail("to_mat", error)
    case Done{mat}:
      Ex.with_mat(out, Ex.maybe_noisy(noisy, mat))

def Ex.converted(+out: String, +ppm: String, +noisy: String, converted: V.Frame & Result<&1, &1, U32 & String, I.Mat>,
  capture: V.Capture) -> IO(Unit):
  (frame, result) = converted
  do IO<Unit>:
    snap : V.Frame & Result<&1, &1, U32 & String, Unit> <- V.Frame.snapshot(frame, ppm)
    Ex.snapped(ppm, snap)
    Ex.encode(out, noisy, result)
    _ : Result<&1, &1, U32 & String, Unit> <- V.VideoCapture.release(capture)
    return Unit{}

def Ex.got_frame(+out: String, +ppm: String, +noisy: String, capture: V.Capture, result: Result<&1, &1, U32 & String, V.Frame>) ->
  IO(Unit):
  match result:
    case Fail{error}:
      Ex.fail("read", error)
    case Done{frame}:
      IO.bind(V.Frame & Result<&1, &1, U32 & String, I.Mat>, Unit, V.Frame.to_mat(frame), converted =>
        Ex.converted(out, ppm, noisy, converted, capture))

def Ex.got(+out: String, +ppm: String, +noisy: String, pair: V.Capture & Result<&1, &1, U32 & String, V.Frame>) -> IO(Unit):
  (capture, result) = pair
  Ex.got_frame(out, ppm, noisy, capture, result)

def Ex.opened(+out: String, +ppm: String, +noisy: String, result: Result<&1, &1, U32 & String, V.Capture>) -> IO(Unit):
  match result:
    case Fail{error}:
      Ex.fail("open", error)
    case Done{capture}:
      IO.bind(V.Capture & Result<&1, &1, U32 & String, V.Frame>, Unit, V.VideoCapture.read(capture, 2000), pair =>
        Ex.got(out, ppm, noisy, pair))

def Ex.paths(args: List<String>) -> String & (String & String):
  match args:
    case Con{_, Con{out, Con{ppm, Con{flag, _}}}}:
      (out, (ppm, flag))
    case Con{_, Con{out, Con{ppm, _}}}:
      (out, (ppm, "plain"))
    case Con{_, Con{out, _}}:
      (out, ("build/source.ppm", "plain"))
    case _:
      ("build/bend.jpg", ("build/source.ppm", "plain"))

def Ex.start_with(+out: String, rest: String & String) -> IO(Unit):
  (+ppm, +noisy) = rest
  IO.bind(Result<&1, &1, U32 & String, V.Capture>, Unit, V.VideoCapture.open(0), opened =>
    Ex.opened(out, ppm, noisy, opened))

def Ex.start(paths: String & (String & String)) -> IO(Unit):
  (+out, rest) = paths
  Ex.start_with(out, rest)

def main() -> IO(Unit):
  IO.bind(List<String>, Unit, IO.args(), args => Ex.start(Ex.paths(args)))
