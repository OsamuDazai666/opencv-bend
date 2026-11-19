import Base
import ../src/image.bend as I
import ../src/imgproc.bend as IP
import ../src/draw.bend as D
import ../src/jpeg.bend as J
import ../src/bytes.bend as B

# Checks the drawing module on small images, then writes build/draw_demo.jpg
# (shapes over a gradient, encoded by the Bend JPEG encoder).

def C.black() -> U32:
  4278190080

def C.px(m: I.Mat, +x: U32, +y: U32) -> U32:
  I.Mat.pixel_at(m, x, y)

def C.show(+p: U32) -> String:
  "(" ++ U32.show(I.Pixel.r(p)) ++ "," ++ U32.show(I.Pixel.g(p)) ++ "," ++ U32.show(I.Pixel.b(p)) ++ "," ++ U32.show(I.Pixel.a(p)) ++ ")"

def C.verdict(ok: Bool, +want: U32) -> String:
  match ok:
    case True{}:
      "  ok"
    case False{}:
      "  WRONG, want " ++ C.show(want)

def C.check(+name: String, +got: U32, +want: U32) -> String:
  name ++ ": " ++ C.show(got) ++ C.verdict(U32.is_eq(got, want), want) ++ "\n"

def C.opaque_circle() -> I.Mat:
  D.Mat.draw(I.Mat.blank(40, 40, C.black()), D.Shape{1, 20, 20, 10, 0, 0, 0, D.Draw.red(), 0})

def C.glass_box() -> I.Mat:
  D.Mat.draw(I.Mat.blank(40, 40, C.black()), D.Shape{0, 5, 5, 30, 30, 6, 0, D.Draw.alpha(D.Draw.white(), 51), 0})

def C.stroked_box() -> I.Mat:
  D.Mat.draw(I.Mat.blank(40, 40, C.black()), D.Draw.box(5, 5, 30, 30, D.Draw.green()))

def C.offscreen_box() -> I.Mat:
  D.Mat.draw(I.Mat.blank(20, 20, C.black()), D.Shape{0, (0 - 10 : U32), 5, 15, 10, 0, 0, D.Draw.blue(), 0})

def C.between(ok: Bool) -> String:
  match ok:
    case True{}:
      "  ok (partly covered: anti-aliased)"
    case False{}:
      "  WRONG (expected strictly between 0 and 239)"

def C.edge(+p: U32) -> String:
  "circle edge pixel (red channel) " ++ U32.show(I.Pixel.r(p)) ++ C.between(Bool.and(U32.is_gt(I.Pixel.r(p), 0), U32.is_lt(I.Pixel.r(p), 239))) ++ "\n"

def C.symmetric(+a: U32, +b: U32) -> String:
  "circle symmetry " ++ C.show(a) ++ " vs " ++ C.show(b) ++ C.verdict(U32.is_eq(a, b), b) ++ "\n"

def C.report() -> String:
  C.check("opaque circle centre", C.px(C.opaque_circle(), 20, 20), D.Draw.red()) ++
  C.check("opaque circle, 6 px outside", C.px(C.opaque_circle(), 36, 20), C.black()) ++
  C.edge(C.px(C.opaque_circle(), 27, 26)) ++
  C.symmetric(C.px(C.opaque_circle(), 13, 26), C.px(C.opaque_circle(), 26, 13)) ++
  C.check("20% white glass box interior", C.px(C.glass_box(), 20, 20), I.Pixel.pack(51, 51, 51, 255)) ++
  C.check("glass box, outside", C.px(C.glass_box(), 1, 1), C.black()) ++
  C.check("default box stroke (left edge)", C.px(C.stroked_box(), 5, 20), D.Draw.green()) ++
  C.check("default box interior (20% green)", C.px(C.stroked_box(), 20, 20), I.Pixel.pack(7, 39, 19, 255)) ++
  C.check("box from x = -10: column 0 covered", C.px(C.offscreen_box(), 0, 8), D.Draw.blue()) ++
  C.check("box from x = -10: right edge not wrapped", C.px(C.offscreen_box(), 19, 8), C.black())

# --- Demo image -----------------------------------------------------------------------

def C.bg(+k: U32, +x: U32, +y: U32, +p: U32) -> U32:
  I.Pixel.pack((30 + x / 12 : U32), (40 + y / 10 : U32), (70 + (x + y) / 20 : U32), 255)

