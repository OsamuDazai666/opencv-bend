import Base
import ./image.bend as I
import ./jpeg_tables.bend as T

# Baseline JPEG encoder in pure Bend (ITU-T T.81): YCbCr 4:2:0, float AAN
# DCT, the standard (Annex K) quantisation and Huffman tables at the quality
# baked into jpeg_tables.bend.
#
# Each band of a Mat is an independent restart interval, so the 8 bands are
# encoded in parallel and joined with RSTn markers. Bands hold whole 16-row
# macroblock rows (I.Mat.rows_per_band), except the last.
#
# The output is a list of byte segments: (Array<U32>, length in bytes), four
# bytes per U32, little-endian, so native code writes the memory as is.

# --- Bit writer -----------------------------------------------------------------

# out: packed bytes; pos: bytes written (it keeps counting past cap, without
# writing, so an overflow is detected rather than wrapping); acc/n: pending bits.
type Bits is Type:
  Bits{out: Array<U32>, pos: U32, cap: U32, acc: U32, n: U32}

def Bits.new(+cap: U32) -> Bits:
  Bits{Array.new(U32, I.Px.slots(((cap + 3) / 4 : U32)), 0), 0, cap, 0, 0}

def Bits.or_byte(got: Array<U32> & U32, +pos: U32, +v: U32) -> Array<U32>:
  (out, +old) = got
  +shift = ((pos .&. 3) * 8 : U32)
  Array.set(U32, out, (pos >> 2n : U32), (old .|. (v << U32.to_nat(shift)) : U32))

def Bits.raw_at(ok: Bool, out: Array<U32>, +pos: U32, +cap: U32, acc: U32, n: U32, +v: U32) -> Bits:
  match ok:
    case True{}:
      Bits{Bits.or_byte(Array.get(U32, out, (pos >> 2n : U32)), pos, v), (pos + 1 : U32), cap, acc, n}
    case False{}:
      Bits{out, (pos + 1 : U32), cap, acc, n}

# One byte as is (markers and headers).
def Bits.raw(bits: Bits, +v: U32) -> Bits:
  match bits:
    case Bits{out, +pos, +cap, acc, n}:
      Bits.raw_at(U32.is_lt(pos, cap), out, pos, cap, acc, n, v)

def Bits.stuff(ff: Bool, bits: Bits) -> Bits:
  match ff:
    case True{}:
      Bits.raw(bits, 0)
    case False{}:
      bits

# One byte of entropy-coded data: 0xFF is followed by 0x00.
def Bits.byte(bits: Bits, +v: U32) -> Bits:
  Bits.stuff(U32.is_eq(v, 255), Bits.raw(bits, v))

def Bits.flush_if(ready: Bool, out: Array<U32>, pos: U32, cap: U32, +acc: U32, +n: U32) -> Bits:
  match ready:
    case True{}:
      +m = (n - 8 : U32)
      +low = ((1 << U32.to_nat(m)) - 1 : U32)
      Bits.byte(Bits{out, pos, cap, (acc .&. low : U32), m}, ((acc >> U32.to_nat(m)) .&. 255 : U32))
    case False{}:
      Bits{out, pos, cap, acc, n}

def Bits.flush1(bits: Bits) -> Bits:
  match bits:
    case Bits{out, pos, cap, +acc, +n}:
      Bits.flush_if(U32.is_ge(n, 8), out, pos, cap, acc, n)

# Appends the low `len` bits of `code` (len <= 16). At most 7 bits wait in
# acc, so at most 23 are held and two bytes come out.
def Bits.put(bits: Bits, +code: U32, +len: U32) -> Bits:
  match bits:
    case Bits{out, pos, cap, +acc, +n}:
      Bits.flush1(Bits.flush1(Bits{out, pos, cap, ((acc << U32.to_nat(len)) .|. code : U32), (n + len : U32)}))

def Bits.pad_if(pending: Bool, bits: Bits, +fill: U32) -> Bits:
  match pending:
    case True{}:
      Bits.put(bits, ((1 << U32.to_nat(fill)) - 1 : U32), fill)
    case False{}:
      bits

# Pads the last byte with 1-bits, as T.81 requires before a marker.
def Bits.finish(bits: Bits) -> Bits:
  match bits:
    case Bits{out, pos, cap, acc, +n}:
      Bits.pad_if(U32.is_gt(n, 0), Bits{out, pos, cap, acc, n}, (8 - n : U32))

# The segment: (bytes, length). A length past the capacity means overflow.
def Bits.segment(bits: Bits) -> Array<U32> & U32:
  match bits:
    case Bits{out, pos, _, _, _}:
      (out, pos)

