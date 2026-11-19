import Base
import ./image.bend as I

# Modern drawing: anti-aliased shapes with rounded corners, translucent fills
# and crisp strokes, blended onto the image ("over" compositing).
#
# Each shape is a signed distance field: for a pixel centre, the distance to
# the shape's edge (negative inside). Coverage is a 1-pixel smooth ramp
# across the edge, which gives anti-aliasing, rounded corners and round line
# caps from one rule.
#
# Only the shape's bounding box (plus a 2-pixel margin for the soft edge) is
# visited, so a shape costs the same on an 8K image as on a small one. Which
# pixels are visited is decided with integers; floats are used only for the
# distance and blending of visited pixels.
#
# Coordinates are whole pixels and may be negative (write them as signed
# 32-bit values, e.g. (0 - 20 : U32)): shapes can start off the left or top
# edge. Everything outside the image is clipped, never wrapped.

# --- Palette (vivid 500 shades, as in today's UI kits) ----------------------------

def Draw.blue() -> U32:
  I.Pixel.pack(59, 130, 246, 255)

def Draw.green() -> U32:
  I.Pixel.pack(34, 197, 94, 255)

def Draw.red() -> U32:
  I.Pixel.pack(239, 68, 68, 255)

def Draw.amber() -> U32:
  I.Pixel.pack(245, 158, 11, 255)

def Draw.violet() -> U32:
  I.Pixel.pack(139, 92, 246, 255)

def Draw.cyan() -> U32:
  I.Pixel.pack(6, 182, 212, 255)

def Draw.white() -> U32:
  I.Pixel.pack(255, 255, 255, 255)

def Draw.slate() -> U32:
  I.Pixel.pack(100, 116, 139, 255)

# The same colour with alpha a (0..255).
def Draw.alpha(+color: U32, +a: U32) -> U32:
  ((color .&. 16777215) .|. (a << 24n) : U32)

# --- Signed coordinates in U32 (two's complement) -----------------------------------

def Sx.neg(+v: U32) -> Bool:
  U32.is_ge(v, 2147483648)

def Sx.lt(+a: U32, +b: U32) -> Bool:
  U32.is_lt((a .^. 2147483648 : U32), (b .^. 2147483648 : U32))

def Sx.pick(c: Bool, +yes: U32, +no: U32) -> U32:
  match c:
    case True{}:
      yes
    case False{}:
      no

def Sx.min(+a: U32, +b: U32) -> U32:
  Sx.pick(Sx.lt(a, b), a, b)

def Sx.max(+a: U32, +b: U32) -> U32:
  Sx.pick(Sx.lt(a, b), b, a)

# Clamps a signed value to 0..limit.
def Sx.clamp(+v: U32, +limit: U32) -> U32:
  Sx.pick(Sx.neg(v), 0, U32.min(v, limit))

def Sx.f32_if(negative: Bool, +v: U32) -> F32:
  match negative:
    case True{}:
      (0.0 - U32.to_f32(((v .^. 4294967295) + 1 : U32)) : F32)
    case False{}:
      U32.to_f32(v)

def Sx.f32(+v: U32) -> F32:
  Sx.f32_if(Sx.neg(v), v)

# --- Shapes -------------------------------------------------------------------------

# kind 0: rounded box, top-left (ax, ay), size (bx, by), corner `radius`.
# kind 1: circle, centre (ax, ay), radius bx.
# kind 2: line from (ax, ay) to (bx, by), `width` thick, round caps; drawn in
#         the `fill` colour.
# Boxes and circles: `fill` inside (use alpha for translucency), then a
# `stroke` of `width` pixels centred on the edge (width 0: no stroke).
type Shape is Data:
  Shape{kind: U32, ax: U32, ay: U32, bx: U32, by: U32, radius: U32, width: U32, fill: U32, stroke: U32}

# A rounded box in the modern default style: 20% fill, solid 2 px stroke,
# 8 px corners.
def Draw.box(+x: U32, +y: U32, +w: U32, +h: U32, +color: U32) -> Shape:
  Shape{0, x, y, w, h, 8, 2, Draw.alpha(color, 51), color}

# A circle in the default style.
def Draw.circle(+cx: U32, +cy: U32, +r: U32, +color: U32) -> Shape:
  Shape{1, cx, cy, r, 0, 0, 2, Draw.alpha(color, 51), color}

# A line with round caps.
def Draw.line(+x1: U32, +y1: U32, +x2: U32, +y2: U32, +width: U32, +color: U32) -> Shape:
  Shape{2, x1, y1, x2, y2, 0, width, color, 0}

