#!/usr/bin/env python3
"""Generates the sample GLB files used by the example app.

  cube.glb  textured cube: uint16 indices, normals, UVs, embedded PNG texture.
  star.glb  extruded gold star: no normals (flat normals are generated),
            no texture, uint8 indices, nested TRS nodes.

Usage: python3 tool/make_test_glb.py   (run from example/)
"""
import json
import math
import os
import struct
import zlib

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets")


def png_rgba(width, height, pixel):
    rows = b"".join(
        b"\x00" + b"".join(bytes(pixel(x, y)) for x in range(width)) for y in range(height)
    )

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(rows, 9))
        + chunk(b"IEND", b"")
    )


class GlbBuilder:
    def __init__(self):
        self.bin = bytearray()
        self.gltf = {
            "asset": {"version": "2.0", "generator": "glbview make_test_glb.py"},
            "buffers": [],
            "bufferViews": [],
            "accessors": [],
        }

    def view(self, data, target=None):
        while len(self.bin) % 4:
            self.bin.append(0)
        view = {"buffer": 0, "byteOffset": len(self.bin), "byteLength": len(data)}
        if target:
            view["target"] = target
        self.bin.extend(data)
        self.gltf["bufferViews"].append(view)
        return len(self.gltf["bufferViews"]) - 1

    def accessor(self, values, kind, component, fmt, target, minmax=False):
        width = {"SCALAR": 1, "VEC2": 2, "VEC3": 3}[kind]
        flat = [c for v in values for c in (v if width > 1 else (v,))]
        data = struct.pack("<%d%s" % (len(flat), fmt), *flat)
        acc = {
            "bufferView": self.view(data, target),
            "componentType": component,
            "count": len(values),
            "type": kind,
        }
        if minmax:
            acc["min"] = [min(v[i] for v in values) for i in range(width)]
            acc["max"] = [max(v[i] for v in values) for i in range(width)]
        self.gltf["accessors"].append(acc)
        return len(self.gltf["accessors"]) - 1

    def write(self, path):
        while len(self.bin) % 4:
            self.bin.append(0)
        self.gltf["buffers"] = [{"byteLength": len(self.bin)}]
        js = json.dumps(self.gltf, separators=(",", ":")).encode()
        js += b" " * ((4 - len(js) % 4) % 4)
        total = 12 + 8 + len(js) + 8 + len(self.bin)
        with open(path, "wb") as f:
            f.write(struct.pack("<III", 0x46546C67, 2, total))
            f.write(struct.pack("<II", len(js), 0x4E4F534A) + js)
            f.write(struct.pack("<II", len(self.bin), 0x004E4942) + bytes(self.bin))
        print("wrote %s (%d bytes)" % (path, total))


def make_cube(path):
    b = GlbBuilder()
    faces = [  # normal, u axis, v axis
        ((1, 0, 0), (0, 0, -1), (0, -1, 0)),
        ((-1, 0, 0), (0, 0, 1), (0, -1, 0)),
        ((0, 1, 0), (1, 0, 0), (0, 0, 1)),
        ((0, -1, 0), (1, 0, 0), (0, 0, -1)),
        ((0, 0, 1), (1, 0, 0), (0, -1, 0)),
        ((0, 0, -1), (-1, 0, 0), (0, -1, 0)),
    ]
    pos, nrm, uv, idx = [], [], [], []
    for n, u, v in faces:
        base = len(pos)
        for su, sv in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            pos.append(tuple(0.5 * (n[i] + su * u[i] + sv * v[i]) for i in range(3)))
            nrm.append(n)
            uv.append(((su + 1) / 2, (sv + 1) / 2))
        idx += [base, base + 2, base + 1, base, base + 3, base + 2]
    # Make sure every triangle is counter-clockwise seen from outside.
    fixed = []
    for t in range(0, len(idx), 3):
        a, c, d = (pos[i] for i in idx[t:t + 3])
        e1 = [c[i] - a[i] for i in range(3)]
        e2 = [d[i] - a[i] for i in range(3)]
        cross = (e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0])
        n = nrm[idx[t]]
        tri = idx[t:t + 3]
        if sum(cross[i] * n[i] for i in range(3)) < 0:
            tri = [tri[0], tri[2], tri[1]]
        fixed += tri

    def pixel(x, y):
        checker = ((x // 8) + (y // 8)) % 2
        if x < 2 or y < 2 or x > 61 or y > 61:
            return (30, 30, 40, 255)
        return (255, 196, 40, 255) if checker else (40, 120, 230, 255)

    png = png_rgba(64, 64, pixel)
    b.gltf["images"] = [{"bufferView": b.view(png), "mimeType": "image/png"}]
    b.gltf["samplers"] = [{"magFilter": 9729, "minFilter": 9987}]
    b.gltf["textures"] = [{"source": 0, "sampler": 0}]
    b.gltf["materials"] = [{
        "name": "checker",
        "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}, "metallicFactor": 0.0},
    }]
    attributes = {
        "POSITION": b.accessor(pos, "VEC3", 5126, "f", 34962, minmax=True),
        "NORMAL": b.accessor(nrm, "VEC3", 5126, "f", 34962),
        "TEXCOORD_0": b.accessor(uv, "VEC2", 5126, "f", 34962),
    }
    indices = b.accessor(fixed, "SCALAR", 5123, "H", 34963)
    b.gltf["meshes"] = [{"primitives": [{"attributes": attributes, "indices": indices, "material": 0}]}]
    b.gltf["nodes"] = [{"mesh": 0, "rotation": [0, 0.3826834, 0, 0.9238795]}]
    b.gltf["scenes"] = [{"nodes": [0]}]
    b.gltf["scene"] = 0
    b.write(path)


def make_star(path):
    b = GlbBuilder()
    points, depth = 5, 0.25
    ring = []
    for i in range(points * 2):
        r = 1.0 if i % 2 == 0 else 0.45
        a = math.pi / 2 + i * math.pi / points
        ring.append((r * math.cos(a), r * math.sin(a)))
    n = len(ring)
    pos = [(0, 0, depth), (0, 0, -depth)]
    pos += [(x, y, 0.08) for x, y in ring] + [(x, y, -0.08) for x, y in ring]
    idx = []
    for i in range(n):
        j = (i + 1) % n
        idx += [0, 2 + i, 2 + j]                  # front cone
        idx += [1, 2 + n + j, 2 + n + i]          # back cone
        idx += [2 + i, 2 + n + i, 2 + n + j]      # side wall
        idx += [2 + i, 2 + n + j, 2 + j]
    b.gltf["materials"] = [{
        "name": "gold",
        "pbrMetallicRoughness": {"baseColorFactor": [1.0, 0.62, 0.08, 1.0]},
    }]
    attributes = {"POSITION": b.accessor(pos, "VEC3", 5126, "f", 34962, minmax=True)}
    indices = b.accessor(idx, "SCALAR", 5121, "B", 34963)
    b.gltf["meshes"] = [{"primitives": [{"attributes": attributes, "indices": indices, "material": 0}]}]
    # Parent offsets and scales the child; the parser must compose them.
    b.gltf["nodes"] = [
        {"children": [1], "translation": [5, -2, 0], "scale": [3, 3, 3]},
        {"mesh": 0, "rotation": [0, 0, 0.1305262, 0.9914449]},
    ]
    b.gltf["scenes"] = [{"nodes": [0]}]
    b.write(path)


if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    make_cube(os.path.join(OUT_DIR, "cube.glb"))
    make_star(os.path.join(OUT_DIR, "star.glb"))
