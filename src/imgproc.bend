import Base
import ./image.bend as I

# Image processing on Mats (OpenCV's imgproc, first batch). Pure Bend; bands
# run in parallel. Behaviour follows OpenCV unless a project law says
# otherwise (crop refuses rectangles past the edge).

# --- Helpers --------------------------------------------------------------------

def U.pick(cond: Bool, +yes: U32, +no: U32) -> U32:
  match cond:
    case True{}:
      yes
    case False{}:
      no

# a - b, or 0 when b > a.
def U.sat_sub(+a: U32, +b: U32) -> U32:
  U.pick(U32.is_gt(a, b), (a - b : U32), 0)

def U.between(+lo: U32, +v: U32, +hi: U32) -> Bool:
  Bool.and(U32.is_le(lo, v), U32.is_le(v, hi))

# --- Per-pixel loops with a parameter and the pixel's position -------------------
# f(param, x, y, pixel) -> new pixel. A template (fast, no closure per pixel);
# the parameter record carries runtime values such as a colour or a threshold.

def Px.map_xy_go(~P: Data, ~f: P -> U32 -> U32 -> U32 -> U32, +prm: P, n: Nat, got: Array<U32> & U32,
  +i: U32, +w: U32, +y0: U32) -> Array<U32>:
  match n:
    case 0n:
      (band, +px) = got
      Array.set(U32, band, i, f(prm, (i % w : U32), (y0 + i / w : U32), px))
    case 1n+p:
      (band, +px) = got
      +j = (i + 1 : U32)
      Px.map_xy_go(~P, ~f, prm, p, Array.get(U32, Array.set(U32, band, i, f(prm, (i % w : U32), (y0 + i / w : U32), px)), j),
        j, w, y0)

def Px.map_xy(~P: Data, ~f: P -> U32 -> U32 -> U32 -> U32, +prm: P, +count: U32, +w: U32, +y0: U32,
  band: Array<U32>) -> Array<U32>:
  Px.map_xy_go(~P, ~f, prm, Nat.sub(U32.to_nat(count), 1n), Array.get(U32, band, 0), 0, w, y0)

# y0: first image row of this subtree; half: rows in its top half (the band
# tree is full and uniform, so each level knows it up front).
def Bands.map_xy(~P: Data, ~f: P -> U32 -> U32 -> U32 -> U32, bands: I.Bands<Array<U32>>, +prm: P, +w: U32,
  +y0: U32, +half: U32) -> I.Bands<Array<U32>>:
  match bands:
    case I.NoBand{}:
      I.NoBand{}
    case I.Band{+rows, band}:
      I.Band{rows, Px.map_xy(~P, ~f, prm, (w * rows : U32), w, y0, band)}
    case I.Split{+rows, top, bottom}:
      +h = (half / 2 : U32)
      t b = Bands.map_xy(~P, ~f, top, prm, w, y0, h) Bands.map_xy(~P, ~f, bottom, prm, w, (y0 + half : U32), h)
      I.Split{rows, t, b}

# Applies f(param, x, y, pixel) to every pixel, in place, bands in parallel.
def Mat.map_xy(~P: Data, ~f: P -> U32 -> U32 -> U32 -> U32, +prm: P, image: I.Mat) -> I.Mat:
  match image:
    case I.Mat{+w, +h, bands}:
      I.Mat{w, h, Bands.map_xy(~P, ~f, bands, prm, w, 0, I.Mat.top_half(w, h))}

# --- Per-pixel loops with a parameter only (no coordinate arithmetic) ----------------

def Px.map_p_go(~P: Data, ~f: P -> U32 -> U32, +prm: P, n: Nat, got: Array<U32> & U32, +i: U32) -> Array<U32>:
  match n:
    case 0n:
      (band, +px) = got
      Array.set(U32, band, i, f(prm, px))
    case 1n+p:
      (band, +px) = got
      +j = (i + 1 : U32)
      Px.map_p_go(~P, ~f, prm, p, Array.get(U32, Array.set(U32, band, i, f(prm, px)), j), j)

def Bands.map_p(~P: Data, ~f: P -> U32 -> U32, bands: I.Bands<Array<U32>>, +prm: P, +w: U32) -> I.Bands<Array<U32>>:
  match bands:
    case I.NoBand{}:
      I.NoBand{}
    case I.Band{+rows, band}:
      I.Band{rows, Px.map_p_go(~P, ~f, prm, Nat.sub(U32.to_nat((w * rows : U32)), 1n), Array.get(U32, band, 0), 0)}
    case I.Split{+rows, top, bottom}:
      t b = Bands.map_p(~P, ~f, top, prm, w) Bands.map_p(~P, ~f, bottom, prm, w)
      I.Split{rows, t, b}

# Applies f(param, pixel) to every pixel, in place, bands in parallel.
def Mat.map_with(~P: Data, ~f: P -> U32 -> U32, +prm: P, image: I.Mat) -> I.Mat:
  match image:
    case I.Mat{+w, h, bands}:
      I.Mat{w, h, Bands.map_p(~P, ~f, bands, prm, w)}

