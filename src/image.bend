import Base

# Images in Bend. An image is split into horizontal bands of rows; each band
# is its own Array<U32> (one RGBA pixel per U32), and the bands form a
# balanced tree so work on them runs in parallel. Splitting an Array by
# `match` copies it, while separate bands split for free, which is why bands
# are made when a frame is copied in rather than later.
# Pure module: no effects, so LAWS.bend can import it.

# --- Pixels: RGBA packed in a U32 -------------------------------------------
# Every Mat is RGBA (a project law): red in the low byte, so the bytes in
# memory read R, G, B, A. Cameras deliver BGRA; the copy-in swaps red and
# blue as Bend asks (Mat.swap_from_camera), and publishing swaps back.

def Pixel.r(+p: U32) -> U32:
  (p .&. 255 : U32)

def Pixel.g(+p: U32) -> U32:
  ((p >> 8n) .&. 255 : U32)

def Pixel.b(+p: U32) -> U32:
  ((p >> 16n) .&. 255 : U32)

def Pixel.a(+p: U32) -> U32:
  (p >> 24n : U32)

def Pixel.pack(+r: U32, +g: U32, +b: U32, +a: U32) -> U32:
  (r .|. (g << 8n) .|. (b << 16n) .|. (a << 24n) : U32)

# --- Bands: a balanced tree of row bands ------------------------------------

# rows: how many image rows a band (or a whole subtree) holds.
type Bands<-A: Type> is Type:
  NoBand{}
  Band{rows: U32, band: A}
  Split{rows: U32, top: Bands<A>, bottom: Bands<A>}

# --- Mat: the image type (OpenCV's name) ------------------------------------------------------------------

type Mat is Type:
  Mat{width: U32, height: U32, bands: Bands<Array<U32>>}

# Frames arrive BGRA; asking native code to swap red and blue (1) makes them RGBA.
def Mat.swap_from_camera() -> U32:
  1

# Rec. 601 luma, 0..255.
def Pixel.luma(+p: U32) -> U32:
  ((77 * Pixel.r(p) + 150 * Pixel.g(p) + 29 * Pixel.b(p)) >> 8n : U32)

def Pixel.gray(+p: U32) -> U32:
  +y = Pixel.luma(p)
  Pixel.pack(y, y, y, 255)

def Bands.rows(-A: Type, bands: Bands<A>) -> Bands<A> & U32:
  match bands:
    case NoBand{}:
      (NoBand{}, 0)
    case Band{+rows, band}:
      (Band{rows, band}, rows)
    case Split{+rows, top, bottom}:
      (Split{rows, top, bottom}, rows)

def Bands.join_counted(-A: Type, top: Bands<A> & U32, bottom: Bands<A> & U32) -> Bands<A>:
  (t, +x) = top
  (b, +y) = bottom
  Split{(x + y : U32), t, b}

def Bands.join(-A: Type, top: Bands<A>, bottom: Bands<A>) -> Bands<A>:
  Bands.join_counted(A, Bands.rows(A, top), Bands.rows(A, bottom))

# One tree level up: joins neighbours pairwise.
def Bands.pair_up(-A: Type, level: List<Bands<A>>) -> List<Bands<A>>:
  match level:
    case Con{top, Con{bottom, rest}}:
      Con{Bands.join(A, top, bottom), Bands.pair_up(A, rest)}
    case Con{one, Nil{}}:
      Con{one, Nil{}}
    case Nil{}:
      Nil{}

def Bands.first(-A: Type, level: List<Bands<A>>) -> Bands<A>:
  match level:
    case Con{one, _}:
      one
    case Nil{}:
      NoBand{}

def Bands.leaf(-A: Type, piece: U32 & A) -> Bands<A>:
  (rows, band) = piece
  Band{rows, band}