def Bits.raw_list(bytes: List<&2, U32>, bits: Bits) -> Bits:
  match bytes:
    case Nil{}:
      bits
    case Con{+b, rest}:
      Bits.raw_list(rest, Bits.raw(bits, b))

# --- Macroblocks -----------------------------------------------------------------

# A band's encoder state: the band, two 64-value scratch blocks, the writer,
# and the DC predictors for Y, Cb and Cr.
type Enc is Type:
  Enc{px: Array<U32>, s: Array<F32>, t: Array<F32>, bits: Bits, py: F32, pb: F32, pr: F32}

# --- Coefficients and Huffman codes ---------------------------------------------

def Enc.size_if(zero: Bool, +m: U32) -> U32:
  match zero:
    case True{}:
      0
    case False{}:
      (U32.from_nat(U32.log2(m)) + 1 : U32)

# The JPEG magnitude category: bits needed for |v|.
def Enc.size(+m: U32) -> U32:
  Enc.size_if(U32.is_eq(m, 0), m)

def Enc.bits_if(negative: Bool, +m: U32, +size: U32) -> U32:
  match negative:
    case True{}:
      (((1 << U32.to_nat(size)) - 1) - m : U32)
    case False{}:
      m

# The value bits of a coefficient: v itself, or for v < 0 its ones' complement.
def Enc.value_bits(+v: F32, +m: U32, +size: U32) -> U32:
  Enc.bits_if(F32.is_lt(v, 0.0), m, size)

def Enc.code(+packed: U32) -> U32:
  (packed >> 5n : U32)

def Enc.len(+packed: U32) -> U32:
  (packed .&. 31 : U32)

def Enc.put_huff(bits: Bits, +packed: U32) -> Bits:
  Bits.put(bits, Enc.code(packed), Enc.len(packed))

def Enc.dc_code(+chroma: Bool, +size: U32) -> U32:
  match chroma:
    case True{}:
      T.Jt.dc_chroma(U32.to_nat(size))
    case False{}:
      T.Jt.dc_luma(U32.to_nat(size))

def Enc.ac_code(+chroma: Bool, +symbol: U32) -> U32:
  match chroma:
    case True{}:
      T.Jt.ac_chroma(U32.to_nat(symbol))
    case False{}:
      T.Jt.ac_luma(U32.to_nat(symbol))

def Enc.recip(+chroma: Bool, +z: U32) -> F32:
  match chroma:
    case True{}:
      T.Jt.recip_chroma(U32.to_nat(z))
    case False{}:
      T.Jt.recip_luma(U32.to_nat(z))

def Enc.quant(+c: F32, +chroma: Bool, +z: U32) -> F32:
  F32.round((c * Enc.recip(chroma, z) : F32))

# A DC difference or an AC value: Huffman code for (symbol), then value bits.
def Enc.coded(bits: Bits, +packed: U32, +v: F32, +m: U32, +size: U32) -> Bits:
  Bits.put(Enc.put_huff(bits, packed), Enc.value_bits(v, m, size), size)

def Enc.dc(bits: Bits, +diff: F32, +chroma: Bool) -> Bits:
  +m = F32.to_u32(F32.abs(diff))
  +size = Enc.size(m)
  Enc.coded(bits, Enc.dc_code(chroma, size), diff, m, size)

# ZRL (0xF0) for each full run of 16 zeros.
def Enc.zrls(n: Nat, bits: Bits, +chroma: Bool) -> Bits:
  match n:
    case 0n:
      bits
    case 1n+p:
      Enc.zrls(p, Enc.put_huff(bits, Enc.ac_code(chroma, 240)), chroma)

def Enc.ac_nonzero(bits: Bits, +run: U32, +v: F32, +chroma: Bool) -> Bits & U32:
  +m = F32.to_u32(F32.abs(v))
  +size = Enc.size(m)
  +rest = (run % 16 : U32)
  (Enc.coded(Enc.zrls(U32.to_nat((run / 16 : U32)), bits, chroma),
    Enc.ac_code(chroma, ((rest << 4n) .|. size : U32)), v, m, size), 0)

def Enc.ac_step_if(zero: Bool, bits: Bits, +run: U32, +v: F32, +chroma: Bool) -> Bits & U32:
  match zero:
    case True{}:
      (bits, (run + 1 : U32))
    case False{}:
      Enc.ac_nonzero(bits, run, v, chroma)

# One AC coefficient: extend the zero run, or emit (run, size) and the value.
def Enc.ac_step(bits: Bits, +run: U32, +v: F32, +chroma: Bool) -> Bits & U32:
  Enc.ac_step_if(F32.is_eq(v, 0.0), bits, run, v, chroma)