# --- Invert, fill, threshold --------------------------------------------------------

# OpenCV bitwise_not: every channel, alpha included, becomes 255 - value.
def Mat.invert(image: I.Mat) -> I.Mat:
  I.Mat.map(~(p => (p .^. 4294967295 : U32)), image)

# OpenCV setTo: every pixel becomes `color`.
def Mat.fill(image: I.Mat, +color: U32) -> I.Mat:
  Mat.map_with(~U32, ~(c => p => c), color, image)

type Thresh is Data:
  Thresh{level: U32, maxval: U32}

def Thr.channel(+c: U32, +level: U32, +maxval: U32) -> U32:
  U.pick(U32.is_gt(c, level), maxval, 0)

def Thr.pixel(t: Thresh, +p: U32) -> U32:
  match t:
    case Thresh{+level, +maxval}:
      I.Pixel.pack(Thr.channel(I.Pixel.r(p), level, maxval), Thr.channel(I.Pixel.g(p), level, maxval),
        Thr.channel(I.Pixel.b(p), level, maxval), Thr.channel(I.Pixel.a(p), level, maxval))

# OpenCV threshold, THRESH_BINARY, per channel (alpha included): a channel
# strictly above `level` becomes `maxval`, otherwise 0. Equal to level -> 0.
def Mat.threshold(image: I.Mat, +level: U32, +maxval: U32) -> I.Mat:
  Mat.map_with(~Thresh, ~(t => p => Thr.pixel(t, p)), Thresh{level, maxval}, image)

# --- Rectangle (drawing clips at the edge, as in OpenCV) ----------------------------

# Corners are inclusive and may come in any order, as in OpenCV. thickness 0
# means filled (OpenCV's FILLED, -1); otherwise an outline `thickness` wide,
# centred on the edge.
type Rect is Data:
  Rect{x1: U32, y1: U32, x2: U32, y2: U32, color: U32, thickness: U32}

def Draw.in_box(+x: U32, +y: U32, +l: U32, +t: U32, +r: U32, +b: U32) -> Bool:
  Bool.and(U.between(l, x, r), U.between(t, y, b))

def Draw.outline(+x: U32, +y: U32, +l: U32, +t: U32, +r: U32, +b: U32, +thick: U32) -> Bool:
  +lo = ((thick - 1) / 2 : U32)
  +hi = (thick / 2 : U32)
  Bool.and(Draw.in_box(x, y, U.sat_sub(l, lo), U.sat_sub(t, lo), (r + hi : U32), (b + hi : U32)),
    Bool.not(Bool.and(Bool.and(U32.is_gt(x, (l + hi : U32)), U32.is_lt((x + lo : U32), r)),
      Bool.and(U32.is_gt(y, (t + hi : U32)), U32.is_lt((y + lo : U32), b)))))

def Draw.covers_by(filled: Bool, +x: U32, +y: U32, +l: U32, +t: U32, +r: U32, +b: U32, +thick: U32) -> Bool:
  match filled:
    case True{}:
      Draw.in_box(x, y, l, t, r, b)
    case False{}:
      Draw.outline(x, y, l, t, r, b, thick)

def Draw.covers(r: Rect, +x: U32, +y: U32) -> Bool:
  match r:
    case Rect{+x1, +y1, +x2, +y2, _, +thick}:
      +l = U32.min(x1, x2)
      +t = U32.min(y1, y2)
      +rr = U32.max(x1, x2)
      +b = U32.max(y1, y2)
      Draw.covers_by(U32.is_eq(thick, 0), x, y, l, t, rr, b, thick)

def Draw.color(r: Rect) -> U32:
  match r:
    case Rect{_, _, _, _, color, _}:
      color

def Draw.rect_pixel(+r: Rect, +x: U32, +y: U32, +p: U32) -> U32:
  U.pick(Draw.covers(r, x, y), Draw.color(r), p)

# OpenCV rectangle. Only pixels inside the image are touched: a rectangle
# reaching past the edge is clipped, never wrapped.
def Mat.rectangle(image: I.Mat, +r: Rect) -> I.Mat:
  Mat.map_xy(~Rect, ~(rect => x => y => p => Draw.rect_pixel(rect, x, y, p)), r, image)

# --- Setting one pixel ---------------------------------------------------------------

def Bands.set_band(+rows: U32, band: Array<U32>) -> I.Bands<Array<U32>>:
  I.Band{rows, band}

def Bands.set_go(bands: I.Bands<Array<U32>>, below: Bool, +w: U32, +x: U32, +y: U32, +half: U32, +color: U32) ->
  I.Bands<Array<U32>>:
  match bands below:
    case I.NoBand{} _:
      I.NoBand{}
    case I.Band{+rows, band} _:
      I.Band{rows, Array.set(U32, band, (y * w + x : U32), color)}
    case I.Split{+rows, top, bottom} True{}:
      +h = (half / 2 : U32)
      I.Split{rows, Bands.set_go(top, U32.is_lt(y, h), w, x, y, h, color), bottom}
    case I.Split{+rows, top, bottom} False{}:
      +h = (half / 2 : U32)
      +y2 = (y - half : U32)
      I.Split{rows, top, Bands.set_go(bottom, U32.is_lt(y2, h), w, x, y2, h, color)}

