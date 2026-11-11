#!/usr/bin/env python3
"""Generates a 1024x1024 app icon (dark rounded square + glowing blue orb) using only the stdlib.
   usage: make_icon.py out.png"""
import math, struct, sys, zlib
N = 1024
def sd_round_rect(x, y, half, r):
    qx, qy = abs(x) - (half - r), abs(y) - (half - r)
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r
def smooth(a, b, v):
    t = min(1.0, max(0.0, (v - a) / (b - a))); return t * t * (3 - 2 * t)
rows = []
for j in range(N):
    row = bytearray([0])
    for i in range(N):
        x, y = i - N / 2 + 0.5, j - N / 2 + 0.5
        d = sd_round_rect(x, y, 412, 185)                   # macOS icon grid: ~824px squircle in 1024 canvas
        a = 1.0 - smooth(-1.5, 1.5, d)
        if a <= 0: row += b"\x00\x00\x00\x00"; continue
        # background: near-black with a blue pool at the top
        t = (y + 412) / 824
        r, g, b = 10 + 14 * (1 - t), 10 + 20 * (1 - t), 14 + 46 * (1 - t)
        # orb
        dist = math.hypot(x, y + 20)
        glow = math.exp(-((dist / 230) ** 2)) * 0.9
        core = 1 - smooth(120, 175, dist)
        ring = math.exp(-(((dist - 175) / 6) ** 2)) * 0.7
        r += 40 * glow + 20 * core + 200 * ring * 0.6
        g += 110 * glow + 70 * core + 220 * ring * 0.7
        b += 255 * glow + 175 * core + 255 * ring
        # waveform bars (rounded)
        for k, h in enumerate((44, 92, 140, 92, 44)):
            bx = (k - 2) * 50
            qx, qy = abs(x - bx) - (13 - 13), abs(y + 20) - (h / 2 - 13)
            dbar = math.hypot(max(qx, 0), max(qy, 0)) - 13
            cov = 1 - smooth(-1.0, 1.0, dbar)
            if cov > 0 and dist < 185:
                r, g, b = r + (255 - r) * cov, g + (255 - g) * cov, b + (255 - b) * cov
        # subtle top highlight
        r += 18 * smooth(-412, -300, y) * (1 - smooth(-300, -150, y))
        row += bytes((min(255, int(r)), min(255, int(g)), min(255, int(b)), int(a * 255)))
    rows.append(bytes(row))
raw = b"".join(rows)
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", N, N, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