def Enc.ac_end_if(trailing: Bool, bits: Bits, +chroma: Bool) -> Bits:
  match trailing:
    case True{}:
      Enc.put_huff(bits, Enc.ac_code(chroma, 0))
    case False{}:
      bits

# EOB when the block ends in zeros.
def Enc.ac_end(state: Bits & U32, +chroma: Bool) -> Bits:
  (bits, +run) = state
  Enc.ac_end_if(U32.is_gt(run, 0), bits, chroma)

# Quantised AC coefficients k..last in zigzag order; got = (block, value at k).
# The caller writes EOB after `last` when it is not 63.
def Enc.ac(n: Nat, got: Array<F32> & F32, state: Bits & U32, +k: U32, +chroma: Bool) ->
  Array<F32> & (Bits & U32):
  match n:
    case 0n:
      (s, +c) = got
      (bits, +run) = state
      (s, Enc.ac_step(bits, run, c, chroma))
    case 1n+p:
      (s, +c) = got
      (bits, +run) = state
      +next = (k + 1 : U32)
      Enc.ac(p, Array.get(F32, s, T.Jt.zigzag(U32.to_nat(next))), Enc.ac_step(bits, run, c, chroma), next, chroma)

# Quantises the block in place (natural order): s[z] = round(s[z] / divisor).
def Enc.quantize(n: Nat, got: Array<F32> & F32, +z: U32, +chroma: Bool) -> Array<F32>:
  match n:
    case 0n:
      (s, +c) = got
      Array.set(F32, s, z, Enc.quant(c, chroma, z))
    case 1n+p:
      (s, +c) = got
      Enc.quantize(p, Array.get(F32, Array.set(F32, s, z, Enc.quant(c, chroma, z)), (z + 1 : U32)), (z + 1 : U32), chroma)

# The zigzag index of the last non-zero AC coefficient (0 when all are zero),
# scanning down from 63. `found` says the coefficient at k + 1 was non-zero.
def Enc.last(n: Nat, found: Bool, got: Array<F32> & F32, +k: U32) -> Array<F32> & U32:
  match n found:
    case _ True{}:
      (s, c) = got
      (s, (k + 1 : U32))
    case 0n False{}:
      (s, c) = got
      (s, 0)
    case 1n+p False{}:
      (s, +c) = got
      Enc.last(p, Bool.not(F32.is_eq(c, 0.0)), Array.get(F32, s, T.Jt.zigzag(U32.to_nat((k - 1 : U32)))), (k - 1 : U32))

# EOB after the last non-zero coefficient (not needed when it is the 63rd).
def Enc.eob(state: Bits & U32, needed: Bool, +chroma: Bool) -> Bits:
  (bits, run) = state
  Enc.ac_end_if(needed, bits, chroma)

def Enc.block_done(+dc: F32, coded: Array<F32> & (Bits & U32), +last: U32, +chroma: Bool) ->
  Array<F32> & (Bits & F32):
  (s, state) = coded
  (s, (Enc.eob(state, U32.is_lt(last, 63), chroma), dc))

def Enc.block_ac_if(none: Bool, got: Array<F32> & F32, bits: Bits, +dc: F32, +last: U32, +chroma: Bool) ->
  Array<F32> & (Bits & F32):
  match none:
    case True{}:
      (s, c) = got
      (s, (Enc.put_huff(bits, Enc.ac_code(chroma, 0)), dc))
    case False{}:
      Enc.block_done(dc, Enc.ac(U32.to_nat((last - 1 : U32)), got, (bits, 0), 1, chroma), last, chroma)

def Enc.block_ac(got: Array<F32> & F32, bits: Bits, +dc: F32, +last: U32, +chroma: Bool) -> Array<F32> & (Bits & F32):
  Enc.block_ac_if(U32.is_eq(last, 0), got, bits, dc, last, chroma)

def Enc.block_dc(got: Array<F32> & F32, bits: Bits, +pred: F32, +last: U32, +chroma: Bool) ->
  Array<F32> & (Bits & F32):
  (s, +dc) = got
  Enc.block_ac(Array.get(F32, s, T.Jt.zigzag(1n)), Enc.dc(bits, (dc - pred : F32), chroma), dc, last, chroma)

def Enc.block_scanned(scanned: Array<F32> & U32, bits: Bits, +pred: F32, +chroma: Bool) -> Array<F32> & (Bits & F32):
  (s, +last) = scanned
  Enc.block_dc(Array.get(F32, s, 0), bits, pred, last, chroma)