def Mat.set_if(inside: Bool, +w: U32, +h: U32, bands: I.Bands<Array<U32>>, +x: U32, +y: U32, +color: U32) ->
  I.Mat & Bool:
  match inside:
    case True{}:
      +half = I.Mat.top_half(w, h)
      (I.Mat{w, h, Bands.set_go(bands, U32.is_lt(y, half), w, x, y, half, color)}, True{})
    case False{}:
      (I.Mat{w, h, bands}, False{})

# Sets pixel (x, y). A position outside the image is refused (False) and
# nothing changes.
def Mat.set(image: I.Mat, +x: U32, +y: U32, +color: U32) -> I.Mat & Bool:
  match image:
    case I.Mat{+w, +h, bands}:
      Mat.set_if(Bool.and(U32.is_lt(x, w), U32.is_lt(y, h)), w, h, bands, x, y, color)

# --- Horizontal flip (OpenCV flip code 1) ---------------------------------------------

def Flip.swap(got_b: Array<U32> & U32, +a: U32, +ia: U32, +ib: U32) -> Array<U32>:
  (band, +b) = got_b
  Array.set(U32, Array.set(U32, band, ia, b), ib, a)

def Flip.a_index(+k: U32, +w: U32, +half: U32) -> U32:
  ((k / half) * w + k % half : U32)

def Flip.b_index(+k: U32, +w: U32, +half: U32) -> U32:
  ((k / half) * w + (w - 1 - k % half) : U32)

# Pair k: row k / half, column k % half and its mirror; got = (band, left pixel).
def Flip.go(n: Nat, got: Array<U32> & U32, +k: U32, +w: U32, +half: U32) -> Array<U32>:
  match n:
    case 0n:
      (band, +a) = got
      Flip.swap(Array.get(U32, band, Flip.b_index(k, w, half)), a, Flip.a_index(k, w, half), Flip.b_index(k, w, half))
    case 1n+p:
      (band, +a) = got
      +next = (k + 1 : U32)
      Flip.go(p, Array.get(U32,
        Flip.swap(Array.get(U32, band, Flip.b_index(k, w, half)), a, Flip.a_index(k, w, half), Flip.b_index(k, w, half)),
        Flip.a_index(next, w, half)), next, w, half)

def Flip.band_if(skip: Bool, +rows: U32, +w: U32, band: Array<U32>) -> Array<U32>:
  match skip:
    case True{}:
      band
    case False{}:
      +half = (w / 2 : U32)
      Flip.go(Nat.sub(U32.to_nat((rows * half : U32)), 1n), Array.get(U32, band, 0), 0, w, half)

def Bands.flip_x(+w: U32, bands: I.Bands<Array<U32>>) -> I.Bands<Array<U32>>:
  match bands:
    case I.NoBand{}:
      I.NoBand{}
    case I.Band{+rows, band}:
      I.Band{rows, Flip.band_if(Bool.or(U32.is_lt(w, 2), U32.is_eq(rows, 0)), rows, w, band)}
    case I.Split{+rows, top, bottom}:
      t b = Bands.flip_x(w, top) Bands.flip_x(w, bottom)
      I.Split{rows, t, b}

# Mirrors the image left to right, in place.
def Mat.flip_x(image: I.Mat) -> I.Mat:
  match image:
    case I.Mat{+w, h, bands}:
      I.Mat{w, h, Bands.flip_x(w, bands)}

# --- Crop (refuses a rectangle past the edge: a project law) ------------------------
# Two parallel phases. 1: each source band cuts the crop rows it holds into
# fragments, split at the output bands' boundaries. 2: each output band joins
# its fragments (a single fragment is used as is). Copies are indexed loops.

type Frag is Type:
  Frag{rows: U32, px: Array<U32>}

def Crop.copy(n: Nat, got: Array<U32> & U32, dst: Array<U32>, +j: U32, +sr: U32, +x: U32, +w: U32, +cw: U32) ->
  Array<U32> & Array<U32>:
  match n:
    case 0n:
      (src, +v) = got
      (src, Array.set(U32, dst, j, v))
    case 1n+p:
      (src, +v) = got
      +next = (j + 1 : U32)
      Crop.copy(p, Array.get(U32, src, ((sr + next / cw) * w + x + next % cw : U32)), Array.set(U32, dst, j, v),
        next, sr, x, w, cw)

def Crop.frag_done(+rows: U32, copied: Array<U32> & Array<U32>) -> Array<U32> & Frag:
  (src, dst) = copied
  (src, Frag{rows, dst})