def Bands.leaves(-A: Type, pieces: List<(U32 & A)>) -> List<Bands<A>>:
  match pieces:
    case Nil{}:
      Nil{}
    case Con{piece, rest}:
      Con{Bands.leaf(A, piece), Bands.leaves(A, rest)}

def Bands.build_level(-A: Type, depth: Nat, level: List<Bands<A>>) -> Bands<A>:
  match depth:
    case 0n:
      Bands.first(A, level)
    case 1n+d:
      Bands.build_level(A, d, Bands.pair_up(A, level))

# Exactly n leaves: the given ones, then empty bands. A full tree keeps every
# Split's top half at a predictable number of bands (Mat.get relies on it).
def Bands.fill(-A: Type, n: Nat, level: List<Bands<A>>) -> List<Bands<A>>:
  match n level:
    case 0n _:
      Nil{}
    case 1n+p Con{one, rest}:
      Con{one, Bands.fill(A, p, rest)}
    case 1n+p Nil{}:
      Con{NoBand{}, Bands.fill(A, p, Nil{})}

# Up to 2^depth (rows, band) pieces, top to bottom, as a full balanced tree.
def Bands.build(-A: Type, +depth: Nat, pieces: List<(U32 & A)>) -> Bands<A>:
  Bands.build_level(A, depth, Bands.fill(A, Nat.pow(2n, depth), Bands.leaves(A, pieces)))

# The (rows, band) pieces, top to bottom, without padding: the inverse of build.
def Bands.pieces(-A: Type, bands: Bands<A>) -> List<(U32 & A)>:
  match bands:
    case NoBand{}:
      Nil{}
    case Band{+rows, band}:
      [(rows, band)]
    case Split{_, top, bottom}:
      List.append(&1, (U32 & A), Bands.pieces(A, top), Bands.pieces(A, bottom))

# The band contents, top to bottom.
def Bands.contents(-A: Type, bands: Bands<A>) -> List<A>:
  match bands:
    case NoBand{}:
      Nil{}
    case Band{_, band}:
      [band]
    case Split{_, top, bottom}:
      List.append(&1, A, Bands.contents(A, top), Bands.contents(A, bottom))

# How many bands an image has: more for bigger images, so the work spreads
# evenly over fast and slow cores (each band is one task, and Bend never moves
# a task once started). 2^depth bands: 8 up to 1.5 MP, 16 up to 3 MP, 32 up to
# 6 MP, 64 beyond (4K, 8K).
def Mat.depth_by(small: Bool, medium: Bool, large: Bool) -> Nat:
  match small medium large:
    case True{} _ _:
      3n
    case False{} True{} _:
      4n
    case False{} False{} True{}:
      5n
    case False{} False{} False{}:
      6n

def Mat.band_depth(+width: U32, +height: U32) -> Nat:
  +px = (width * height : U32)
  Mat.depth_by(U32.is_le(px, 1572864), U32.is_le(px, 3145728), U32.is_le(px, 6291456))

def Mat.band_count(+width: U32, +height: U32) -> U32:
  U32.from_nat(Nat.pow(2n, Mat.band_depth(width, height)))

# --- Building a Mat in Bend ---------------------------------------------------

# An array holding `count` pixels: 2^k slots, the fewest that fit.
def Px.slots_if(one: Bool, +count: U32) -> Nat:
  match one:
    case True{}:
      0n
    case False{}:
      1n+U32.log2((count - 1 : U32))

def Px.slots(+count: U32) -> Nat:
  Px.slots_if(U32.is_le(count, 1), count)