# Visited pixels: columns x0 <= x < x1, rows y0 <= y < y1 (inside the image).
type Box is Data:
  Box{x0: U32, y0: U32, x1: U32, y1: U32}

# How far past the geometry a shape can touch pixels: half the stroke plus
# 2 pixels for the soft edge.
def Draw.margin(+width: U32) -> U32:
  ((width + 1) / 2 + 2 : U32)

def Draw.box_from(+lx: U32, +ty: U32, +rx: U32, +by: U32, +m: U32, +w: U32, +h: U32) -> Box:
  Box{Sx.clamp((lx - m : U32), w), Sx.clamp((ty - m : U32), h), Sx.clamp((rx + m + 1 : U32), w), Sx.clamp((by + m + 1 : U32), h)}

def Draw.bbox_kind(is_box: Bool, is_circle: Bool, +ax: U32, +ay: U32, +bx: U32, +by: U32, +m: U32, +w: U32, +h: U32) -> Box:
  match is_box is_circle:
    case True{} _:
      Draw.box_from(ax, ay, (ax + bx : U32), (ay + by : U32), m, w, h)
    case False{} True{}:
      Draw.box_from((ax - bx : U32), (ay - bx : U32), (ax + bx : U32), (ay + bx : U32), m, w, h)
    case False{} False{}:
      Draw.box_from(Sx.min(ax, bx), Sx.min(ay, by), Sx.max(ax, bx), Sx.max(ay, by), m, w, h)

def Draw.bbox_by(is_box: Bool, is_circle: Bool, s: Shape, +w: U32, +h: U32) -> Box:
  match s:
    case Shape{_, +ax, +ay, +bx, +by, _, +width, _, _}:
      +m = Draw.margin(width)
      Draw.bbox_kind(is_box, is_circle, ax, ay, bx, by, m, w, h)

def Draw.kind(s: Shape) -> U32:
  match s:
    case Shape{kind, _, _, _, _, _, _, _, _}:
      kind

# The pixels a shape may touch on a w x h image (integers only).
def Draw.bbox(+s: Shape, +w: U32, +h: U32) -> Box:
  +k = Draw.kind(s)
  Draw.bbox_by(U32.is_eq(k, 0), U32.is_eq(k, 1), s, w, h)

# --- Distance fields (floats, for visited pixels only) ---------------------------------

def F.sq(+v: F32) -> F32:
  (v * v : F32)

# Rounded box with centre (cx, cy), half size (hx, hy), corner radius r.
def Sdf.box(+px: F32, +py: F32, +cx: F32, +cy: F32, +hx: F32, +hy: F32, +r0: F32) -> F32:
  +r = F32.min(r0, F32.min(hx, hy))
  +qx = (F32.abs((px - cx : F32)) - hx + r : F32)
  +qy = (F32.abs((py - cy : F32)) - hy + r : F32)
  +outside = F32.sqrt((F.sq(F32.max(qx, 0.0)) + F.sq(F32.max(qy, 0.0)) : F32))
  (outside + F32.min(F32.max(qx, qy), 0.0) - r : F32)

def Sdf.circle(+px: F32, +py: F32, +cx: F32, +cy: F32, +r: F32) -> F32:
  (F32.sqrt((F.sq((px - cx : F32)) + F.sq((py - cy : F32)) : F32)) - r : F32)

# Distance to the segment a-b, minus half the width (a capsule).
def Sdf.line(+px: F32, +py: F32, +ax: F32, +ay: F32, +bx: F32, +by: F32, +half: F32) -> F32:
  +pax = (px - ax : F32)
  +pay = (py - ay : F32)
  +bax = (bx - ax : F32)
  +bay = (by - ay : F32)
  +t = F32.clamp(((pax * bax + pay * bay) / (bax * bax + bay * bay + 0.000001) : F32), 0.0, 1.0)
  (F32.sqrt((F.sq((pax - bax * t : F32)) + F.sq((pay - bay * t : F32)) : F32)) - half : F32)

def Sdf.by_kind(is_box: Bool, is_circle: Bool, +px: F32, +py: F32, +ax: F32, +ay: F32, +bx: F32, +by: F32,
  +radius: F32, +width: F32) -> F32:
  match is_box is_circle:
    case True{} _:
      Sdf.box(px, py, (ax + bx * 0.5 : F32), (ay + by * 0.5 : F32), (bx * 0.5 : F32), (by * 0.5 : F32), radius)
    case False{} True{}:
      Sdf.circle(px, py, ax, ay, bx)
    case False{} False{}:
      Sdf.line(px, py, ax, ay, bx, by, (width * 0.5 : F32))

