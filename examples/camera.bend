import Base
import ../src/videoio.bend as V
import ../src/layout.bend as L
import ./camera_args.bend as A

# Usage: camera [frame-count] [snapshot.ppm]
# Opens the default camera, warms up for 30 frames (the last one is printed
# and optionally saved, after auto-exposure has settled), resets the
# counters, then times `frame-count` reads.

def Camera.warmup_frames() -> Nat:
  30n

def Camera.read_timeout_ms() -> U32:
  2000

def Camera.release_frame_result(capture: V.Capture, prior: Maybe<&1, U32 & String>,
  released: Result<&1, &1, U32 & String, Unit>) -> IO(V.Capture & Maybe<&1, U32 & String>):
  match released:
    case Done{_}:
      IO.pure(V.Capture & Maybe<&1, U32 & String>, (capture, prior))
    case Fail{error}:
      IO.pure(V.Capture & Maybe<&1, U32 & String>, (capture, A.Camera.first_error(prior, error)))

def Camera.release_frame(capture: V.Capture, frame: V.Frame,
  prior: Maybe<&1, U32 & String>) -> IO(V.Capture & Maybe<&1, U32 & String>):
  IO.bind(Result<&1, &1, U32 & String, Unit>, V.Capture & Maybe<&1, U32 & String>,
    V.Frame.release(frame), released => Camera.release_frame_result(capture, prior, released))

def Camera.announce(frame: V.Frame, enabled: Bool) -> IO(V.Frame):
  match frame enabled:
    case current False{}:
      IO.pure(V.Frame, current)
    case V.Frame{id, +width, +height, +stride, +sequence, +timestamp_ms} True{}:
      text = "Frame " ++ U32.show(sequence) ++ ": " ++ U32.show(width) ++ "x" ++
        U32.show(height) ++ " BGRA, stride " ++ U32.show(stride) ++
        ", timestamp " ++ U32.show(timestamp_ms) ++ " ms"
      do IO<V.Frame>:
        IO.print(text)
        return V.Frame{id, width, height, stride, sequence, timestamp_ms}

def Camera.layout_verdict(frame: V.Frame, ok: Bool) -> V.Frame & Maybe<&1, U32 & String>:
  match ok:
    case True{}:
      (frame, None{})
    case False{}:
      (frame, Some{{(22, "The frame stride is smaller than width x 4 bytes.") : U32 & String}})

# Every frame must satisfy the BGRA layout rule proven in PROOF.bend.
def Camera.check_layout(frame: V.Frame) -> V.Frame & Maybe<&1, U32 & String>:
  match frame:
    case V.Frame{id, +width, +height, +stride, +sequence, +timestamp_ms}:
      Camera.layout_verdict(V.Frame{id, width, height, stride, sequence, timestamp_ms},
        L.Layout.stride_ok(U32.to_nat(width), U32.to_nat(stride)))

def Camera.snapshot_result(capture: V.Capture, frame: V.Frame,
  result: Result<&1, &1, U32 & String, Unit>) -> IO(V.Capture & Maybe<&1, U32 & String>):
  match result:
    case Done{_}:
      Camera.release_frame(capture, frame, None{})
    case Fail{error}:
      Camera.release_frame(capture, frame, Some{error})

def Camera.snapshot_bound(capture: V.Capture,
  pair: V.Frame & Result<&1, &1, U32 & String, Unit>) -> IO(V.Capture & Maybe<&1, U32 & String>):
  (next, result) = pair
  Camera.snapshot_result(capture, next, result)

def Camera.after_snapshot(capture: V.Capture, frame: V.Frame,
  snapshot: Maybe<&2, String>) -> IO(V.Capture & Maybe<&1, U32 & String>):
  match snapshot:
    case None{}:
      Camera.release_frame(capture, frame, None{})
    case Some{path}:
      IO.bind(V.Frame & Result<&1, &1, U32 & String, Unit>,
        V.Capture & Maybe<&1, U32 & String>, V.Frame.snapshot(frame, path), pair =>
        Camera.snapshot_bound(capture, pair))

def Camera.after_check(capture: V.Capture, frame: V.Frame, snapshot: Maybe<&2, String>,
  announce: Bool, problem: Maybe<&1, U32 & String>) -> IO(V.Capture & Maybe<&1, U32 & String>):
  match problem:
    case Some{error}:
      Camera.release_frame(capture, frame, Some{error})
    case None{}:
      do IO<V.Capture & Maybe<&1, U32 & String>>:
        next : V.Frame <- Camera.announce(frame, announce)
        stepped : (V.Capture & Maybe<&1, U32 & String>) <- Camera.after_snapshot(capture, next, snapshot)
        return stepped

