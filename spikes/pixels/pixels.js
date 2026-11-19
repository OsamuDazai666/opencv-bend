// The spike measures the native lane only.
function spike_native_only() {
  throw new Error("The pixel spike runs as a native binary only: make spike");
}

io_eff(CID(Spike.frame_native), spike_native_only);
io_eff(CID(Spike.native_native), spike_native_only);