# rows x cw pixels from source band row sr, column x, as a fragment.
def Crop.frag(src: Array<U32>, +rows: U32, +sr: U32, +x: U32, +w: U32, +cw: U32) -> Array<U32> & Frag:
  +count = (rows * cw : U32)
  Crop.frag_done(rows, Crop.copy(Nat.sub(U32.to_nat(count), 1n), Array.get(U32, src, (sr * w + x : U32)),
    Array.new(U32, I.Px.slots(count), 0), 0, sr, x, w, cw))

def Crop.cons(f: Frag, rest: Array<U32> & List<Frag>) -> Array<U32> & List<Frag>:
  (src, fs) = rest
  (src, Con{f, fs})

def Crop.then(made: Array<U32> & Frag, rest: Array<U32> -> Array<U32> & List<Frag>) -> Array<U32> & List<Frag>:
  (src, f) = made
  Crop.cons(f, rest(src))

def Crop.frags_if(done: Bool, src: Array<U32>, +rows: U32, +sr: U32, +x: U32, +w: U32, +cw: U32,
  rest: Array<U32> -> Array<U32> & List<Frag>) -> Array<U32> & List<Frag>:
  match done:
    case True{}:
      (src, Nil{})
    case False{}:
      Crop.then(Crop.frag(src, rows, sr, x, w, cw), rest)

# Crop rows cur..end (crop coordinates) held by this band, cut at multiples of
# per_out (the output band height). y: crop top in the image; y0: band's first row.
def Crop.frags(n: Nat, src: Array<U32>, +cur: U32, +end: U32, +y: U32, +y0: U32, +x: U32, +w: U32, +cw: U32,
  +per_out: U32) -> Array<U32> & List<Frag>:
  match n:
    case 0n:
      (src, Nil{})
    case 1n+p:
      +stop = U32.min(end, ((cur / per_out + 1) * per_out : U32))
      Crop.frags_if(U32.is_ge(cur, end), src, (stop - U32.min(cur, stop) : U32), (cur + y - y0 : U32), x, w, cw,
        s => Crop.frags(p, s, stop, end, y, y0, x, w, cw, per_out))

def Crop.leaf_done(+rows: U32, cut: Array<U32> & List<Frag>) -> I.Bands<Array<U32>> & List<Frag>:
  (band, fs) = cut
  (I.Band{rows, band}, fs)

def Crop.leaf(+rows: U32, band: Array<U32>, +y0: U32, +x: U32, +y: U32, +ch: U32, +w: U32, +cw: U32, +per_out: U32) ->
  I.Bands<Array<U32>> & List<Frag>:
  +lo = U32.max(y, y0)
  +hi = U32.max(lo, U32.min((y + ch : U32), (y0 + rows : U32)))
  Crop.leaf_done(rows, Crop.frags(256n, band, (lo - y : U32), (hi - y : U32), y, y0, x, w, cw, per_out))

def Crop.split_done(+rows: U32, top: I.Bands<Array<U32>> & List<Frag>, bottom: I.Bands<Array<U32>> & List<Frag>) ->
  I.Bands<Array<U32>> & List<Frag>:
  (t, ft) = top
  (b, fb) = bottom
  (I.Split{rows, t, b}, List.append(&1, Frag, ft, fb))

# Phase 1, bands in parallel: every fragment of the crop, top to bottom.
def Crop.extract(bands: I.Bands<Array<U32>>, +y0: U32, +half: U32, +x: U32, +y: U32, +ch: U32, +w: U32, +cw: U32,
  +per_out: U32) -> I.Bands<Array<U32>> & List<Frag>:
  match bands:
    case I.NoBand{}:
      (I.NoBand{}, Nil{})
    case I.Band{+rows, band}:
      Crop.leaf(rows, band, y0, x, y, ch, w, cw, per_out)
    case I.Split{+rows, top, bottom}:
      +h = (half / 2 : U32)
      t b = Crop.extract(top, y0, h, x, y, ch, w, cw, per_out) Crop.extract(bottom, (y0 + half : U32), h, x, y, ch, w, cw, per_out)
      Crop.split_done(rows, t, b)

def Crop.prepend(f: Frag, taken: List<Frag> & List<Frag>) -> List<Frag> & List<Frag>:
  (fs, rest) = taken
  (Con{f, fs}, rest)

# Fragments from the front adding up to `need` rows (fragments never straddle
# an output band, so they add up exactly).
def Crop.take_rows(frags: List<Frag>, need: Nat) -> List<Frag> & List<Frag>:
  match frags need:
    case _ 0n:
      (Nil{}, frags)
    case Nil{} _:
      (Nil{}, Nil{})
    case Con{Frag{+rows, px}, rest} _:
      Crop.prepend(Frag{rows, px}, Crop.take_rows(rest, Nat.sub(need, U32.to_nat(rows))))

def Crop.out_cons(+rows: U32, taken: List<Frag> & List<Frag>, rest: List<Frag> -> List<(U32 & List<Frag>)>) ->
  List<(U32 & List<Frag>)>:
  (mine, left) = taken
  Con{(rows, mine), rest(left)}

def Mat.rows_in(+k: U32, +per_band: U32, +height: U32) -> U32:
  +y0 = U32.min(height, (k * per_band : U32))
  (U32.min(height, (y0 + per_band : U32)) - y0 : U32)