def Camera.after_layout(capture: V.Capture, snapshot: Maybe<&2, String>, announce: Bool,
  checked: V.Frame & Maybe<&1, U32 & String>) -> IO(V.Capture & Maybe<&1, U32 & String>):
  (frame, problem) = checked
  Camera.after_check(capture, frame, snapshot, announce, problem)

def Camera.after_read(capture: V.Capture, frame: V.Frame,
  snapshot: Maybe<&2, String>, announce: Bool) -> IO(V.Capture & Maybe<&1, U32 & String>):
  Camera.after_layout(capture, snapshot, announce, Camera.check_layout(frame))

def Camera.read_result(capture: V.Capture, snapshot: Maybe<&2, String>, announce: Bool,
  result: Result<&1, &1, U32 & String, V.Frame>) -> IO(V.Capture & Maybe<&1, U32 & String>):
  match result:
    case Fail{error}:
      IO.pure(V.Capture & Maybe<&1, U32 & String>, (capture, Some{error}))
    case Done{value}:
      Camera.after_read(capture, value, snapshot, announce)

def Camera.read_bound(snapshot: Maybe<&2, String>, announce: Bool,
  pair: V.Capture & Result<&1, &1, U32 & String, V.Frame>) ->
  IO(V.Capture & Maybe<&1, U32 & String>):
  (next, result) = pair
  Camera.read_result(next, snapshot, announce, result)

def Camera.step_done(rest: V.Capture -> Maybe<&1, U32 & String> ->
  IO(V.Capture & Maybe<&1, U32 & String>),
  stepped: V.Capture & Maybe<&1, U32 & String>) -> IO(V.Capture & Maybe<&1, U32 & String>):
  (current, error) = stepped
  rest(current, error)

def Camera.step(capture: V.Capture, snapshot: Maybe<&2, String>, announce: Bool,
  rest: V.Capture -> Maybe<&1, U32 & String> -> IO(V.Capture & Maybe<&1, U32 & String>)) ->
  IO(V.Capture & Maybe<&1, U32 & String>):
  do IO<V.Capture & Maybe<&1, U32 & String>>:
    read_io : V.Capture & Result<&1, &1, U32 & String, V.Frame> <- V.VideoCapture.read(capture, Camera.read_timeout_ms())
    stepped : V.Capture & Maybe<&1, U32 & String> <- Camera.read_bound(snapshot, announce, read_io)
    Camera.step_done(rest, stepped)

# Reads `remaining` frames, stopping at the first error. `snapshot` and
# `announce` apply to the first of them only.
def Camera.loop(remaining: Nat, capture: V.Capture,
  snapshot: Maybe<&2, String>, announce: Bool, error: Maybe<&1, U32 & String>) ->
  IO(V.Capture & Maybe<&1, U32 & String>):
  match remaining error:
    case 0n _:
      IO.pure(V.Capture & Maybe<&1, U32 & String>, (capture, error))
    case _ Some{_}:
      IO.pure(V.Capture & Maybe<&1, U32 & String>, (capture, error))
    case 1n+p None{}:
      Camera.step(capture, snapshot, announce, current => next_error =>
        Camera.loop(p, current, None{}, False{}, next_error))

def Camera.stats_text(stats: V.VideoStats, +frames: Nat, +duration: Nat) -> String:
  match stats:
    case V.VideoStats{+captured, +delivered, +superseded, +dropped, +latency_avg_us, +latency_max_us}:
      "Captured " ++ U32.show(captured) ++ ", delivered " ++ U32.show(delivered) ++
        ", superseded " ++ U32.show(superseded) ++ ", dropped by driver " ++
        U32.show(dropped) ++ "\nRead latency: avg " ++ U32.show(latency_avg_us) ++
        " us, max " ++ U32.show(latency_max_us) ++ " us\nMeasured " ++
        Nat.show(frames) ++ " frames in " ++ Nat.show(duration) ++ " ms: " ++
        A.Camera.fps_text(frames, duration)

def Camera.report_error(error: U32 & String) -> IO(Unit):
  do IO<Unit>:
    IO.print_err(A.Camera.error_text(error))
    IO.exit(1)