def C.demo() -> I.Mat:
  D.Mat.draw_all([
      D.Draw.box(120, 140, 360, 260, D.Draw.blue()),
      D.Draw.box(560, 100, 240, 320, D.Draw.green()),
      D.Draw.box(880, 220, 300, 200, D.Draw.amber()),
      D.Draw.circle(340, 560, 90, D.Draw.violet()),
      D.Draw.circle(1020, 560, 60, D.Draw.cyan()),
      D.Draw.line(560, 600, 820, 480, 4, D.Draw.red()),
      D.Shape{0, 600, 560, 160, 90, 24, 0, D.Draw.alpha(D.Draw.white(), 180), 0},
      D.Draw.box((0 - 60 : U32), 600, 180, 140, D.Draw.red())],
    IP.Mat.map_xy(~U32, ~(k => x => y => p => C.bg(k, x, y, p)), 0, I.Mat.blank(1280, 720, 0)))

# Every pixel of the demo canvas, every shape: the fast path must equal the
# pure distance-field path exactly. Counts disagreements.
def C.shapes() -> List<&2, D.Shape>:
  [D.Draw.box(120, 140, 360, 260, D.Draw.blue()),
   D.Draw.box(560, 100, 240, 320, D.Draw.green()),
   D.Shape{0, 880, 220, 300, 200, 40, 9, D.Draw.alpha(D.Draw.amber(), 120), D.Draw.alpha(D.Draw.white(), 200)},
   D.Draw.circle(340, 560, 90, D.Draw.violet()),
   D.Shape{1, 1020, 560, 60, 0, 0, 7, D.Draw.alpha(D.Draw.cyan(), 90), D.Draw.cyan()},
   D.Shape{1, 700, 100, 3, 0, 0, 6, D.Draw.red(), D.Draw.white()},
   D.Shape{0, 40, 40, 8, 6, 5, 5, D.Draw.green(), D.Draw.amber()},
   D.Shape{0, 600, 560, 160, 90, 24, 0, D.Draw.alpha(D.Draw.white(), 180), 0},
   D.Draw.line(560, 600, 820, 480, 4, D.Draw.red()),
   D.Draw.box((0 - 60 : U32), 600, 180, 140, D.Draw.red())]

def C.one(same: Bool) -> U32:
  match same:
    case True{}:
      0
    case False{}:
      1

def C.differs(shapes: List<&2, D.Shape>, +x: U32, +y: U32, +p: U32) -> U32:
  match shapes:
    case Nil{}:
      0
    case Con{+s, rest}:
      (C.one(U32.is_eq(D.Draw.pixel(s, x, y, p), D.Draw.pixel_float(s, x, y, p))) + C.differs(rest, x, y, p) : U32)

def C.diff_px(+k: U32, +x: U32, +y: U32, +p: U32) -> U32:
  C.differs(C.shapes(), x, y, C.bg(k, x, y, p))

def C.zero(ok: Bool) -> String:
  match ok:
    case True{}:
      "  ok"
    case False{}:
      "  WRONG"

def C.agree(summed: I.Mat & Nat) -> String:
  (m, +n) = summed
  "fast path vs distance field, 1280x720 x 10 shapes: " ++ Nat.show(n) ++ " pixels differ" ++ C.zero(Nat.is_eq(n, 0n)) ++ "\n"

def C.agreement() -> String:
  C.agree(I.Mat.sum(~(p => p), IP.Mat.map_xy(~U32, ~(k => x => y => p => C.diff_px(k, x, y, p)), 0, I.Mat.blank(1280, 720, 0))))

def C.wrote(done: List<(Array<U32> & U32)> & Result<&1, &1, U32 & String, U32>) -> IO(Unit):
  (segs, r) = done
  IO.print("wrote build/draw_demo.jpg")

def C.write(encoded: I.Mat & List<(Array<U32> & U32)>) -> IO(Unit):
  (m, segs) = encoded
  IO.bind(List<(Array<U32> & U32)> & Result<&1, &1, U32 & String, U32>, Unit, B.Bytes.write_file("build/draw_demo.jpg", segs),
    done => C.wrote(done))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(C.report())
    IO.print(C.agreement())
    C.write(J.Jpeg.encode(C.demo()))
