io_eff(CID(Bytes.write_file), (path, segs) => io_tup(segs, { $: "Fail", error: io_tup(45, "Writing bytes requires the native binary.") }));