def Sdf.of(+k: U32, +px: F32, +py: F32, +ax: U32, +ay: U32, +bx: U32, +by: U32, +radius: U32, +width: U32) -> F32:
  Sdf.by_kind(U32.is_eq(k, 0), U32.is_eq(k, 1), px, py, Sx.f32(ax), Sx.f32(ay), Sx.f32(bx), Sx.f32(by),
    U32.to_f32(radius), U32.to_f32(width))

# --- Compositing --------------------------------------------------------------------

def Mix.channel(+s: U32, +d: U32, +a: F32) -> U32:
  F32.to_u32(F32.round((U32.to_f32(s) * a + U32.to_f32(d) * (1.0 - a) : F32)))

def Mix.over_if(skip: Bool, +dst: U32, +src: U32, +a: F32) -> U32:
  match skip:
    case True{}:
      dst
    case False{}:
      I.Pixel.pack(Mix.channel(I.Pixel.r(src), I.Pixel.r(dst), a), Mix.channel(I.Pixel.g(src), I.Pixel.g(dst), a),
        Mix.channel(I.Pixel.b(src), I.Pixel.b(dst), a),
        F32.to_u32(F32.round((255.0 * a + U32.to_f32(I.Pixel.a(dst)) * (1.0 - a) : F32))))

# src over dst, with src's alpha scaled by coverage (0..1).
def Mix.over(+dst: U32, +src: U32, +coverage: F32) -> U32:
  +a = (U32.to_f32(I.Pixel.a(src)) / 255.0 * coverage : F32)
  Mix.over_if(F32.is_le(a, 0.0), dst, src, a)

# Fill coverage: 1 inside, 0 outside, a 1-pixel ramp across the edge.
def Mix.fill(+d: F32) -> F32:
  F32.clamp((0.5 - d : F32), 0.0, 1.0)

# Stroke coverage: a band `width` wide centred on the edge, soft on both sides.
def Mix.stroke(+d: F32, +width: F32) -> F32:
  F32.clamp((width * 0.5 + 0.5 - F32.abs(d) : F32), 0.0, 1.0)

def Mix.shape_by(is_line: Bool, no_stroke: Bool, +d: F32, +width: U32, +fill: U32, +stroke: U32, +p: U32) -> U32:
  match is_line no_stroke:
    case True{} _:
      Mix.over(p, fill, Mix.fill(d))
    case False{} True{}:
      Mix.over(p, fill, Mix.fill(d))
    case False{} False{}:
      Mix.over(Mix.over(p, fill, Mix.fill(d)), stroke, Mix.stroke(d, U32.to_f32(width)))

def Mix.shape_px(+k: U32, +d: F32, +width: U32, +fill: U32, +stroke: U32, +p: U32) -> U32:
  Mix.shape_by(U32.is_eq(k, 2), U32.is_eq(width, 0), d, width, fill, stroke, p)

# src over dst at full coverage, in exact integer arithmetic (the same result
# as the float path: round((s * A + d * (255 - A)) / 255)).
def Mix.int_channel(+s: U32, +d: U32, +a: U32) -> U32:
  ((s * a + d * (255 - a) + 127) / 255 : U32)

def Mix.int_over(+dst: U32, +src: U32) -> U32:
  +a = I.Pixel.a(src)
  I.Pixel.pack(Mix.int_channel(I.Pixel.r(src), I.Pixel.r(dst), a), Mix.int_channel(I.Pixel.g(src), I.Pixel.g(dst), a),
    Mix.int_channel(I.Pixel.b(src), I.Pixel.b(dst), a), Mix.int_channel(255, I.Pixel.a(dst), a))

def Sx.abs(+v: U32) -> U32:
  Sx.pick(Sx.neg(v), ((v .^. 4294967295) + 1 : U32), v)

# Signed lo <= v < hi.
def Sx.within(+lo: U32, +v: U32, +hi: U32) -> Bool:
  Bool.and(Bool.not(Sx.lt(v, lo)), Sx.lt(v, hi))

# Integer classification of a pixel: 0 deep inside (fill only, exact), 1 far
# outside (untouched), 2 near the edge (distance field). e is the margin:
# past the stroke and the soft edge, so these regions need no floats.
def Draw.region_box(+x: U32, +y: U32, +ax: U32, +ay: U32, +bx: U32, +by: U32, +r: U32, +e: U32) -> U32:
  +l = (ax + e : U32)
  +t = (ay + e : U32)
  +rr = (ax + bx - e : U32)
  +b = (ay + by - e : U32)
  Sx.pick(Bool.or(Bool.and(Sx.within(l, x, rr), Sx.within((t + r : U32), y, (b - r : U32))),
    Bool.and(Sx.within((l + r : U32), x, (rr - r : U32)), Sx.within(t, y, b))), 0, 2)

