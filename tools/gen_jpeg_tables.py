#!/usr/bin/env python3
"""Generates src/jpeg_tables.bend: baseline JPEG tables as pure Bend functions.

Tables come from ITU-T T.81 (JPEG), Annex K: the zigzag order, the example
quantisation tables (K.1, K.2) and the typical Huffman tables (K.3-K.6),
given as BITS (codes per length) and HUFFVAL lists. Huffman codes are derived
from them with the procedure of Annex C. Lookups become `match` on Nat
literals, which compile to direct branches (about 2 ns each), so the encoder
needs no table arrays.

Run: python3 tools/gen_jpeg_tables.py [quality] > src/jpeg_tables.bend
(quality 1-100, default 75, scales the quantisation tables the IJG way).
"""
import sys

QUALITY = int(sys.argv[1]) if len(sys.argv) > 1 else 75

ZIGZAG = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48,
          41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15,
          23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]

LUMA_Q = [16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40,
          57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35,
          55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112,
          100, 103, 99]
CHROMA_Q = [17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99,
            99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99] + [99] * 32

# AAN DCT output scale factors: cos(k*pi/16) * sqrt(2) for k > 0, 1 for k = 0.
AAN = [1.0, 1.387039845, 1.306562965, 1.175875602, 1.0, 0.785694958, 0.541196100, 0.275899379]

DC_LUMA_BITS = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
DC_LUMA_VALS = list(range(12))
DC_CHROMA_BITS = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0]
DC_CHROMA_VALS = list(range(12))
AC_LUMA_BITS = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d]
AC_LUMA_VALS = [
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61,
    0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52,
    0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25,
    0x26, 0x27, 0x28, 0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45,
    0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64,
    0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83,
    0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99,
    0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
    0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3,
    0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8,
    0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa]
AC_CHROMA_BITS = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77]
AC_CHROMA_VALS = [
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61,
    0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33,
    0x52, 0xf0, 0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18,
    0x19, 0x1a, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44,
    0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63,
    0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a,
    0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97,
    0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4,
    0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca,
    0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7,
    0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa]


def huffman_codes(bits, vals):
    """Annex C: canonical codes, assigned in order of length."""
    codes, code, k = {}, 0, 0
    for length in range(1, 17):
        for _ in range(bits[length - 1]):
            codes[vals[k]] = (code, length)
            code += 1
            k += 1
        code <<= 1
    assert k == len(vals)
    return codes


def nat_match(name, sig, ret, pairs, default):
    lines = [f"def {name}({sig}) -> {ret}:", "  match k:"]
    for k, v in pairs:
        lines += [f"    case {k}n:", f"      {v}"]
    lines += ["    case _:", f"      {default}", ""]
    return "\n".join(lines)


def huff_fn(name, bits, vals):
    codes = huffman_codes(bits, vals)
    pairs = [(sym, (code << 5) | length) for sym, (code, length) in sorted(codes.items())]
    return nat_match(name, "k: Nat", "U32", pairs, 0)


def scaled(base, quality):
    """IJG quality scaling of a base quantisation table, clamped to 1..255."""
    scale = 5000 // quality if quality < 50 else 200 - 2 * quality
    return [min(255, max(1, (b * scale + 50) // 100)) for b in base]


def recips(table):
    """1 / (q * aan[row] * aan[col] * 8): one multiply quantises an AAN output."""
    return [1.0 / (table[z] * AAN[z // 8] * AAN[z % 8] * 8.0) for z in range(64)]


def dht_list(cls_id, bits, vals):
    return [cls_id] + bits + vals


out = ['''import Base

# GENERATED by tools/gen_jpeg_tables.py from ITU-T T.81 Annex K. Do not edit.
# Huffman lookups answer (code << 5) | length; 0 means "no such symbol".
''']
out.append("# Zigzag position k -> natural (row-major) index in the 8x8 block.")
out.append(nat_match("Jt.zigzag", "k: Nat", "U32", enumerate(ZIGZAG), 0))
out.append("# Example quantisation tables (Annex K.1 and K.2), natural order.")
out.append(nat_match("Jt.luma_q", "k: Nat", "U32", enumerate(LUMA_Q), 1))
out.append(nat_match("Jt.chroma_q", "k: Nat", "U32", enumerate(CHROMA_Q), 1))
luma_scaled, chroma_scaled = scaled(LUMA_Q, QUALITY), scaled(CHROMA_Q, QUALITY)
out.append(f"# Quality {QUALITY}: quantisation reciprocals, natural order (multiply an AAN output).")
out.append(nat_match("Jt.recip_luma", "k: Nat", "F32", [(z, f"{v:.9e}") for z, v in enumerate(recips(luma_scaled))], "0.0"))
out.append(nat_match("Jt.recip_chroma", "k: Nat", "F32", [(z, f"{v:.9e}") for z, v in enumerate(recips(chroma_scaled))], "0.0"))
out.append(f"# Quality {QUALITY}: the DQT segment body (table id, then 64 values in zigzag order), luma then chroma.")
out.append("def Jt.dqt() -> List<&2, U32>:\n  [" + ", ".join(map(str,
    [0] + [luma_scaled[ZIGZAG[k]] for k in range(64)] + [1] + [chroma_scaled[ZIGZAG[k]] for k in range(64)])) + "]\n")
out.append(f"def Jt.quality() -> U32:\n  {QUALITY}\n")
out.append("# AAN DCT scale factors for row/column k.")
out.append(nat_match("Jt.aan", "k: Nat", "F32", [(k, f"{v:.9f}") for k, v in enumerate(AAN)], "1.0"))
out.append("# Typical Huffman tables (Annex K.3 to K.6), keyed by symbol.")
out.append(huff_fn("Jt.dc_luma", DC_LUMA_BITS, DC_LUMA_VALS))
out.append(huff_fn("Jt.dc_chroma", DC_CHROMA_BITS, DC_CHROMA_VALS))
out.append(huff_fn("Jt.ac_luma", AC_LUMA_BITS, AC_LUMA_VALS))
out.append(huff_fn("Jt.ac_chroma", AC_CHROMA_BITS, AC_CHROMA_VALS))
dht = (dht_list(0x00, DC_LUMA_BITS, DC_LUMA_VALS) + dht_list(0x10, AC_LUMA_BITS, AC_LUMA_VALS)
       + dht_list(0x01, DC_CHROMA_BITS, DC_CHROMA_VALS) + dht_list(0x11, AC_CHROMA_BITS, AC_CHROMA_VALS))
out.append("# The four tables as a DHT segment body (class/id, BITS, HUFFVAL each).")
out.append("def Jt.dht() -> List<&2, U32>:\n  [" + ", ".join(map(str, dht)) + "]\n")
print("\n".join(out))