# Output band k: (rows, its fragments), for every output band.
def Crop.outputs(n: Nat, frags: List<Frag>, +k: U32, +per_out: U32, +ch: U32) -> List<(U32 & List<Frag>)>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      +rows = Mat.rows_in(k, per_out, ch)
      Crop.out_cons(rows, Crop.take_rows(frags, U32.to_nat(rows)),
        left => Crop.outputs(p, left, (k + 1 : U32), per_out, ch))

def Crop.cp(n: Nat, got: Array<U32> & U32, dst: Array<U32>, +j: U32, +off: U32) -> Array<U32>:
  match n:
    case 0n:
      (src, +v) = got
      Array.set(U32, dst, (off + j : U32), v)
    case 1n+p:
      (src, +v) = got
      Crop.cp(p, Array.get(U32, src, (j + 1 : U32)), Array.set(U32, dst, (off + j : U32), v), (j + 1 : U32), off)

def Crop.into_if(empty: Bool, src: Array<U32>, dst: Array<U32>, +off: U32, +count: U32) -> Array<U32>:
  match empty:
    case True{}:
      dst
    case False{}:
      Crop.cp(Nat.sub(U32.to_nat(count), 1n), Array.get(U32, src, 0), dst, 0, off)

def Crop.concat_into(frags: List<Frag>, dst: Array<U32>, +off: U32, +cw: U32) -> Array<U32>:
  match frags:
    case Nil{}:
      dst
    case Con{Frag{+rows, px}, rest}:
      +count = (rows * cw : U32)
      Crop.concat_into(rest, Crop.into_if(U32.is_eq(count, 0), px, dst, off, count), (off + count : U32), cw)

# One output band from its fragments.
def Crop.concat(frags: List<Frag>, +rows: U32, +cw: U32) -> Array<U32>:
  match frags:
    case Con{Frag{_, px}, Nil{}}:
      px
    case _:
      Crop.concat_into(frags, Array.new(U32, I.Px.slots((rows * cw : U32)), 0), 0, cw)

# Phase 2, output bands in parallel.
def Crop.join(bands: I.Bands<List<Frag>>, +cw: U32) -> I.Bands<Array<U32>>:
  match bands:
    case I.NoBand{}:
      I.NoBand{}
    case I.Band{+rows, frags}:
      I.Band{rows, Crop.concat(frags, rows, cw)}
    case I.Split{+rows, top, bottom}:
      t b = Crop.join(top, cw) Crop.join(bottom, cw)
      I.Split{rows, t, b}

def Crop.assemble(+w: U32, +h: U32, +cw: U32, +ch: U32, extracted: I.Bands<Array<U32>> & List<Frag>) ->
  I.Mat & Maybe<&1, I.Mat>:
  (bands, frags) = extracted
  +per_out = I.Mat.rows_per_band(cw, ch)
  (I.Mat{w, h, bands}, Some{I.Mat{cw, ch, Crop.join(I.Bands.build(List<Frag>, I.Mat.band_depth(cw, ch),
    Crop.outputs(U32.to_nat(I.Mat.band_count(cw, ch)), frags, 0, per_out, ch)), cw)}})

def Crop.within(+x: U32, +y: U32, +cw: U32, +ch: U32, +w: U32, +h: U32) -> Bool:
  Bool.and(Bool.and(U32.is_gt(cw, 0), U32.is_gt(ch, 0)),
    Bool.and(Bool.and(U32.is_le(cw, w), U32.is_le(x, (w - cw : U32))),
      Bool.and(U32.is_le(ch, h), U32.is_le(y, (h - ch : U32)))))

def Crop.if_within(ok: Bool, +w: U32, +h: U32, bands: I.Bands<Array<U32>>, +x: U32, +y: U32, +cw: U32, +ch: U32) ->
  I.Mat & Maybe<&1, I.Mat>:
  match ok:
    case True{}:
      Crop.assemble(w, h, cw, ch,
        Crop.extract(bands, 0, I.Mat.top_half(w, h), x, y, ch, w, cw, I.Mat.rows_per_band(cw, ch)))
    case False{}:
      (I.Mat{w, h, bands}, None{})

# The cw x ch region whose top-left corner is (x, y), as a new Mat; pixel
# (i, j) of the crop is pixel (x + i, y + j) of the image. A region that
# reaches past the edge (or is empty) is refused: None, image unchanged.
def Mat.crop(image: I.Mat, +x: U32, +y: U32, +cw: U32, +ch: U32) -> I.Mat & Maybe<&1, I.Mat>:
  match image:
    case I.Mat{+w, +h, bands}:
      Crop.if_within(Crop.within(x, y, cw, ch, w, h), w, h, bands, x, y, cw, ch)

# --- Histogram of brightness (256 bins) ------------------------------------------------

def Hist.bump(got: Array<U32> & U32, +bin: U32) -> Array<U32>:
  (counts, +c) = got
  Array.set(U32, counts, bin, (c + 1 : U32))

