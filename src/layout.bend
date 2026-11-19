import Base

# Pure frame-layout rules. No foreign effects here, so LAWS.bend and
# PROOF.bend can import this module and still reach ALL PROOFS CHECK.

# Captured frames are BGRA: 4 bytes per pixel.
def Layout.bytes_per_pixel() -> Nat:
  4n

# The narrowest row a frame of this width can have.
def Layout.min_stride(width: Nat) -> Nat:
  Nat.mul(width, Layout.bytes_per_pixel())

# A row of `have` bytes can hold `need` bytes.
def Layout.covers(need: Nat, have: Nat) -> Bool:
  Nat.is_le(need, have)

# A frame's stride (bytes per row, padding included) is valid for its width.
def Layout.stride_ok(width: Nat, stride: Nat) -> Bool:
  Layout.covers(Layout.min_stride(width), stride)
