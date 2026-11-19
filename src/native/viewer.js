// The browser viewer needs the native macOS binary; on the JavaScript lane it
// never starts (claim answers False) and every query answers a neutral value.
function viewer_fail() {
  return { $: "Fail", error: io_tup(45, "The viewer requires the native macOS binary.") };
}

io_eff(CID(Viewer.next_jpeg), viewer_fail);
io_eff(CID(Viewer.send_jpeg), (sock) => io_tup(sock, viewer_fail()));
io_eff(CID(Viewer.peer_is_local), (sock) => io_tup(sock, { $: CID(False) }));
io_eff(CID(Viewer.lan_addresses), () => "");
io_eff(CID(Viewer.random_token), () => "");
io_eff(CID(Viewer.claim), () => ({ $: CID(False) }));
io_eff(CID(Viewer.unclaim), () => ({ $: CID(Unit) }));
io_eff(CID(Viewer.request_sharing), () => ({ $: CID(Unit) }));
io_eff(CID(Viewer.requested_sharing), () => ({ $: CID(False) }));
io_eff(CID(Viewer.publish_state), () => ({ $: CID(Unit) }));
io_eff(CID(Viewer.state), () => io_tup({ $: CID(False) }, 0));
io_eff(CID(Viewer.capture_count), () => 0);
io_eff(CID(Viewer.cameras), () => ({ $: CID(Nil) }));
io_eff(CID(Viewer.capture_for), () => 0);
io_eff(CID(Viewer.encodes), () => 0);
io_eff(CID(Viewer.base_port), () => 8765);
io_eff(CID(Viewer.stream_enter), () => ({ $: CID(False) }));
io_eff(CID(Viewer.stream_leave), () => ({ $: CID(Unit) }));
io_eff(CID(View.publish_native), (name, w, h, swap, bands) => io_tup(bands, viewer_fail()));
io_eff(CID(Viewer.view_for), () => 0);
io_eff(CID(Viewer.views), () => "");
io_eff(CID(Viewer.peek), viewer_fail);
io_eff(CID(Viewer.frame_size), viewer_fail);
io_eff(CID(Viewer.frame_bands), viewer_fail);
io_eff(CID(Viewer.frame_drop), () => ({ $: CID(Unit) }));
io_eff(CID(Viewer.store_jpeg), (capture, seq, segs) => io_tup(segs, viewer_fail()));
