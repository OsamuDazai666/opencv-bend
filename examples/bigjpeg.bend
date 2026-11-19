import Base
import ../src/image.bend as I
import ../src/imgproc.bend as IP
import ../src/jpeg.bend as J
import ../src/bytes.bend as B

# Usage: bigjpeg   writes build/big4k.jpg and build/big8k.jpg: a known pattern
# (R = x mod 256, G = y mod 256, B = (x + y) mod 256) encoded by the Bend
# encoder, for checking large-image JPEGs against the formula.

def G.px(+k: U32, +x: U32, +y: U32, +p: U32) -> U32:
  I.Pixel.pack((x .&. 255 : U32), (y .&. 255 : U32), ((x + y) .&. 255 : U32), 255)

def G.image(+w: U32, +h: U32) -> I.Mat:
  IP.Mat.map_xy(~U32, ~(k => x => y => p => G.px(k, x, y, p)), 0, I.Mat.blank(w, h, 0))

def G.say(+path: String, result: Result<&1, &1, U32 & String, U32>) -> IO(Unit):
  match result:
    case Done{+n}:
      IO.print("wrote " ++ path ++ " (" ++ U32.show(n) ++ " bytes)")
    case Fail{(code, message)}:
      IO.print_err("failed " ++ path ++ ": " ++ message)

def G.written(+path: String, done: List<(Array<U32> & U32)> & Result<&1, &1, U32 & String, U32>) -> IO(Unit):
  (segs, result) = done
  G.say(path, result)

def G.write(+path: String, encoded: I.Mat & List<(Array<U32> & U32)>) -> IO(Unit):
  (mat, segs) = encoded
  IO.bind(List<(Array<U32> & U32)> & Result<&1, &1, U32 & String, U32>, Unit, B.Bytes.write_file(path, segs), done =>
    G.written(path, done))

def main() -> IO(Unit):
  do IO<Unit>:
    G.write("build/big4k.jpg", J.Jpeg.encode(G.image(3840, 2160)))
    G.write("build/big8k.jpg", J.Jpeg.encode(G.image(7680, 4320)))