def Enc.block_quantized(s: Array<F32>, bits: Bits, +pred: F32, +chroma: Bool) -> Array<F32> & (Bits & F32):
  Enc.block_scanned(Enc.last(63n, False{}, Array.get(F32, s, T.Jt.zigzag(63n)), 63), bits, pred, chroma)

# Quantises and entropy-codes one transformed 8x8 block; answers the new DC
# predictor alongside the block and the writer. Coding stops at the last
# non-zero coefficient (then EOB), so mostly-zero blocks are cheap.
def Enc.block(s: Array<F32>, bits: Bits, +pred: F32, +chroma: Bool) -> Array<F32> & (Bits & F32):
  Enc.block_quantized(Enc.quantize(63n, Array.get(F32, s, 0), 0, chroma), bits, pred, chroma)

# --- DCT (float AAN, as in libjpeg's jfdctflt) -------------------------------------

type Oct is Data:
  Oct{a: F32, b: F32, c: F32, d: F32, e: F32, f: F32, g: F32, h: F32}

def Dct.odd(+t4: F32, +t5: F32, +t6: F32, +t7: F32, +o0: F32, +o2: F32, +o4: F32, +o6: F32) -> Oct:
  +p10 = (t4 + t5 : F32)
  +p11 = (t5 + t6 : F32)
  +p12 = (t6 + t7 : F32)
  +z5 = ((p10 - p12) * 0.382683433 : F32)
  +z2 = (0.541196100 * p10 + z5 : F32)
  +z4 = (1.306562965 * p12 + z5 : F32)
  +z3 = (p11 * 0.707106781 : F32)
  +z11 = (t7 + z3 : F32)
  +z13 = (t7 - z3 : F32)
  Oct{o0, (z11 + z4 : F32), o2, (z13 - z2 : F32), o4, (z13 + z2 : F32), o6, (z11 - z4 : F32)}

def Dct.aan(o: Oct) -> Oct:
  match o:
    case Oct{+d0, +d1, +d2, +d3, +d4, +d5, +d6, +d7}:
      +t0 = (d0 + d7 : F32)
      +t7 = (d0 - d7 : F32)
      +t1 = (d1 + d6 : F32)
      +t6 = (d1 - d6 : F32)
      +t2 = (d2 + d5 : F32)
      +t5 = (d2 - d5 : F32)
      +t3 = (d3 + d4 : F32)
      +t4 = (d3 - d4 : F32)
      +t10 = (t0 + t3 : F32)
      +t13 = (t0 - t3 : F32)
      +t11 = (t1 + t2 : F32)
      +t12 = (t1 - t2 : F32)
      +z1 = ((t12 + t13) * 0.707106781 : F32)
      Dct.odd(t4, t5, t6, t7, (t10 + t11 : F32), (t13 + z1 : F32), (t10 - t11 : F32), (t13 - z1 : F32))

def Dct.write(s: Array<F32>, +base: U32, +step: U32, o: Oct) -> Array<F32>:
  match o:
    case Oct{a, b, c, d, e, f, g, h}:
      Array.set(F32, Array.set(F32, Array.set(F32, Array.set(F32,
        Array.set(F32, Array.set(F32, Array.set(F32, Array.set(F32, s,
          base, a), (base + step : U32), b), (base + 2 * step : U32), c), (base + 3 * step : U32), d),
          (base + 4 * step : U32), e), (base + 5 * step : U32), f), (base + 6 * step : U32), g),
          (base + 7 * step : U32), h)

def Dct.r7(got: Array<F32> & F32, +a: F32, +b: F32, +c: F32, +d: F32, +e: F32, +f: F32, +g: F32) ->
  Array<F32> & Oct:
  (s, +h) = got
  (s, Oct{a, b, c, d, e, f, g, h})

def Dct.r6(got: Array<F32> & F32, +base: U32, +step: U32, +a: F32, +b: F32, +c: F32, +d: F32, +e: F32,
  +f: F32) -> Array<F32> & Oct:
  (s, +g) = got
  Dct.r7(Array.get(F32, s, (base + 7 * step : U32)), a, b, c, d, e, f, g)

def Dct.r5(got: Array<F32> & F32, +base: U32, +step: U32, +a: F32, +b: F32, +c: F32, +d: F32, +e: F32) ->
  Array<F32> & Oct:
  (s, +f) = got
  Dct.r6(Array.get(F32, s, (base + 6 * step : U32)), base, step, a, b, c, d, e, f)

def Dct.r4(got: Array<F32> & F32, +base: U32, +step: U32, +a: F32, +b: F32, +c: F32, +d: F32) ->
  Array<F32> & Oct:
  (s, +e) = got
  Dct.r5(Array.get(F32, s, (base + 5 * step : U32)), base, step, a, b, c, d, e)

