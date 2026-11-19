// io_fail(code, ...rest) appends rest to the error tuple, so build the
// (code, message) pair directly. 45 is ENOTSUP on macOS.
function video_native_only() {
  return { $: "Fail", error: io_tup(45, "Camera capture requires the native macOS binary; JavaScript execution is unsupported.") };
}

io_eff(CID(VideoCapture.open_native), video_native_only);
io_eff(CID(VideoCapture.read_native), video_native_only);
io_eff(CID(VideoCapture.modes_native), video_native_only);
io_eff(CID(VideoCapture.stats_native), video_native_only);
io_eff(CID(VideoCapture.is_opened_native), () => ({ $: CID(False) }));
io_eff(CID(VideoCapture.release_native), video_native_only);
io_eff(CID(Frame.release_native), video_native_only);
io_eff(CID(Frame.snapshot_native), video_native_only);
io_eff(CID(Frame.bands_native), video_native_only);