def Camera.report_finish(+frames: Nat, +started: Nat, +ended: Nat,
  stats_result: Result<&1, &1, U32 & String, V.VideoStats>,
  released: Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  match stats_result:
    case Fail{error}:
      Camera.report_error(error)
    case Done{stats}:
      match released:
        case Fail{error}:
          Camera.report_error(error)
        case Done{_}:
          do IO<Unit>:
            IO.print(Camera.stats_text(stats, frames, Nat.sub(ended, started)))
            return Unit{}

def Camera.finish_release(+frames: Nat, +started: Nat, +ended: Nat,
  pair: V.Capture & Result<&1, &1, U32 & String, V.VideoStats>) -> IO(Unit):
  (current, stats_result) = pair
  do IO<Unit>:
    released : Result<&1, &1, U32 & String, Unit> <- V.VideoCapture.release(current)
    finished : Unit <- Camera.report_finish(frames, started, ended, stats_result, released)
    return finished

def Camera.finish_success(capture: V.Capture, +frames: Nat, +started: Nat) -> IO(Unit):
  do IO<Unit>:
    ended : Nat <- IO.now()
    pair : V.Capture & Result<&1, &1, U32 & String, V.VideoStats> <- V.VideoCapture.stats(capture)
    Camera.finish_release(frames, started, ended, pair)

def Camera.finish(capture: V.Capture, +frames: Nat, +started: Nat,
  error: Maybe<&1, U32 & String>) -> IO(Unit):
  match error:
    case Some{value}:
      do IO<Unit>:
        _ : Result<&1, &1, U32 & String, Unit> <- V.VideoCapture.release(capture)
        failed : Unit <- Camera.report_error(value)
        return failed
    case None{}:
      Camera.finish_success(capture, frames, started)

def Camera.measured_bound(+frames: Nat, +started: Nat,
  measured: V.Capture & Maybe<&1, U32 & String>) -> IO(Unit):
  (last, error) = measured
  Camera.finish(last, frames, started, error)

# The warm-up's counters are discarded so the report covers only the timed reads.
def Camera.run_reset(+frames: Nat, reset: V.Capture & Result<&1, &1, U32 & String, V.VideoStats>) ->
  IO(Unit):
  (current, discarded) = reset
  do IO<Unit>:
    started : Nat <- IO.now()
    measured : (V.Capture & Maybe<&1, U32 & String>) <- Camera.loop(frames, current, None{}, False{}, None{})
    finished : Unit <- Camera.measured_bound(frames, started, measured)
    return finished

def Camera.run_measured(capture: V.Capture, +frames: Nat,
  warm_error: Maybe<&1, U32 & String>) -> IO(Unit):
  match warm_error:
    case Some{error}:
      Camera.finish(capture, frames, 0n, Some{error})
    case None{}:
      IO.bind(V.Capture & Result<&1, &1, U32 & String, V.VideoStats>, Unit,
        V.VideoCapture.stats(capture), reset => Camera.run_reset(frames, reset))

def Camera.run_bound(+frames: Nat, warmed: V.Capture & Maybe<&1, U32 & String>) -> IO(Unit):
  (current, warm_error) = warmed
  Camera.run_measured(current, frames, warm_error)

# The last warm-up frame is announced and saved: by then exposure has settled.
def Camera.warm_last(+frames: Nat, snapshot: Maybe<&2, String>,
  warmed: V.Capture & Maybe<&1, U32 & String>) -> IO(Unit):
  (current, error) = warmed
  IO.bind(V.Capture & Maybe<&1, U32 & String>, Unit,
    Camera.loop(1n, current, snapshot, True{}, error), last =>
    Camera.run_bound(frames, last))

def Camera.run(capture: V.Capture, config: A.CameraConfig) -> IO(Unit):
  match config:
    case A.CameraConfig{+frames, +snapshot}:
      IO.bind(V.Capture & Maybe<&1, U32 & String>, Unit,
        Camera.loop(Nat.sub(Camera.warmup_frames(), 1n), capture, None{}, False{}, None{}),
        warmed => Camera.warm_last(frames, snapshot, warmed))

def Camera.start(opened: Result<&1, &1, U32 & String, V.Capture>,
  config: A.CameraConfig) -> IO(Unit):
  match opened:
    case Fail{error}:
      Camera.report_error(error)
    case Done{capture}:
      Camera.run(capture, config)

def Camera.configure_config(config: Maybe<&2, A.CameraConfig>) -> IO(Unit):
  match config:
    case None{}:
      do IO<Unit>:
        IO.print_err("Usage: camera [frame-count] [snapshot.ppm]")
        IO.exit(1)
    case Some{config}:
      IO.bind(Result<&1, &1, U32 & String, V.Capture>, Unit,
        V.VideoCapture.open(0), opened => Camera.start(opened, config))

def main() -> IO(Unit):
  IO.bind(List<String>, Unit, IO.args(), args => Camera.configure_config(A.Camera.config(args)))