def Dct.r3(got: Array<F32> & F32, +base: U32, +step: U32, +a: F32, +b: F32, +c: F32) -> Array<F32> & Oct:
  (s, +d) = got
  Dct.r4(Array.get(F32, s, (base + 4 * step : U32)), base, step, a, b, c, d)

def Dct.r2(got: Array<F32> & F32, +base: U32, +step: U32, +a: F32, +b: F32) -> Array<F32> & Oct:
  (s, +c) = got
  Dct.r3(Array.get(F32, s, (base + 3 * step : U32)), base, step, a, b, c)

def Dct.r1(got: Array<F32> & F32, +base: U32, +step: U32, +a: F32) -> Array<F32> & Oct:
  (s, +b) = got
  Dct.r2(Array.get(F32, s, (base + 2 * step : U32)), base, step, a, b)

def Dct.r0(got: Array<F32> & F32, +base: U32, +step: U32) -> Array<F32> & Oct:
  (s, +a) = got
  Dct.r1(Array.get(F32, s, (base + step : U32)), base, step, a)

# Eight values s[base + i * step].
def Dct.read(s: Array<F32>, +base: U32, +step: U32) -> Array<F32> & Oct:
  Dct.r0(Array.get(F32, s, base), base, step)

# One pass: line l starts at l * lstep, its values are `step` apart.
def Dct.pass(n: Nat, got: Array<F32> & Oct, +l: U32, +lstep: U32, +step: U32) -> Array<F32>:
  match n:
    case 0n:
      (s, o) = got
      Dct.write(s, (l * lstep : U32), step, Dct.aan(o))
    case 1n+p:
      (s, o) = got
      +next = (l + 1 : U32)
      Dct.pass(p, Dct.read(Dct.write(s, (l * lstep : U32), step, Dct.aan(o)), (next * lstep : U32), step),
        next, lstep, step)

# The 2-D DCT of the 8x8 block in s (row-major), in place: rows, then columns.
def Dct.block(s: Array<F32>) -> Array<F32>:
  Dct.pass(7n, Dct.read(Dct.pass(7n, Dct.read(s, 0, 1), 0, 8, 1), 0, 8), 0, 1, 8)

# --- Loading blocks from a band -------------------------------------------------

def Load.f(+v: U32) -> F32:
  U32.to_f32(v)

# JFIF colour conversion, level-shifted by -128.
def Load.y(+p: U32) -> F32:
  (0.299 * Load.f(I.Pixel.r(p)) + 0.587 * Load.f(I.Pixel.g(p)) + 0.114 * Load.f(I.Pixel.b(p)) - 128.0 : F32)

def Load.cb(+p: U32) -> F32:
  (0.0 - 0.168736 * Load.f(I.Pixel.r(p)) - 0.331264 * Load.f(I.Pixel.g(p)) + 0.5 * Load.f(I.Pixel.b(p)) : F32)

def Load.cr(+p: U32) -> F32:
  (0.5 * Load.f(I.Pixel.r(p)) - 0.418688 * Load.f(I.Pixel.g(p)) - 0.081312 * Load.f(I.Pixel.b(p)) : F32)

# Index of pixel (x, y) in a band, clamped to its edges (edge pixels repeat).
def Load.at(+x: U32, +y: U32, +w: U32, +h: U32) -> U32:
  (U32.min(y, (h - 1 : U32)) * w + U32.min(x, (w - 1 : U32)) : U32)

def Load.luma_index(+i: U32, +x0: U32, +y0: U32, +w: U32, +h: U32) -> U32:
  Load.at((x0 + i % 8 : U32), (y0 + i / 8 : U32), w, h)

# s[i] = Y of pixel (x0 + i % 8, y0 + i / 8); got = (band, pixel for i).
def Load.luma(n: Nat, got: Array<U32> & U32, s: Array<F32>, +i: U32, +x0: U32, +y0: U32, +w: U32, +h: U32) ->
  Array<U32> & Array<F32>:
  match n:
    case 0n:
      (px, +p) = got
      (px, Array.set(F32, s, i, Load.y(p)))
    case 1n+q:
      (px, +p) = got
      +next = (i + 1 : U32)
      Load.luma(q, Array.get(U32, px, Load.luma_index(next, x0, y0, w, h)), Array.set(F32, s, i, Load.y(p)),
        next, x0, y0, w, h)

type Quad is Data:
  Quad{a: U32, b: U32, c: U32, d: U32}

def Load.q3(got: Array<U32> & U32, +a: U32, +b: U32, +c: U32) -> Array<U32> & Quad:
  (px, +d) = got
  (px, Quad{a, b, c, d})

