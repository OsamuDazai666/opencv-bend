import Base
import ./viewer.bend as W
import ./modes.bend as M
import ./image.bend as I

type Capture is Type:
  Capture{id: U32}

type Frame is Type:
  Frame{id: U32, width: U32, height: U32, stride: U32, sequence: U32, timestamp_ms: U32}

# Counters for the window since open or since the previous stats call.
# superseded: frames replaced by a newer one before a read took them.
# dropped: frames AVFoundation discarded before they reached us.
# latency: from the frame's arrival in the capture callback to its delivery by read.
type VideoStats is Data:
  VideoStats{captured: U32, delivered: U32, superseded: U32, dropped: U32,
    latency_avg_us: U32, latency_max_us: U32}

def VideoCapture.open_native(+index: U32, +width: U32, +height: U32, +fps: U32) ->
  IO(Result<&1, &1, U32 & String, Capture>):
  import "./native/videoio.c"
  import "./native/videoio.js"

def VideoCapture.modes_native(+index: U32) ->
  IO(Result<&1, &1, U32 & String, List<&2, U32>>):
  import "./native/videoio.c"
  import "./native/videoio.js"

def VideoCapture.read_native(+id: U32, +timeout_ms: U32) ->
  IO(Result<&1, &1, U32 & String, Frame>):
  import "./native/videoio.c"
  import "./native/videoio.js"

def VideoCapture.stats_native(+id: U32) ->
  IO(Result<&1, &1, U32 & String, VideoStats>):
  import "./native/videoio.c"
  import "./native/videoio.js"

def VideoCapture.is_opened_native(+id: U32) -> IO(Bool):
  import "./native/videoio.c"
  import "./native/videoio.js"

def VideoCapture.release_native(+id: U32) ->
  IO(Result<&1, &1, U32 & String, Unit>):
  import "./native/videoio.c"
  import "./native/videoio.js"

def Frame.release_native(+id: U32) ->
  IO(Result<&1, &1, U32 & String, Unit>):
  import "./native/videoio.c"
  import "./native/videoio.js"

def Frame.snapshot_native(+id: U32, path: String) ->
  IO(Result<&1, &1, U32 & String, Unit>):
  import "./native/videoio.c"
  import "./native/videoio.js"

def VideoCapture.with_viewer(opened: Result<&1, &1, U32 & String, Capture>) ->
  IO(Result<&1, &1, U32 & String, Capture>):
  match opened:
    case Fail{error}:
      IO.pure(Result<&1, &1, U32 & String, Capture>, Fail{error})
    case Done{capture}:
      do IO<Result<&1, &1, U32 & String, Capture>>:
        W.Viewer.start()
        return Done{capture}

# The modes a camera offers (size and highest frame rate). Needs no permission.
def VideoCapture.modes_of(listed: Result<&1, &1, U32 & String, List<&2, U32>>) ->
  IO(Result<&1, &1, U32 & String, List<&2, M.Mode>>):
  match listed:
    case Fail{error}:
      IO.pure(Result<&1, &1, U32 & String, List<&2, M.Mode>>, Fail{error})
    case Done{numbers}:
      IO.pure(Result<&1, &1, U32 & String, List<&2, M.Mode>>, Done{M.Modes.from_numbers(numbers)})

def VideoCapture.modes(+index: U32) -> IO(Result<&1, &1, U32 & String, List<&2, M.Mode>>):
  IO.bind(Result<&1, &1, U32 & String, List<&2, U32>>, Result<&1, &1, U32 & String, List<&2, M.Mode>>,
    VideoCapture.modes_native(index), listed => VideoCapture.modes_of(listed))

def VideoCapture.open_mode(+index: U32, picked: Maybe<&2, M.Mode>, offered: String) ->
  IO(Result<&1, &1, U32 & String, Capture>):
  match picked:
    case None{}:
      IO.pure(Result<&1, &1, U32 & String, Capture>,
        Fail{(22, "The camera does not offer that size. It offers: " ++ offered)})
    case Some{M.Mode{+width, +height, +fps}}:
      IO.bind(Result<&1, &1, U32 & String, Capture>, Result<&1, &1, U32 & String, Capture>,
        VideoCapture.open_native(index, width, height, fps), opened =>
        VideoCapture.with_viewer(opened))

def VideoCapture.open_listed(+index: U32, +want: M.Want,
  listed: Result<&1, &1, U32 & String, List<&2, M.Mode>>) ->
  IO(Result<&1, &1, U32 & String, Capture>):
  match listed:
    case Fail{error}:
      IO.pure(Result<&1, &1, U32 & String, Capture>, Fail{error})
    case Done{+modes}:
      VideoCapture.open_mode(index, M.Modes.pick(want, modes), M.Modes.show(modes))