# Rows per band. Start from the height split over band_count bands, rounded
# up to a multiple of 16 (JPEG's 16x16 macroblocks never straddle bands).
# A band's array has a power-of-two number of slots, so then grow the band,
# 16 rows at a time, while it still fits the same array: at 8K that is 128
# rows (94% of the slots used) instead of 80 (59%). The last band may be
# shorter, and trailing bands may be empty.
def Mat.rows_per_band(+width: U32, +height: U32) -> U32:
  +count = Mat.band_count(width, height)
  +share = ((height + count - 1) / count : U32)
  +rows = ((share + 15) / 16 * 16 : U32)
  +slots = U32.from_nat(Nat.pow(2n, Px.slots((width * rows : U32))))
  +fit = ((slots / U32.max(1, (width * 16 : U32))) * 16 : U32)
  U32.max(rows, U32.min(fit, ((height + 15) / 16 * 16 : U32)))

# Rows in the top half of the band tree (every level halves it).
def Mat.top_half(+width: U32, +height: U32) -> U32:
  (Mat.rows_per_band(width, height) * (Mat.band_count(width, height) / 2) : U32)

def Mat.from_bands(+width: U32, +height: U32, pieces: List<(U32 & Array<U32>)>) -> Mat:
  Mat{width, height, Bands.build(Array<U32>, Mat.band_depth(width, height), pieces)}

def Mat.size(image: Mat) -> Mat & (U32 & U32):
  match image:
    case Mat{+w, +h, bands}:
      (Mat{w, h, bands}, (w, h))

# --- Per-pixel loops inside one band (indexed: no copies) --------------------

# `got` is the previous read (band, pixel), the way Base's Array.map loops.
def Px.map_go(~f: U32 -> U32, n: Nat, got: Array<U32> & U32, +i: U32) -> Array<U32>:
  match n:
    case 0n:
      (band, +px) = got
      Array.set(U32, band, i, f(px))
    case 1n+p:
      (band, +px) = got
      +j = (i + 1 : U32)
      Px.map_go(~f, p, Array.get(U32, Array.set(U32, band, i, f(px)), j), j)

# Rewrites the first `count` pixels in place.
def Px.map(~f: U32 -> U32, +count: U32, band: Array<U32>) -> Array<U32>:
  Px.map_go(~f, Nat.sub(U32.to_nat(count), 1n), Array.get(U32, band, 0), 0)

def Px.sum_go(~f: U32 -> U32, n: Nat, got: Array<U32> & U32, +i: U32, acc: U32) -> Array<U32> & U32:
  match n:
    case 0n:
      (band, +px) = got
      (band, (acc + f(px) : U32))
    case 1n+p:
      (band, +px) = got
      +j = (i + 1 : U32)
      Px.sum_go(~f, p, Array.get(U32, band, j), j, (acc + f(px) : U32))

# Sums f over the first `count` pixels; hands the band back.
def Px.sum(~f: U32 -> U32, +count: U32, band: Array<U32>) -> Array<U32> & U32:
  Px.sum_go(~f, Nat.sub(U32.to_nat(count), 1n), Array.get(U32, band, 0), 0, 0)

# --- Whole-image operations (bands in parallel) ------------------------------

def Bands.map_px(~f: U32 -> U32, +width: U32, bands: Bands<Array<U32>>) -> Bands<Array<U32>>:
  match bands:
    case NoBand{}:
      NoBand{}
    case Band{+rows, band}:
      Band{rows, Px.map(~f, (width * rows : U32), band)}
    case Split{+rows, top, bottom}:
      t b = Bands.map_px(~f, width, top) Bands.map_px(~f, width, bottom)
      Split{rows, t, b}

# A band's sum fits in a U32 (at most 2^22 pixels of up to 255 each); bands
# are added as Nat, so whole 8K images (33 Mpx) do not overflow.
def Bands.sum_band(+rows: U32, counted: Array<U32> & U32) -> Bands<Array<U32>> & Nat:
  (band, total) = counted
  (Band{rows, band}, U32.to_nat(total))

def Bands.sum_split(+rows: U32, top: Bands<Array<U32>> & Nat, bottom: Bands<Array<U32>> & Nat) ->
  Bands<Array<U32>> & Nat:
  (t, x) = top
  (b, y) = bottom
  (Split{rows, t, b}, Nat.add(x, y))