def Load.q2(got: Array<U32> & U32, +x: U32, +y: U32, +w: U32, +h: U32, +a: U32, +b: U32) -> Array<U32> & Quad:
  (px, +c) = got
  Load.q3(Array.get(U32, px, Load.at((x + 1 : U32), (y + 1 : U32), w, h)), a, b, c)

def Load.q1(got: Array<U32> & U32, +x: U32, +y: U32, +w: U32, +h: U32, +a: U32) -> Array<U32> & Quad:
  (px, +b) = got
  Load.q2(Array.get(U32, px, Load.at(x, (y + 1 : U32), w, h)), x, y, w, h, a, b)

def Load.q0(got: Array<U32> & U32, +x: U32, +y: U32, +w: U32, +h: U32) -> Array<U32> & Quad:
  (px, +a) = got
  Load.q1(Array.get(U32, px, Load.at((x + 1 : U32), y, w, h)), x, y, w, h, a)

# The 2x2 pixels behind chroma sample i of the 16x16 macroblock at (x0, y0).
def Load.quad(px: Array<U32>, +i: U32, +x0: U32, +y0: U32, +w: U32, +h: U32) -> Array<U32> & Quad:
  +x = (x0 + (i % 8) * 2 : U32)
  +y = (y0 + (i / 8) * 2 : U32)
  Load.q0(Array.get(U32, px, Load.at(x, y, w, h)), x, y, w, h)

def Load.cb4(q: Quad) -> F32:
  match q:
    case Quad{+a, +b, +c, +d}:
      ((Load.cb(a) + Load.cb(b) + Load.cb(c) + Load.cb(d)) * 0.25 : F32)

def Load.cr4(q: Quad) -> F32:
  match q:
    case Quad{+a, +b, +c, +d}:
      ((Load.cr(a) + Load.cr(b) + Load.cr(c) + Load.cr(d)) * 0.25 : F32)

# s[i] = Cb and t[i] = Cr, each averaged over 2x2 pixels (4:2:0).
def Load.chroma(n: Nat, got: Array<U32> & Quad, s: Array<F32>, t: Array<F32>, +i: U32, +x0: U32, +y0: U32,
  +w: U32, +h: U32) -> Array<U32> & (Array<F32> & Array<F32>):
  match n:
    case 0n:
      (px, +q) = got
      (px, (Array.set(F32, s, i, Load.cb4(q)), Array.set(F32, t, i, Load.cr4(q))))
    case 1n+r:
      (px, +q) = got
      +next = (i + 1 : U32)
      Load.chroma(r, Load.quad(px, next, x0, y0, w, h), Array.set(F32, s, i, Load.cb4(q)),
        Array.set(F32, t, i, Load.cr4(q)), next, x0, y0, w, h)

def Mb.y_done(px: Array<U32>, t: Array<F32>, +pb: F32, +pr: F32, coded: Array<F32> & (Bits & F32)) -> Enc:
  (s, (bits, py)) = coded
  Enc{px, s, t, bits, py, pb, pr}

def Mb.y_loaded(loaded: Array<U32> & Array<F32>, t: Array<F32>, bits: Bits, +py: F32, +pb: F32, +pr: F32) -> Enc:
  (px, s) = loaded
  Mb.y_done(px, t, pb, pr, Enc.block(Dct.block(s), bits, py, False{}))

# One 8x8 luma block at (x0, y0).
def Mb.luma(e: Enc, +x0: U32, +y0: U32, +w: U32, +h: U32) -> Enc:
  match e:
    case Enc{px, s, t, bits, +py, +pb, +pr}:
      Mb.y_loaded(Load.luma(63n, Array.get(U32, px, Load.at(x0, y0, w, h)), s, 0, x0, y0, w, h),
        t, bits, py, pb, pr)

def Mb.cr_done(px: Array<U32>, s: Array<F32>, +py: F32, +pb: F32, coded: Array<F32> & (Bits & F32)) -> Enc:
  (t, (bits, pr)) = coded
  Enc{px, s, t, bits, py, pb, pr}

def Mb.cr_block(e: Enc) -> Enc:
  match e:
    case Enc{px, s, t, bits, +py, +pb, +pr}:
      Mb.cr_done(px, s, py, pb, Enc.block(Dct.block(t), bits, pr, True{}))

def Mb.cb_done(px: Array<U32>, t: Array<F32>, +py: F32, +pr: F32, coded: Array<F32> & (Bits & F32)) -> Enc:
  (s, (bits, pb)) = coded
  Mb.cr_block(Enc{px, s, t, bits, py, pb, pr})