def Hist.count(n: Nat, got: Array<U32> & U32, counts: Array<U32>, +i: U32) -> Array<U32> & Array<U32>:
  match n:
    case 0n:
      (band, +p) = got
      +bin = I.Pixel.luma(p)
      (band, Hist.bump(Array.get(U32, counts, bin), bin))
    case 1n+q:
      (band, +p) = got
      +bin = I.Pixel.luma(p)
      +next = (i + 1 : U32)
      Hist.count(q, Array.get(U32, band, next), Hist.bump(Array.get(U32, counts, bin), bin), next)

def Hist.add_into(got_a: Array<U32> & U32, b: Array<U32>, +i: U32, +v: U32) -> Array<U32> & Array<U32>:
  (a, +u) = got_a
  (Array.set(U32, a, i, (u + v : U32)), b)

def Hist.add_one(got_b: Array<U32> & U32, a: Array<U32>, +i: U32) -> Array<U32> & Array<U32>:
  (b, +v) = got_b
  Hist.add_into(Array.get(U32, a, i), b, i, v)

def Hist.first(pair: Array<U32> & Array<U32>) -> Array<U32>:
  (a, b) = pair
  a

def Hist.add_go(n: Nat, pair: Array<U32> & Array<U32>, +i: U32) -> Array<U32>:
  match n:
    case 0n:
      (a, b) = pair
      Hist.first(Hist.add_one(Array.get(U32, b, i), a, i))
    case 1n+q:
      (a, b) = pair
      Hist.add_go(q, Hist.add_one(Array.get(U32, b, i), a, i), (i + 1 : U32))

# Adds the counts of b into a.
def Hist.add(a: Array<U32>, b: Array<U32>) -> Array<U32>:
  Hist.add_go(255n, (a, b), 0)

def Hist.empty() -> Array<U32>:
  Array.new(U32, 8n, 0)

def Hist.band_done(+rows: U32, counted: Array<U32> & Array<U32>) -> I.Bands<Array<U32>> & Array<U32>:
  (band, counts) = counted
  (I.Band{rows, band}, counts)

def Hist.band_if(empty: Bool, +rows: U32, +w: U32, band: Array<U32>) -> I.Bands<Array<U32>> & Array<U32>:
  match empty:
    case True{}:
      (I.Band{rows, band}, Hist.empty())
    case False{}:
      Hist.band_done(rows, Hist.count(Nat.sub(U32.to_nat((w * rows : U32)), 1n), Array.get(U32, band, 0),
        Hist.empty(), 0))

def Hist.split_done(+rows: U32, top: I.Bands<Array<U32>> & Array<U32>, bottom: I.Bands<Array<U32>> & Array<U32>) ->
  I.Bands<Array<U32>> & Array<U32>:
  (t, a) = top
  (b, c) = bottom
  (I.Split{rows, t, b}, Hist.add(a, c))

def Bands.histogram(+w: U32, bands: I.Bands<Array<U32>>) -> I.Bands<Array<U32>> & Array<U32>:
  match bands:
    case I.NoBand{}:
      (I.NoBand{}, Hist.empty())
    case I.Band{+rows, band}:
      Hist.band_if(U32.is_eq(rows, 0), rows, w, band)
    case I.Split{+rows, top, bottom}:
      t b = Bands.histogram(w, top) Bands.histogram(w, bottom)
      Hist.split_done(rows, t, b)

def Hist.with_mat(+w: U32, +h: U32, counted: I.Bands<Array<U32>> & Array<U32>) -> I.Mat & Array<U32>:
  (bands, counts) = counted
  (I.Mat{w, h, bands}, counts)

# How many pixels have each brightness (luma 0..255): 256 counts. The image
# is handed back unchanged.
def Mat.histogram(image: I.Mat) -> I.Mat & Array<U32>:
  match image:
    case I.Mat{+w, +h, bands}:
      Hist.with_mat(w, h, Bands.histogram(w, bands))

# --- Small readers for laws and examples ----------------------------------------------

def Hist.total_go(n: Nat, got: Array<U32> & U32, +i: U32, +acc: U32) -> U32:
  match n:
    case 0n:
      (counts, +c) = got
      (acc + c : U32)
    case 1n+q:
      (counts, +c) = got
      Hist.total_go(q, Array.get(U32, counts, (i + 1 : U32)), (i + 1 : U32), (acc + c : U32))

# The sum of all 256 counts.
def Hist.total(counts: Array<U32>) -> U32:
  Hist.total_go(255n, Array.get(U32, counts, 0), 0, 0)

def Hist.second(pair: Array<U32> & U32) -> U32:
  (counts, c) = pair
  c

# The count in one bin.
def Hist.bin(counts: Array<U32>, +i: U32) -> U32:
  Hist.second(Array.get(U32, counts, i))

def Mat.counts(pair: I.Mat & Array<U32>) -> Array<U32>:
  (image, counts) = pair
  counts

def Mat.ok(pair: I.Mat & Bool) -> Bool:
  (image, ok) = pair
  ok

