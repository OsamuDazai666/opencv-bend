import Base

# Byte segments made in Bend (a List of (Array<U32>, length), four bytes per
# U32, little-endian), written by native code that only moves the bytes.

def Bytes.write_file(path: String, segments: List<(Array<U32> & U32)>) ->
  IO(List<(Array<U32> & U32)> & Result<&1, &1, U32 & String, U32>):
  import "./native/bytes.c"
  import "./native/bytes.js"