def Mb.c_loaded(loaded: Array<U32> & (Array<F32> & Array<F32>), bits: Bits, +py: F32, +pb: F32, +pr: F32) -> Enc:
  (px, (s, t)) = loaded
  Mb.cb_done(px, t, py, pr, Enc.block(Dct.block(s), bits, pb, True{}))

# The Cb and Cr blocks of the macroblock at (x0, y0).
def Mb.chroma(e: Enc, +x0: U32, +y0: U32, +w: U32, +h: U32) -> Enc:
  match e:
    case Enc{px, s, t, bits, +py, +pb, +pr}:
      Mb.c_loaded(Load.chroma(63n, Load.quad(px, 0, x0, y0, w, h), s, t, 0, x0, y0, w, h), bits, py, pb, pr)

# A 16x16 macroblock: four Y blocks, then Cb and Cr.
def Mb.encode(e: Enc, +x0: U32, +y0: U32, +w: U32, +h: U32) -> Enc:
  Mb.chroma(Mb.luma(Mb.luma(Mb.luma(Mb.luma(e, x0, y0, w, h), (x0 + 8 : U32), y0, w, h),
    x0, (y0 + 8 : U32), w, h), (x0 + 8 : U32), (y0 + 8 : U32), w, h), x0, y0, w, h)

def Mb.loop(n: Nat, e: Enc, +m: U32, +across: U32, +w: U32, +h: U32) -> Enc:
  match n:
    case 0n:
      e
    case 1n+p:
      Mb.loop(p, Mb.encode(e, ((m % across) * 16 : U32), ((m / across) * 16 : U32), w, h), (m + 1 : U32),
        across, w, h)

def Mb.segment(e: Enc) -> Array<U32> & (Array<U32> & U32):
  match e:
    case Enc{px, s, t, bits, _, _, _}:
      (px, Bits.segment(Bits.finish(bits)))

def Mb.count(+size: U32) -> U32:
  ((size + 15) / 16 : U32)

# Encodes one band (w x rows) as a restart interval; hands the band back.
# The writer holds one byte per pixel, far above what quality 75 produces.
def Mb.band(+w: U32, +rows: U32, px: Array<U32>) -> Array<U32> & (Array<U32> & U32):
  +across = Mb.count(w)
  Mb.segment(Mb.loop(U32.to_nat((across * Mb.count(rows) : U32)),
    Enc{px, Array.new(F32, 6n, 0.0), Array.new(F32, 6n, 0.0), Bits.new((w * rows + 64 : U32)), 0.0, 0.0, 0.0},
    0, across, w, rows))

# --- Bands in parallel --------------------------------------------------------------

def Jpeg.band_done(+rows: U32, coded: Array<U32> & (Array<U32> & U32)) ->
  I.Bands<Array<U32>> & List<(Array<U32> & U32)>:
  (px, seg) = coded
  (I.Band{rows, px}, [seg])

def Jpeg.band_if(empty: Bool, +w: U32, +rows: U32, px: Array<U32>) ->
  I.Bands<Array<U32>> & List<(Array<U32> & U32)>:
  match empty:
    case True{}:
      (I.Band{rows, px}, Nil{})
    case False{}:
      Jpeg.band_done(rows, Mb.band(w, rows, px))

def Jpeg.split_done(+rows: U32, top: I.Bands<Array<U32>> & List<(Array<U32> & U32)>,
  bottom: I.Bands<Array<U32>> & List<(Array<U32> & U32)>) -> I.Bands<Array<U32>> & List<(Array<U32> & U32)>:
  (t, ts) = top
  (b, bs) = bottom
  (I.Split{rows, t, b}, List.append(&1, (Array<U32> & U32), ts, bs))

# Every band's entropy-coded segment, top to bottom, bands in parallel.
def Jpeg.bands(+w: U32, bands: I.Bands<Array<U32>>) -> I.Bands<Array<U32>> & List<(Array<U32> & U32)>:
  match bands:
    case I.NoBand{}:
      (I.NoBand{}, Nil{})
    case I.Band{+rows, px}:
      Jpeg.band_if(U32.is_eq(rows, 0), w, rows, px)
    case I.Split{+rows, top, bottom}:
      t b = Jpeg.bands(w, top) Jpeg.bands(w, bottom)
      Jpeg.split_done(rows, t, b)

# --- Headers and assembly ------------------------------------------------------------

def Jpeg.bytes(+bytes: List<&2, U32>) -> Array<U32> & U32:
  Bits.segment(Bits.raw_list(bytes, Bits.new((U32.from_nat(List.length(&2, U32, bytes)) + 4 : U32))))