def Mat.image(pair: I.Mat & Bool) -> I.Mat:
  (image, ok) = pair
  image

def Mat.cropped(pair: I.Mat & Maybe<&1, I.Mat>) -> Maybe<&1, I.Mat>:
  (image, crop) = pair
  crop

def Mat.refused(crop: Maybe<&1, I.Mat>) -> Bool:
  match crop:
    case None{}:
      True{}
    case Some{image}:
      False{}

# Pixel (x, y) of a crop, or 0 when the crop was refused.
def Mat.crop_pixel(crop: Maybe<&1, I.Mat>, +x: U32, +y: U32) -> U32:
  match crop:
    case None{}:
      0
    case Some{image}:
      I.Mat.pixel_at(image, x, y)

def Hist.keep_total_go(n: Nat, got: Array<U32> & U32, +i: U32, +acc: U32) -> Array<U32> & U32:
  match n:
    case 0n:
      (counts, +c) = got
      (counts, (acc + c : U32))
    case 1n+q:
      (counts, +c) = got
      Hist.keep_total_go(q, Array.get(U32, counts, (i + 1 : U32)), (i + 1 : U32), (acc + c : U32))

def Hist.summary_b(got: Array<U32> & U32, +total: U32, +ca: U32, +b: U32, +c: U32) -> U32 & U32 & U32 & U32:
  (counts, +cb) = got
  (total, (ca, (cb, Hist.bin(counts, c))))

def Hist.summary_a(got: Array<U32> & U32, +total: U32, +b: U32, +c: U32) -> U32 & U32 & U32 & U32:
  (counts, +ca) = got
  Hist.summary_b(Array.get(U32, counts, b), total, ca, b, c)

def Hist.summary_t(counted: Array<U32> & U32, +a: U32, +b: U32, +c: U32) -> U32 & U32 & U32 & U32:
  (counts, +total) = counted
  Hist.summary_a(Array.get(U32, counts, a), total, b, c)

# (total of all counts, count in bin a, in bin b, in bin c), reading the
# counts once.
def Hist.summary(counts: Array<U32>, +a: U32, +b: U32, +c: U32) -> U32 & U32 & U32 & U32:
  Hist.summary_t(Hist.keep_total_go(255n, Array.get(U32, counts, 0), 0, 0), a, b, c)

# --- Downscale by an integer factor (OpenCV resize, INTER_AREA) ------------------------
# Each output pixel is the average of a k x k block. Output size is
# (width / k) x (height / k), rounded down. k must divide 16 (1, 2, 4, 8, 16),
# so a block never straddles two source bands; source bands produce output
# fragments cut at the output bands' edges, and output bands join them (the
# crop pipeline).

# Sums two channels per U32: red and blue in the 16-bit lanes of one word,
# green and alpha in the other (a 16x16 block sums to at most 65280, so the
# lanes never overflow). No allocation per pixel.
def Down.lanes(+p: U32) -> U32:
  (p .&. 16711935 : U32)

def Down.mean_lanes(+rb: U32, +ga: U32, +n: U32) -> U32:
  +h = (n / 2 : U32)
  I.Pixel.pack((((rb .&. 65535) + h) / n : U32), (((ga .&. 65535) + h) / n : U32),
    (((rb >> 16n) + h) / n : U32), (((ga >> 16n) + h) / n : U32))

# Block pixel i (row i / k, column i % k) from source index base.
def Down.at(+base: U32, +i: U32, +w: U32, +k: U32) -> U32:
  (base + (i / k) * w + i % k : U32)

def Down.block(n: Nat, got: Array<U32> & U32, +rb: U32, +ga: U32, +i: U32, +base: U32, +w: U32, +k: U32) ->
  Array<U32> & U32:
  match n:
    case 0n:
      (src, +p) = got
      (src, Down.mean_lanes((rb + Down.lanes(p) : U32), (ga + Down.lanes((p >> 8n : U32)) : U32), (k * k : U32)))
    case 1n+q:
      (src, +p) = got
      +next = (i + 1 : U32)
      Down.block(q, Array.get(U32, src, Down.at(base, next, w, k)), (rb + Down.lanes(p) : U32),
        (ga + Down.lanes((p >> 8n : U32)) : U32), next, base, w, k)

# The averaged output pixel whose block starts at source index base.
def Down.pixel(src: Array<U32>, +base: U32, +w: U32, +k: U32) -> Array<U32> & U32:
  Down.block(Nat.sub(U32.to_nat((k * k : U32)), 1n), Array.get(U32, src, base), 0, 0, 0, base, w, k)

# Source index of the block for output pixel j of a fragment starting at band row sr.
def Down.base(+j: U32, +sr: U32, +w: U32, +wo: U32, +k: U32) -> U32:
  ((sr + (j / wo) * k) * w + (j % wo) * k : U32)