# Opens a camera in the mode `want` picks (M.Largest{} or M.Size{w, h}) and
# serves it in the browser viewer, privately on http://127.0.0.1:8765/
# unless sharing is switched on.
def VideoCapture.open_with(+index: U32, +want: M.Want) ->
  IO(Result<&1, &1, U32 & String, Capture>):
  IO.bind(Result<&1, &1, U32 & String, List<&2, M.Mode>>, Result<&1, &1, U32 & String, Capture>,
    VideoCapture.modes(index), listed => VideoCapture.open_listed(index, want, listed))

# Opens a camera (0 is the default one) at its largest mode.
def VideoCapture.open(+index: U32) ->
  IO(Result<&1, &1, U32 & String, Capture>):
  VideoCapture.open_with(index, M.Largest{})

def VideoCapture.read(capture: Capture, +timeout_ms: U32) ->
  IO(Capture & Result<&1, &1, U32 & String, Frame>):
  match capture:
    case Capture{+id}:
      do IO<Capture & Result<&1, &1, U32 & String, Frame>>:
        result : Result<&1, &1, U32 & String, Frame> <- VideoCapture.read_native(id, timeout_ms)
        return (Capture{id}, result)

def VideoCapture.is_opened(capture: Capture) -> IO(Capture & Bool):
  match capture:
    case Capture{+id}:
      do IO<Capture & Bool>:
        opened : Bool <- VideoCapture.is_opened_native(id)
        return (Capture{id}, opened)

def VideoCapture.stats(capture: Capture) ->
  IO(Capture & Result<&1, &1, U32 & String, VideoStats>):
  match capture:
    case Capture{+id}:
      do IO<Capture & Result<&1, &1, U32 & String, VideoStats>>:
        result : Result<&1, &1, U32 & String, VideoStats> <- VideoCapture.stats_native(id)
        return (Capture{id}, result)

def VideoCapture.release(capture: Capture) ->
  IO(Result<&1, &1, U32 & String, Unit>):
  match capture:
    case Capture{id}:
      VideoCapture.release_native(id)

def Frame.release(frame: Frame) ->
  IO(Result<&1, &1, U32 & String, Unit>):
  match frame:
    case Frame{id, _, _, _, _, _}:
      Frame.release_native(id)

def Frame.snapshot(frame: Frame, path: String) ->
  IO(Frame & Result<&1, &1, U32 & String, Unit>):
  match frame:
    case Frame{+id, +width, +height, +stride, +sequence, +timestamp_ms}:
      do IO<Frame & Result<&1, &1, U32 & String, Unit>>:
        result : Result<&1, &1, U32 & String, Unit> <- Frame.snapshot_native(id, path)
        return (Frame{id, width, height, stride, sequence, timestamp_ms}, result)

def Frame.description(frame: Frame) -> String & Frame:
  match frame:
    case Frame{id, +width, +height, +stride, +sequence, +timestamp_ms}:
      ("Frame " ++ U32.show(sequence) ++ ": " ++ U32.show(width) ++ "x" ++
        U32.show(height) ++ " BGRA, stride " ++ U32.show(stride) ++
        ", timestamp " ++ U32.show(timestamp_ms) ++ " ms",
        Frame{id, width, height, stride, sequence, timestamp_ms})

def Frame.bands_native(+id: U32, +rows_per_band: U32, +swap_rb: U32) ->
  IO(Result<&1, &1, U32 & String, List<(U32 & Array<U32>)>>):
  import "./native/videoio.c"
  import "./native/videoio.js"

def Frame.mat_of(+width: U32, +height: U32,
  copied: Result<&1, &1, U32 & String, List<(U32 & Array<U32>)>>) -> Result<&1, &1, U32 & String, I.Mat>:
  match copied:
    case Fail{error}:
      Fail{error}
    case Done{pieces}:
      Done{I.Mat.from_bands(width, height, pieces)}

# Copies the frame's pixels into a Mat (RGBA, bands of rows processed in
# parallel). The frame is handed back; release it as usual.
def Frame.to_mat(frame: Frame) -> IO(Frame & Result<&1, &1, U32 & String, I.Mat>):
  match frame:
    case Frame{+id, +width, +height, +stride, +sequence, +timestamp_ms}:
      IO.bind(Result<&1, &1, U32 & String, List<(U32 & Array<U32>)>>,
        Frame & Result<&1, &1, U32 & String, I.Mat>,
        Frame.bands_native(id, I.Mat.rows_per_band(width, height), I.Mat.swap_from_camera()), copied =>
        IO.pure(Frame & Result<&1, &1, U32 & String, I.Mat>,
          (Frame{id, width, height, stride, sequence, timestamp_ms}, Frame.mat_of(width, height, copied))))