def Bands.sum_px(~f: U32 -> U32, +width: U32, bands: Bands<Array<U32>>) -> Bands<Array<U32>> & Nat:
  match bands:
    case NoBand{}:
      (NoBand{}, 0n)
    case Band{+rows, band}:
      Bands.sum_band(rows, Px.sum(~f, (width * rows : U32), band))
    case Split{+rows, top, bottom}:
      t b = Bands.sum_px(~f, width, top) Bands.sum_px(~f, width, bottom)
      Bands.sum_split(rows, t, b)

# Applies f to every pixel, in place, bands in parallel.
def Mat.map(~f: U32 -> U32, image: Mat) -> Mat:
  match image:
    case Mat{+w, h, bands}:
      Mat{w, h, Bands.map_px(~f, w, bands)}

def Mat.with_total(+w: U32, +h: U32, counted: Bands<Array<U32>> & Nat) -> Mat & Nat:
  (bands, total) = counted
  (Mat{w, h, bands}, total)

# Sums f over every pixel (f answers at most 255), bands in parallel; hands
# the image back. The total is a Nat, so it cannot overflow.
def Mat.sum(~f: U32 -> U32, image: Mat) -> Mat & Nat:
  match image:
    case Mat{+w, +h, bands}:
      Mat.with_total(w, h, Bands.sum_px(~f, w, bands))

def Mat.gray(image: Mat) -> Mat:
  Mat.map(~(p => Pixel.gray(p)), image)

def Mat.mean_of(+pixels: U32, summed: Mat & Nat) -> Mat & U32:
  (image, +total) = summed
  (image, U32.from_nat(Nat.div(total, U32.to_nat(pixels))))

# Average brightness, 0..255.
def Mat.mean_luma(image: Mat) -> Mat & U32:
  match image:
    case Mat{+w, +h, bands}:
      Mat.mean_of((w * h : U32), Mat.sum(~(p => Pixel.luma(p)), Mat{w, h, bands}))

# --- Reading one pixel --------------------------------------------------------
# Bands are uniform, so each level knows how many rows its top half holds and
# can pick the next level's side up front, the way Base's Array.get works.

def Bands.get_band(+rows: U32, got: Array<U32> & U32) -> Bands<Array<U32>> & U32:
  (band, px) = got
  (Band{rows, band}, px)

def Bands.get_lo(+rows: U32, bottom: Bands<Array<U32>>, got: Bands<Array<U32>> & U32) ->
  Bands<Array<U32>> & U32:
  (top, px) = got
  (Split{rows, top, bottom}, px)

def Bands.get_hi(+rows: U32, top: Bands<Array<U32>>, got: Bands<Array<U32>> & U32) ->
  Bands<Array<U32>> & U32:
  (bottom, px) = got
  (Split{rows, top, bottom}, px)

# half: rows in this node's top half; below: whether y falls in that half.
def Bands.get_go(bands: Bands<Array<U32>>, below: Bool, +width: U32, +x: U32, +y: U32, +half: U32) ->
  Bands<Array<U32>> & U32:
  match bands below:
    case NoBand{} _:
      (NoBand{}, 0)
    case Band{+rows, band} _:
      Bands.get_band(rows, Array.get(U32, band, (y * width + x : U32)))
    case Split{+rows, top, bottom} True{}:
      +h = (half / 2 : U32)
      Bands.get_lo(rows, bottom, Bands.get_go(top, U32.is_lt(y, h), width, x, y, h))
    case Split{+rows, top, bottom} False{}:
      +h = (half / 2 : U32)
      +y2 = (y - half : U32)
      Bands.get_hi(rows, top, Bands.get_go(bottom, U32.is_lt(y2, h), width, x, y2, h))

def Mat.with_pixel(+w: U32, +h: U32, got: Bands<Array<U32>> & U32) -> Mat & U32:
  (bands, px) = got
  (Mat{w, h, bands}, px)