def Jpeg.be16(+v: U32) -> List<&2, U32>:
  [(v >> 8n : U32), (v .&. 255 : U32)]

def Jpeg.segment(+marker: U32, +body: List<&2, U32>) -> List<&2, U32>:
  +len = (U32.from_nat(List.length(&2, U32, body)) + 2 : U32)
  List.append(&2, U32, [255, marker], List.append(&2, U32, Jpeg.be16(len), body))

# Macroblocks per restart interval: one band's worth.
def Jpeg.restart_interval(+w: U32, +h: U32) -> U32:
  (Mb.count(w) * (I.Mat.rows_per_band(w, h) / 16) : U32)

# SOI, DQT, SOF0 (4:2:0), DHT, DRI (one restart interval per band), SOS.
def Jpeg.header(+w: U32, +h: U32) -> List<&2, U32>:
  +interval = Jpeg.restart_interval(w, h)
  List.append(&2, U32, [255, 216],
  List.append(&2, U32, Jpeg.segment(219, T.Jt.dqt()),
  List.append(&2, U32, Jpeg.segment(192, List.append(&2, U32, [8],
    List.append(&2, U32, Jpeg.be16(h), List.append(&2, U32, Jpeg.be16(w),
      [3, 1, 34, 0, 2, 17, 1, 3, 17, 1])))),
  List.append(&2, U32, Jpeg.segment(196, T.Jt.dht()),
  List.append(&2, U32, Jpeg.segment(221, Jpeg.be16(interval)),
    Jpeg.segment(218, [3, 1, 0, 2, 17, 3, 17, 0, 63, 0]))))))

# Band segments with RST0..RST7 between them (cycling).
def Jpeg.with_restarts(segs: List<(Array<U32> & U32)>, +n: U32) -> List<(Array<U32> & U32)>:
  match segs:
    case Nil{}:
      Nil{}
    case Con{seg, Nil{}}:
      [seg]
    case Con{seg, rest}:
      Con{seg, Con{Jpeg.bytes([255, (208 + n % 8 : U32)]), Jpeg.with_restarts(rest, (n + 1 : U32))}}

def Jpeg.assemble(+w: U32, +h: U32, coded: I.Bands<Array<U32>> & List<(Array<U32> & U32)>) ->
  I.Mat & List<(Array<U32> & U32)>:
  (bands, segs) = coded
  (I.Mat{w, h, bands},
    Con{Jpeg.bytes(Jpeg.header(w, h)), List.append(&1, (Array<U32> & U32), Jpeg.with_restarts(segs, 0),
      [Jpeg.bytes([255, 217])])})

# Encodes a Mat as a baseline JPEG: a list of (bytes, length) segments to
# write in order. The Mat is handed back unchanged.
def Jpeg.encode(image: I.Mat) -> I.Mat & List<(Array<U32> & U32)>:
  match image:
    case I.Mat{+w, +h, bands}:
      Jpeg.assemble(w, h, Jpeg.bands(w, bands))

def Jpeg.zigzag_add(hit: Bool, rest: Nat) -> Nat:
  match hit:
    case True{}:
      1n+rest
    case False{}:
      rest

# --- Checks used by the laws ------------------------------------------------------

# How many of the next n zigzag positions, from i, map to natural index t.
def Jpeg.zigzag_hits(n: Nat, +i: U32, +t: U32) -> Nat:
  match n:
    case 0n:
      0n
    case 1n+p:
      Jpeg.zigzag_add(U32.is_eq(T.Jt.zigzag(U32.to_nat(i)), t), Jpeg.zigzag_hits(p, (i + 1 : U32), t))

def Jpeg.zigzag_all_once(n: Nat, +t: U32) -> Bool:
  match n:
    case 0n:
      True{}
    case 1n+p:
      Bool.and(Nat.is_eq(Jpeg.zigzag_hits(64n, 0, t), 1n), Jpeg.zigzag_all_once(p, (t + 1 : U32)))

# The zigzag table is a permutation of 0..63: each index appears exactly once.
def Jpeg.zigzag_ok() -> Bool:
  Jpeg.zigzag_all_once(64n, 0)

def Bits.first_word_of(got: Array<U32> & U32, +n: U32) -> U32 & U32:
  (out, +w) = got
  (n, w)

def Bits.first_word(seg: Array<U32> & U32) -> U32 & U32:
  (out, +n) = seg
  Bits.first_word_of(Array.get(U32, out, 0), n)

# (bytes written, first four bytes as a little-endian word).
def Bits.peek(bits: Bits) -> U32 & U32:
  Bits.first_word(Bits.segment(bits))
