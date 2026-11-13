# Sonar: renders the 1024 px app icon (ping rings around a source, one bright echo) using only the standard library.
import math, struct, sys, zlib

SIZE = 1024
BG = (10, 12, 13)
ACC = (111, 255, 200)
CX, CY = 512, 512
RINGS = [(150, 0.9), (270, 0.5), (390, 0.24)]
THICK = 30
ECHO = (CX + 270 * math.cos(math.radians(-38)), CY + 270 * math.sin(math.radians(-38)), 46)


def cover(d):
    return max(0.0, min(1.0, 0.5 - d))


rows = []
for y in range(SIZE):
    row = bytearray([0])
    for x in range(SIZE):
        px, py = x + 0.5, y + 0.5
        r = math.hypot(px - CX, py - CY)
        a = cover(r - 34)
        for radius, alpha in RINGS:
            a = max(a, cover(abs(r - radius) - THICK / 2) * alpha)
        e = math.hypot(px - ECHO[0], py - ECHO[1])
        gap = cover(e - ECHO[2] - 22)
        a = a * (1 - gap) + cover(e - ECHO[2])
        white = cover(e - ECHO[2])
        row += bytes(round((BG[c] + (ACC[c] - BG[c]) * min(1.0, a)) * (1 - white) + 255 * white) for c in range(3))
    rows.append(bytes(row))


def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