# The pixel at (x, y), for 0 <= x < width and 0 <= y < height.
def Mat.get(image: Mat, +x: U32, +y: U32) -> Mat & U32:
  match image:
    case Mat{+w, +h, bands}:
      +half = Mat.top_half(w, h)
      Mat.with_pixel(w, h, Bands.get_go(bands, U32.is_lt(y, half), w, x, y, half))

def Px.fill(n: Nat, band: Array<U32>, +i: U32, pixels: List<&2, U32>) -> Array<U32> & List<&2, U32>:
  match n pixels:
    case 0n _:
      (band, pixels)
    case 1n+p Con{px, rest}:
      Px.fill(p, Array.set(U32, band, i, px), (i + 1 : U32), rest)
    case 1n+p Nil{}:
      (band, Nil{})

def Mat.piece(+rows: U32, filled: Array<U32> & List<&2, U32>,
  rest: List<&2, U32> -> List<(U32 & Array<U32>)>) -> List<(U32 & Array<U32>)>:
  (band, left) = filled
  Con{(rows, band), rest(left)}

# Bands of `per_band` rows, `rows_left` rows in all, from row-major pixels.
def Mat.pieces(n: Nat, +width: U32, +per_band: U32, +rows_left: U32, pixels: List<&2, U32>) ->
  List<(U32 & Array<U32>)>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      +rows = U32.min(per_band, rows_left)
      +count = (width * rows : U32)
      Mat.piece(rows, Px.fill(U32.to_nat(count), Array.new(U32, Px.slots(count), 0), 0, pixels),
        left => Mat.pieces(p, width, per_band, (rows_left - rows : U32), left))

# A Mat from row-major RGBA pixels (missing pixels are 0).
def Mat.from_list(+width: U32, +height: U32, pixels: List<&2, U32>) -> Mat:
  +per_band = Mat.rows_per_band(width, height)
  Mat.from_bands(width, height,
    Mat.pieces(U32.to_nat(Mat.band_count(width, height)), width, per_band, height, pixels))

def Mat.second(pair: Mat & U32) -> U32:
  (image, value) = pair
  value

# Just the pixel at (x, y), dropping the Mat.
def Mat.pixel_at(image: Mat, +x: U32, +y: U32) -> U32:
  Mat.second(Mat.get(image, x, y))

# Just the average brightness, dropping the Mat.
def Mat.brightness(image: Mat) -> U32:
  Mat.second(Mat.mean_luma(image))

# --- Blank images ------------------------------------------------------------------

# Rows held by `leaves` bands starting at band `first`.
def Mat.span_rows(+first: U32, +leaves: U32, +per_band: U32, +height: U32) -> U32:
  +y0 = (first * per_band : U32)
  +end = U32.min(height, ((first + leaves) * per_band : U32))
  ((end - U32.min(y0, end)) : U32)

# The band tree of a blank image, built in parallel (each band one fill).
def Bands.blank(+d: Nat, +first: U32, +width: U32, +per_band: U32, +height: U32, +color: U32) -> Bands<Array<U32>>:
  match d:
    case 0n:
      +rows = Mat.span_rows(first, 1, per_band, height)
      Band{rows, Array.new(U32, Px.slots((width * rows : U32)), color)}
    case 1n+e:
      +span = U32.from_nat(Nat.pow(2n, e))
      t b = Bands.blank(e, first, width, per_band, height, color) Bands.blank(e, (first + span : U32), width, per_band, height, color)
      Split{Mat.span_rows(first, (span * 2 : U32), per_band, height), t, b}

# A width x height Mat with every pixel `color`.
def Mat.blank(+width: U32, +height: U32, +color: U32) -> Mat:
  Mat{width, height,
    Bands.blank(Mat.band_depth(width, height), 0, width, Mat.rows_per_band(width, height), height, color)}