def Draw.region_circle(+x: U32, +y: U32, +cx: U32, +cy: U32, +r: U32, +e: U32) -> U32:
  +dx = Sx.abs((x - cx : U32))
  +dy = Sx.abs((y - cy : U32))
  +d2 = (dx * dx + dy * dy : U32)
  +inner = U32.max(r, e)
  Sx.pick(U32.is_lt(d2, ((inner - e) * (inner - e) : U32)), 0,
    Sx.pick(U32.is_ge(d2, ((r + e) * (r + e) : U32)), 1, 2))

def Draw.region_by(is_box: Bool, is_circle: Bool, +x: U32, +y: U32, +ax: U32, +ay: U32, +bx: U32, +by: U32,
  +radius: U32, +e: U32) -> U32:
  match is_box is_circle:
    case True{} _:
      Draw.region_box(x, y, ax, ay, bx, by, radius, e)
    case False{} True{}:
      Draw.region_circle(x, y, ax, ay, bx, e)
    case False{} False{}:
      2

def Draw.region(+k: U32, +x: U32, +y: U32, +ax: U32, +ay: U32, +bx: U32, +by: U32, +radius: U32, +e: U32) -> U32:
  Draw.region_by(U32.is_eq(k, 0), U32.is_eq(k, 1), x, y, ax, ay, bx, by, radius, e)

def Draw.pixel_case(inside: Bool, outside: Bool, +k: U32, +x: U32, +y: U32, +ax: U32, +ay: U32, +bx: U32, +by: U32,
  +radius: U32, +width: U32, +fill: U32, +stroke: U32, +p: U32) -> U32:
  match inside outside:
    case True{} _:
      Mix.int_over(p, fill)
    case False{} True{}:
      p
    case False{} False{}:
      Mix.shape_px(k, Sdf.of(k, (U32.to_f32(x) + 0.5 : F32), (U32.to_f32(y) + 0.5 : F32), ax, ay, bx, by, radius, width),
        width, fill, stroke, p)

def Draw.pixel_by(+region: U32, +k: U32, +x: U32, +y: U32, +ax: U32, +ay: U32, +bx: U32, +by: U32, +radius: U32,
  +width: U32, +fill: U32, +stroke: U32, +p: U32) -> U32:
  Draw.pixel_case(U32.is_eq(region, 0), U32.is_eq(region, 1), k, x, y, ax, ay, bx, by, radius, width, fill, stroke, p)

# The same pixel computed by the distance field alone, with no integer
# shortcuts (the reference the fast path is checked against).
def Draw.pixel_float(s: Shape, +x: U32, +y: U32, +p: U32) -> U32:
  match s:
    case Shape{+k, +ax, +ay, +bx, +by, +radius, +width, +fill, +stroke}:
      Mix.shape_px(k, Sdf.of(k, (U32.to_f32(x) + 0.5 : F32), (U32.to_f32(y) + 0.5 : F32), ax, ay, bx, by, radius, width),
        width, fill, stroke, p)

# The pixel at (x, y) with the shape drawn over it.
def Draw.pixel(s: Shape, +x: U32, +y: U32, +p: U32) -> U32:
  match s:
    case Shape{+k, +ax, +ay, +bx, +by, +radius, +width, +fill, +stroke}:
      Draw.pixel_by(Draw.region(k, x, y, ax, ay, bx, by, radius, Draw.margin(width)), k, x, y, ax, ay, bx, by, radius,
        width, fill, stroke, p)

# --- Visiting only the bounding box --------------------------------------------------

# Visited pixel j of a band: row lo + j / cols, column x0 + j % cols.
def Draw.index(+j: U32, +lo: U32, +y0: U32, +x0: U32, +cols: U32, +w: U32) -> U32:
  ((lo - y0 + j / cols) * w + x0 + j % cols : U32)

def Draw.go(n: Nat, got: Array<U32> & U32, +s: Shape, +j: U32, +lo: U32, +y0: U32, +x0: U32, +cols: U32, +w: U32) -> Array<U32>:
  match n:
    case 0n:
      (band, +p) = got
      Array.set(U32, band, Draw.index(j, lo, y0, x0, cols, w),
        Draw.pixel(s, (x0 + j % cols : U32), (lo + j / cols : U32), p))
    case 1n+q:
      (band, +p) = got
      +next = (j + 1 : U32)
      Draw.go(q, Array.get(U32, Array.set(U32, band, Draw.index(j, lo, y0, x0, cols, w),
        Draw.pixel(s, (x0 + j % cols : U32), (lo + j / cols : U32), p)), Draw.index(next, lo, y0, x0, cols, w)),
        s, next, lo, y0, x0, cols, w)