def Down.copy(n: Nat, got: Array<U32> & U32, dst: Array<U32>, +j: U32, +sr: U32, +w: U32, +wo: U32, +k: U32) ->
  Array<U32> & Array<U32>:
  match n:
    case 0n:
      (src, +v) = got
      (src, Array.set(U32, dst, j, v))
    case 1n+p:
      (src, +v) = got
      +next = (j + 1 : U32)
      Down.copy(p, Down.pixel(src, Down.base(next, sr, w, wo, k), w, k), Array.set(U32, dst, j, v), next, sr, w, wo, k)

def Down.frag(src: Array<U32>, +rows: U32, +sr: U32, +w: U32, +wo: U32, +k: U32) -> Array<U32> & Frag:
  +count = (rows * wo : U32)
  Crop.frag_done(rows, Down.copy(Nat.sub(U32.to_nat(count), 1n), Down.pixel(src, Down.base(0, sr, w, wo, k), w, k),
    Array.new(U32, I.Px.slots(count), 0), 0, sr, w, wo, k))

def Down.frags_if(done: Bool, src: Array<U32>, +rows: U32, +sr: U32, +w: U32, +wo: U32, +k: U32,
  rest: Array<U32> -> Array<U32> & List<Frag>) -> Array<U32> & List<Frag>:
  match done:
    case True{}:
      (src, Nil{})
    case False{}:
      Crop.then(Down.frag(src, rows, sr, w, wo, k), rest)

# Output rows cur..end held by this band (y0: its first source row), cut at
# multiples of per_out.
def Down.frags(n: Nat, src: Array<U32>, +cur: U32, +end: U32, +y0: U32, +w: U32, +wo: U32, +k: U32, +per_out: U32) ->
  Array<U32> & List<Frag>:
  match n:
    case 0n:
      (src, Nil{})
    case 1n+p:
      +stop = U32.min(end, ((cur / per_out + 1) * per_out : U32))
      Down.frags_if(U32.is_ge(cur, end), src, (stop - U32.min(cur, stop) : U32), (cur * k - U32.min(y0, (cur * k : U32)) : U32),
        w, wo, k, s => Down.frags(p, s, stop, end, y0, w, wo, k, per_out))

def Down.leaf(+rows: U32, band: Array<U32>, +y0: U32, +w: U32, +wo: U32, +ho: U32, +k: U32, +per_out: U32) ->
  I.Bands<Array<U32>> & List<Frag>:
  +first = (y0 / k : U32)
  +last = U32.max(first, U32.min(ho, ((y0 + rows) / k : U32)))
  Crop.leaf_done(rows, Down.frags(256n, band, first, last, y0, w, wo, k, per_out))

def Down.extract(bands: I.Bands<Array<U32>>, +y0: U32, +half: U32, +w: U32, +wo: U32, +ho: U32, +k: U32, +per_out: U32) ->
  I.Bands<Array<U32>> & List<Frag>:
  match bands:
    case I.NoBand{}:
      (I.NoBand{}, Nil{})
    case I.Band{+rows, band}:
      Down.leaf(rows, band, y0, w, wo, ho, k, per_out)
    case I.Split{+rows, top, bottom}:
      +h = (half / 2 : U32)
      t b = Down.extract(top, y0, h, w, wo, ho, k, per_out) Down.extract(bottom, (y0 + half : U32), h, w, wo, ho, k, per_out)
      Crop.split_done(rows, t, b)

def Down.assemble(+w: U32, +h: U32, +wo: U32, +ho: U32, extracted: I.Bands<Array<U32>> & List<Frag>) ->
  I.Mat & Maybe<&1, I.Mat>:
  (bands, frags) = extracted
  +per_out = I.Mat.rows_per_band(wo, ho)
  (I.Mat{w, h, bands}, Some{I.Mat{wo, ho, Crop.join(I.Bands.build(List<Frag>, I.Mat.band_depth(wo, ho),
    Crop.outputs(U32.to_nat(I.Mat.band_count(wo, ho)), frags, 0, per_out, ho)), wo)}})

def Down.valid(+k: U32, +w: U32, +h: U32) -> Bool:
  Bool.and(Bool.and(U32.is_gt(k, 0), U32.is_eq((16 % k : U32), 0)),
    Bool.and(U32.is_ge(w, k), U32.is_ge(h, k)))

def Down.if_valid(ok: Bool, +w: U32, +h: U32, bands: I.Bands<Array<U32>>, +k: U32) -> I.Mat & Maybe<&1, I.Mat>:
  match ok:
    case True{}:
      +wo = (w / k : U32)
      +ho = (h / k : U32)
      Down.assemble(w, h, wo, ho, Down.extract(bands, 0, I.Mat.top_half(w, h), w, wo, ho, k, I.Mat.rows_per_band(wo, ho)))
    case False{}:
      (I.Mat{w, h, bands}, None{})

# The image shrunk k times (each output pixel the rounded average of a k x k
# block), as a new Mat; the original is handed back. Refused (None) unless k
# divides 16 and the image is at least k pixels each way.
def Mat.downscale(image: I.Mat, +k: U32) -> I.Mat & Maybe<&1, I.Mat>:
  match image:
    case I.Mat{+w, +h, bands}:
      Down.if_valid(Down.valid(k, w, h), w, h, bands, k)
