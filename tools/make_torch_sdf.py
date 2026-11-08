"""Builds a signed distance grid of the blowtorch's body for the grip solver (tools/solve_torch_grip.gd).

    python3 tools/make_torch_sdf.py assets/props/blowtorch/cinder_blowtorch.glb /tmp/torch_sdf.bin

The body mesh is rasterised into 1.5 mm voxels and thickened by one voxel (which seals hairline gaps, and keeps the fingers a hair clear
of the surface rather than touching it), the inside is filled, and an exact Euclidean distance transform gives every voxel its distance
to the surface: positive in the open, negative inside the torch. Coordinates are the torch's own, in metres.

File layout (little endian): origin x y z (3 float32), voxel (float32), size x y z (3 int32), then x*y*z float32 with x varying fastest.
"""
import json
import struct
import sys

import numpy as np
from scipy import ndimage

VOXEL = 0.0015
REGION_MIN = np.array([-0.07, 0.10, -0.10])
REGION_MAX = np.array([0.07, 0.33, 0.09])


def read_glb(path):
    data = open(path, "rb").read()
    json_len = struct.unpack("<I", data[12:16])[0]
    doc = json.loads(data[20:20 + json_len])
    bin_start = 20 + json_len + 8
    return doc, data[bin_start:]


def accessor(doc, blob, index):
    acc = doc["accessors"][index]
    view = doc["bufferViews"][acc["bufferView"]]
    start = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
    comps = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[acc["type"]]
    dtype = {5126: np.float32, 5123: np.uint16, 5125: np.uint32}[acc["componentType"]]
    count = acc["count"] * comps
    arr = np.frombuffer(blob, dtype=dtype, count=count, offset=start)
    return arr.reshape(-1, comps) if comps > 1 else arr


if __name__ == "__main__":
    glb, out = sys.argv[1], sys.argv[2]
    doc, blob = read_glb(glb)
    body = next(m for m in doc["meshes"] if "canister" in m["name"].lower() or m is doc["meshes"][0])
    prim = body["primitives"][0]
    verts = accessor(doc, blob, prim["attributes"]["POSITION"]).astype(np.float64)
    tris = accessor(doc, blob, prim["indices"]).astype(np.int64).reshape(-1, 3)
    print("body mesh:", len(verts), "vertices,", len(tris), "triangles")

    size = np.ceil((REGION_MAX - REGION_MIN) / VOXEL).astype(int)
    surface = np.zeros(size[::-1], dtype=bool)          # indexed [z, y, x]
    step = VOXEL * 0.5
    for t in tris:
        a, b, c = verts[t[0]], verts[t[1]], verts[t[2]]
        longest = max(np.linalg.norm(a - b), np.linalg.norm(b - c), np.linalg.norm(c - a))
        n = max(1, int(np.ceil(longest / step)))
        ii, jj = np.meshgrid(np.arange(n + 1), np.arange(n + 1), indexing="ij")
        keep = (ii + jj) <= n
        w1 = ii[keep] / n
        w2 = jj[keep] / n
        pts = a + np.outer(w1, b - a) + np.outer(w2, c - a)
        idx = np.floor((pts - REGION_MIN) / VOXEL).astype(int)
        ok = np.all((idx >= 0) & (idx < size), axis=1)
        idx = idx[ok]
        surface[idx[:, 2], idx[:, 1], idx[:, 0]] = True
    thick = ndimage.binary_dilation(surface, iterations=1)
    solid = ndimage.binary_fill_holes(thick)
    print("surface voxels", surface.sum(), "solid voxels", solid.sum(), "= %.1f cm3" % (solid.sum() * VOXEL ** 3 * 1e6))
    d_out = ndimage.distance_transform_edt(~solid)
    d_in = ndimage.distance_transform_edt(solid)
    sdf = np.where(solid, -(d_in - 0.5), d_out - 0.5) * VOXEL
    with open(out, "wb") as f:
        f.write(struct.pack("<4f3i", REGION_MIN[0], REGION_MIN[1], REGION_MIN[2], VOXEL, size[0], size[1], size[2]))
        f.write(sdf.astype(np.float32).tobytes())
    print("wrote", out, "grid", tuple(size), "min/max sd", float(sdf.min()), float(sdf.max()))