def Draw.band_if(none: Bool, band: Array<U32>, +s: Shape, +lo: U32, +hi: U32, +y0: U32, +x0: U32, +x1: U32, +w: U32) ->
  Array<U32>:
  match none:
    case True{}:
      band
    case False{}:
      +cols = (x1 - x0 : U32)
      Draw.go(Nat.sub(U32.to_nat(((hi - lo) * cols : U32)), 1n), Array.get(U32, band, Draw.index(0, lo, y0, x0, cols, w)),
        s, 0, lo, y0, x0, cols, w)

def Draw.leaf(+rows: U32, band: Array<U32>, +y0: U32, +w: U32, +s: Shape, b: Box) -> I.Bands<Array<U32>>:
  match b:
    case Box{+x0, +by0, +x1, +by1}:
      +lo = U32.max(y0, by0)
      +hi = U32.min((y0 + rows : U32), by1)
      I.Band{rows, Draw.band_if(Bool.or(U32.is_ge(lo, hi), U32.is_ge(x0, x1)), band, s, lo, hi, y0, x0, x1, w)}

# Bands in parallel; a band outside the box's rows does no work.
def Bands.draw(bands: I.Bands<Array<U32>>, +y0: U32, +half: U32, +w: U32, +s: Shape, +b: Box) -> I.Bands<Array<U32>>:
  match bands:
    case I.NoBand{}:
      I.NoBand{}
    case I.Band{+rows, band}:
      Draw.leaf(rows, band, y0, w, s, b)
    case I.Split{+rows, top, bottom}:
      +h = (half / 2 : U32)
      t u = Bands.draw(top, y0, h, w, s, b) Bands.draw(bottom, (y0 + half : U32), h, w, s, b)
      I.Split{rows, t, u}

# Draws one shape onto the image.
def Mat.draw(image: I.Mat, +s: Shape) -> I.Mat:
  match image:
    case I.Mat{+w, +h, bands}:
      I.Mat{w, h, Bands.draw(bands, 0, I.Mat.top_half(w, h), w, s, Draw.bbox(s, w, h))}

def Draw.band_box(+rows: U32, band: Array<U32>, +y0: U32, +w: U32, +s: Shape, b: Box) -> Array<U32>:
  match b:
    case Box{+x0, +by0, +x1, +by1}:
      +lo = U32.max(y0, by0)
      +hi = U32.min((y0 + rows : U32), by1)
      Draw.band_if(Bool.or(U32.is_ge(lo, hi), U32.is_ge(x0, x1)), band, s, lo, hi, y0, x0, x1, w)

# One band: every shape in order (later ones on top), each in its own box.
def Draw.band_all(shapes: List<&2, Shape>, +rows: U32, band: Array<U32>, +y0: U32, +w: U32, +h: U32) -> Array<U32>:
  match shapes:
    case Nil{}:
      band
    case Con{+s, rest}:
      Draw.band_all(rest, rows, Draw.band_box(rows, band, y0, w, s, Draw.bbox(s, w, h)), y0, w, h)

# All shapes in one parallel pass over the bands.
def Bands.draw_all(bands: I.Bands<Array<U32>>, +shapes: List<&2, Shape>, +y0: U32, +half: U32, +w: U32, +h: U32) ->
  I.Bands<Array<U32>>:
  match bands:
    case I.NoBand{}:
      I.NoBand{}
    case I.Band{+rows, band}:
      I.Band{rows, Draw.band_all(shapes, rows, band, y0, w, h)}
    case I.Split{+rows, top, bottom}:
      +hh = (half / 2 : U32)
      t u = Bands.draw_all(top, shapes, y0, hh, w, h) Bands.draw_all(bottom, shapes, (y0 + half : U32), hh, w, h)
      I.Split{rows, t, u}

# Draws shapes in order (later ones on top), bands in parallel: each band
# draws every shape that touches its rows.
def Mat.draw_all(+shapes: List<&2, Shape>, image: I.Mat) -> I.Mat:
  match image:
    case I.Mat{+w, +h, bands}:
      I.Mat{w, h, Bands.draw_all(bands, shapes, 0, I.Mat.top_half(w, h), w, h)}
