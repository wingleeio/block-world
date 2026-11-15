"""Block World's item icons: 16 by 16 pixel art from Pixel Perfection
(Chorus Edition), a Minecraft-style texture pack by XSSheep and its
community, licensed CC BY-SA 4.0 (github.com/Athemis/PixelPerfectionCE,
assets/minecraft/textures/item/).

Writes icons/<name>.png (64 by 64: each pixel 4 by 4, for the inventory)
and icons/atlas.png (32 by 32 each: each pixel 2 by 2, three to a row, in
item id order from 22: for the shader, which draws drops and the item in
hand from it). Only scaled, pixel for pixel; the scaled pictures are
CC BY-SA 4.0 as the originals are (icons/LICENSE.txt).

usage: python3 make_icons.py <PixelPerfectionCE item folder> <plugin folder>
Pure Python (no PIL): reads PNGs (palette at any depth, RGB, RGBA, grey),
writes RGBA.
"""
import struct
import sys
import zlib
from pathlib import Path


def read_png(path):
    data = Path(path).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", path
    pos, idat, w, h, ct, plte, trns = 8, b"", 0, 0, 0, None, None
    while pos < len(data):
        ln = struct.unpack(">I", data[pos : pos + 4])[0]
        typ = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + ln]
        pos += 12 + ln
        if typ == b"IHDR":
            w, h, bd, ct, _, _, il = struct.unpack(">IIBBBBB", body)
            assert il == 0 and (bd == 8 or ct in (0, 3)), (path, bd, ct, il)
        elif typ == b"PLTE":
            plte = body
        elif typ == b"tRNS":
            trns = body
        elif typ == b"IDAT":
            idat += body
    bpp = {6: 4, 2: 3, 3: 1, 4: 2, 0: 1}[ct]
    raw = zlib.decompress(idat)
    # (bytes a row: under 8 bits a pixel, several share a byte)
    stride = (w * bd + 7) // 8 if bd < 8 else w * bpp
    prev = bytearray(stride)
    px = []
    i = 0
    for _ in range(h):
        f = raw[i]
        i += 1
        line = bytearray(raw[i : i + stride])
        i += stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 255
        row = []
        if bd < 8:
            per = 8 // bd
            vals = [(line[x // per] >> (8 - bd * (x % per + 1))) & ((1 << bd) - 1) for x in range(w)]
            for v in vals:
                if ct == 3:
                    a = trns[v] if trns and v < len(trns) else 255
                    row.append(tuple(plte[v * 3 : v * 3 + 3]) + (a,))
                else:
                    g = v * 255 // ((1 << bd) - 1)
                    row.append((g, g, g, 255))
            px.append(row)
            prev = line
            continue
        for x in range(w):
            if ct == 6:
                row.append(tuple(line[x * 4 : x * 4 + 4]))
            elif ct == 2:
                row.append(tuple(line[x * 3 : x * 3 + 3]) + (255,))
            elif ct == 3:
                k = line[x]
                a = trns[k] if trns and k < len(trns) else 255
                row.append(tuple(plte[k * 3 : k * 3 + 3]) + (a,))
            elif ct == 4:
                g, a = line[x * 2], line[x * 2 + 1]
                row.append((g, g, g, a))
            else:
                g = line[x]
                row.append((g, g, g, 255))
        px.append(row)
        prev = line
    return w, h, px


def write_png(path, w, h, px):
    raw = bytearray()
    for row in px:
        raw.append(0)
        for r, g, b, a in row:
            raw += bytes((r, g, b, a))

    def chunk(t, body):
        return struct.pack(">I", len(body)) + t + body + struct.pack(">I", zlib.crc32(t + body) & 0xFFFFFFFF)

    Path(path).write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def resize(w, h, px, n):
    """Area-averaged to n by n (alpha-weighted, so edges don't go dark)."""
    out = []
    for oy in range(n):
        y0, y1 = oy * h / n, (oy + 1) * h / n
        row = []
        for ox in range(n):
            x0, x1 = ox * w / n, (ox + 1) * w / n
            acc = [0.0, 0.0, 0.0, 0.0]
            area = 0.0
            for y in range(int(y0), min(h, int(y1 + 0.999))):
                wy = min(y + 1, y1) - max(y, y0)
                if wy <= 0:
                    continue
                for x in range(int(x0), min(w, int(x1 + 0.999))):
                    wx = min(x + 1, x1) - max(x, x0)
                    if wx <= 0:
                        continue
                    r, g, b, a = px[y][x]
                    k = wx * wy
                    acc[0] += r * a * k
                    acc[1] += g * a * k
                    acc[2] += b * a * k
                    acc[3] += a * k
                    area += k
            a = acc[3] / area if area else 0
            if acc[3] > 0:
                row.append((round(acc[0] / acc[3]), round(acc[1] / acc[3]), round(acc[2] / acc[3]), round(a)))
            else:
                row.append((0, 0, 0, 0))
        out.append(row)
    return out


def trim_square(w, h, px, pad=0.06):
    """The picture cropped to what it shows, squared and padded a little."""
    xs = [x for y in range(h) for x in range(w) if px[y][x][3] > 8]
    ys = [y for y in range(h) for x in range(w) if px[y][x][3] > 8]
    x0, x1, y0, y1 = min(xs), max(xs) + 1, min(ys), max(ys) + 1
    side = max(x1 - x0, y1 - y0)
    side = int(side * (1 + 2 * pad)) + 1
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    ox, oy = int(cx - side / 2), int(cy - side / 2)
    out = []
    for y in range(side):
        row = []
        for x in range(side):
            sx, sy = ox + x, oy + y
            row.append(px[sy][sx] if 0 <= sx < w and 0 <= sy < h else (0, 0, 0, 0))
        out.append(row)
    return side, side, out


def scale(w, h, px, k):
    """Each pixel k by k: pixel art kept sharp."""
    return [[px[y // k][x // k] for x in range(w * k)] for y in range(h * k)]


src = Path(sys.argv[1])
plugin = Path(sys.argv[2])
(plugin / "icons").mkdir(exist_ok=True)

# In item id order (items.luau): 22 stick, 23 pickaxe, 24 axe, 25 shovel,
# 26 sword, 27 egg, 28 raw porkchop, 29 apple.
ICONS = [
    ("stick", "stick"),
    ("pickaxe", "wooden_pickaxe"),
    ("axe", "wooden_axe"),
    ("shovel", "wooden_shovel"),
    ("sword", "wooden_sword"),
    ("egg", "egg"),
    ("porkchop", "porkchop"),
    ("apple", "apple"),
]

CELL = 32
atlas = [[(0, 0, 0, 0)] * (CELL * 3) for _ in range(CELL * 3)]
for k, (name, file) in enumerate(ICONS):
    w, h, px = read_png(src / f"{file}.png")
    assert (w, h) == (16, 16), (file, w, h)
    write_png(plugin / "icons" / f"{name}.png", 64, 64, scale(w, h, px, 4))
    small = scale(w, h, px, CELL // 16)
    cx, cy = (k % 3) * CELL, (k // 3) * CELL
    for y in range(CELL):
        for x in range(CELL):
            atlas[cy + y][cx + x] = small[y][x]
    print("icon", name)
write_png(plugin / "icons" / "atlas.png", CELL * 3, CELL * 3, atlas)
print("atlas", CELL * 3)
