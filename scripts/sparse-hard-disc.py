#!/usr/bin/env python3
"""Packs a SCSI hard disc (BeebEm's .dat and .dsc) into MacBeeb's sparse
form for bundling: "MBHD", the .dsc's 22 bytes, the .dat's length in
sectors (32-bit little-endian), then each sector that isn't all zeros as its
number (32-bit little-endian) and its 256 bytes.

usage: sparse-hard-disc.py DISC.dat DISC.dsc OUT
"""
import struct
import sys

dat_path, dsc_path, out_path = sys.argv[1:4]
dat = open(dat_path, "rb").read()
dsc = open(dsc_path, "rb").read()
assert len(dsc) == 22, "a .dsc is 22 bytes"
sectors = (len(dat) + 255) // 256
dat += bytes(sectors * 256 - len(dat))
out = bytearray(b"MBHD" + dsc + struct.pack("<I", sectors))
for lba in range(sectors):
    sector = dat[lba * 256:(lba + 1) * 256]
    if any(sector):
        out += struct.pack("<I", lba) + sector
open(out_path, "wb").write(out)
