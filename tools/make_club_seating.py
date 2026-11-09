# Models the club's bar stool and booth and exports each as a GLB with no materials: just geometry, normals and UVs into the seating atlas
# (tools/make_club_atlas.py). The game gives them one shared material, so a stool or a booth is a single surface, and every stool (or booth)
# in a room is drawn together as a MultiMesh: one draw call a room per kind, however many there are.
#
#   blender -b --factory-startup --python tools/make_club_seating.py -- <output folder>
#
# Blender axes: Z up. The booth's back is at -Y (the glTF export turns that into Y up, back towards +Z: the booth goes against the south
# wall as it is), its opening at +Y, the origin on the floor in the middle of its footprint. The stool's origin is on the floor under its seat.
import bpy, bmesh, sys, math
from mathutils import Vector, Matrix

OUT = sys.argv[sys.argv.index("--") + 1]

# atlas quadrants, image space, origin top left, as (u0, v0) of the quadrant; each is 0.5 wide
REGION = {"leather": (0.0, 0.0), "chrome": (0.5, 0.0), "lacquer": (0.0, 0.5), "steel": (0.5, 0.5)}
USABLE = 0.42            # the part of a quadrant faces may use: the rest is a margin so mipmaps do not bleed one surface into the next
MARGIN = 0.04
LEATHER_DENSITY = 0.55   # atlas units per metre: the leather quadrant is one 0.9 m tile of the texture
FLAT_DENSITY = 0.02      # flat surfaces: tiny but real UVs, so the tangents are sound


class Part:
    """One mesh being built. Every primitive's faces (all of them, the patches a bevel adds included) are tagged with the atlas region the
    primitive uses, in an integer layer on the faces: the tag is whatever has not been tagged yet when `tag` is called."""
    def __init__(self):
        self.bm = bmesh.new()
        self.layer = self.bm.faces.layers.int.new("group")
        self.regions = []           # the region of group i + 1

    def tag(self, region):
        self.regions.append(region)
        for f in self.bm.faces:
            if f[self.layer] == 0:
                f[self.layer] = len(self.regions)

    # -- primitives ---------------------------------------------------------------------------------------------------------------------
    def box(self, region, lo, hi, bevel=0.0, segments=2):
        """An axis-aligned box from lo to hi, its edges rounded by `bevel`."""
        result = bmesh.ops.create_cube(self.bm, size=1.0)
        verts = result["verts"]
        centre = (Vector(lo) + Vector(hi)) * 0.5
        size = Vector(hi) - Vector(lo)
        bmesh.ops.scale(self.bm, verts=verts, vec=size, space=Matrix.Identity(4))
        bmesh.ops.translate(self.bm, verts=verts, vec=centre)
        if bevel > 0.0:
            edges = list({e for v in verts for e in v.link_edges})
            bmesh.ops.bevel(self.bm, geom=edges, offset=bevel, segments=segments, profile=0.5, affect="EDGES")
        self.tag(region)

    def cylinder(self, region, p0, p1, r0, r1=None, segments=16, round_top=0.0):
        """A closed (tapered) cylinder from p0 to p1; r0 at p0. `round_top` rounds the edge of the p1 end by that much."""
        r1 = r0 if r1 is None else r1
        p0, p1 = Vector(p0), Vector(p1)
        axis = p1 - p0
        length = axis.length
        result = bmesh.ops.create_cone(self.bm, cap_ends=True, cap_tris=False, segments=segments, radius1=r0, radius2=r1, depth=length)
        verts = result["verts"]
        rot = Vector((0, 0, 1)).rotation_difference(axis.normalized()).to_matrix().to_4x4()
        bmesh.ops.transform(self.bm, verts=verts, matrix=Matrix.Translation((p0 + p1) * 0.5) @ rot, space=Matrix.Identity(4))
        self.bm.normal_update()
        if round_top > 0.0:
            faces = {f for v in verts for f in v.link_faces}
            top = [f for f in faces if len(f.verts) == segments and f.normal.dot(axis.normalized()) > 0.99]
            edges = list({e for f in top for e in f.edges})
            bmesh.ops.bevel(self.bm, geom=edges, offset=round_top, segments=3, profile=0.5, affect="EDGES")
        self.tag(region)

    def torus(self, region, centre, major, minor, major_segments=28, minor_segments=8):
        """A ring lying flat (axis Z)."""
        bm = self.bm
        rings = []
        for i in range(major_segments):
            a = math.tau * i / major_segments
            ring = []
            for j in range(minor_segments):
                b = math.tau * j / minor_segments
                r = major + minor * math.cos(b)
                ring.append(bm.verts.new((centre[0] + r * math.cos(a), centre[1] + r * math.sin(a), centre[2] + minor * math.sin(b))))
            rings.append(ring)
        for i in range(major_segments):
            for j in range(minor_segments):
                a, b = rings[i], rings[(i + 1) % major_segments]
                j2 = (j + 1) % minor_segments
                bm.faces.new((a[j], b[j], b[j2], a[j2]))
        self.tag(region)

    # -- finishing ----------------------------------------------------------------------------------------------------------------------
    def finish(self, name):
        bm = self.bm
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        uv = bm.loops.layers.uv.verify()
        for index, region in enumerate(self.regions):
            project([f for f in bm.faces if f[self.layer] == index + 1], uv, region)
        untagged = [f for f in bm.faces if f[self.layer] == 0]
        assert not untagged, "%s: %d faces were never given a region" % (name, len(untagged))
        # smooth everything but the hard edges
        for f in bm.faces:
            f.smooth = True
        for e in bm.edges:
            if len(e.link_faces) == 2 and e.calc_face_angle(0.0) > math.radians(50):
                e.smooth = False
        mesh = bpy.data.meshes.new(name)
        bm.to_mesh(mesh)
        bm.free()
        obj = bpy.data.objects.new(name, mesh)
        bpy.context.scene.collection.objects.link(obj)
        return obj


def project(faces, uv, region):
    """Box-projects a group of faces into its quadrant of the atlas (UV origin at the bottom left, as Blender wants)."""
    by_axis = {0: [], 1: [], 2: []}          # the face's loops, with where they land when seen along that axis
    for f in faces:
        n = f.normal
        axis = max(range(3), key=lambda i: abs(n[i]))
        for loop in f.loops:
            co = loop.vert.co
            by_axis[axis].append((loop, (co[1], co[2]) if axis == 0 else (co[0], co[2]) if axis == 1 else (co[0], co[1])))
    extent = 1e-6
    lows = {}
    for axis, pts in by_axis.items():
        if pts:
            lo = [min(p[1][k] for p in pts) for k in (0, 1)]
            hi = [max(p[1][k] for p in pts) for k in (0, 1)]
            lows[axis] = lo
            extent = max(extent, hi[0] - lo[0], hi[1] - lo[1])
    u0, v0 = REGION[region]
    if region == "leather":
        scale = min(LEATHER_DENSITY, USABLE / extent)
        origin = (u0 + MARGIN, v0 + MARGIN)
    else:
        scale = FLAT_DENSITY
        origin = (u0 + 0.2, v0 + 0.2)
    for axis, pts in by_axis.items():
        for loop, (a, b) in pts:
            u = origin[0] + (a - lows[axis][0]) * scale
            v = origin[1] + (b - lows[axis][1]) * scale
            loop[uv].uv = (u, 1.0 - v)


# ---- the stool ---------------------------------------------------------------------------------------------------------------------------

def make_stool():
    p = Part()
    p.cylinder("chrome", (0, 0, 0), (0, 0, 0.028), 0.205, 0.17, 28)                    # the foot, a low dome
    p.cylinder("chrome", (0, 0, 0.028), (0, 0, 0.075), 0.05, 0.032, 16)                # a collar where the post meets it
    p.cylinder("chrome", (0, 0, 0.075), (0, 0, 0.68), 0.027, segments=16)              # the post
    p.torus("chrome", (0, 0, 0.30), 0.165, 0.0115)                                     # the foot ring
    for k in range(3):                                                                 # three struts from the post to the ring
        a = math.tau * k / 3.0 + 0.5
        p.cylinder("chrome", (0.026 * math.cos(a), 0.026 * math.sin(a), 0.30), (0.165 * math.cos(a), 0.165 * math.sin(a), 0.30), 0.009, segments=8)
    p.cylinder("chrome", (0, 0, 0.675), (0, 0, 0.705), 0.17, 0.185, 28)                # the seat pan
    p.cylinder("leather", (0, 0, 0.705), (0, 0, 0.76), 0.19, 0.182, 28, round_top=0.02)   # the cushion, its top edge rounded
    p.torus("chrome", (0, 0, 0.706), 0.188, 0.0065, 28, 6)                             # the trim round the join
    return p.finish("club_stool")


# ---- the booth ---------------------------------------------------------------------------------------------------------------------------

def make_booth():
    p = Part()
    W, D = 3.0, 1.8                    # the footprint: x from -1.5 to 1.5, y from -0.9 (the back) to 0.9 (the open front)
    SEAT_D = 0.55                      # how deep the benches are
    SEAT_TOP, BACK_TOP = 0.45, 1.15
    PLINTH = 0.12
    gap = 0.006
    x0, x1 = -W / 2, W / 2
    yb = -D / 2                        # the back
    rest = 0.15                        # the thickness of a backrest
    # plinths under the benches (black lacquer, set back a little from the cushions)
    p.box("lacquer", (x0 + 0.03, yb + 0.03, 0.0), (x1 - 0.03, yb + SEAT_D - 0.03, PLINTH))
    for sx in (-1, 1):
        xa, xb = (x0 + 0.03, x0 + SEAT_D - 0.03) if sx < 0 else (x1 - SEAT_D + 0.03, x1 - 0.03)
        p.box("lacquer", (xa, yb + SEAT_D - 0.04, 0.0), (xb, D / 2 - 0.03, PLINTH))
    # the back bench: four seat cushions and four backrest cushions
    n = 4
    for i in range(n):
        xa = x0 + W / n * i + gap
        xb = x0 + W / n * (i + 1) - gap
        p.box("leather", (xa, yb + rest - 0.01, PLINTH), (xb, yb + SEAT_D, SEAT_TOP), 0.025)
        p.box("leather", (xa, yb, SEAT_TOP + 0.015), (xb, yb + rest, BACK_TOP), 0.03)
    # the side benches, each two cushions long, with their backrests on the outside
    run0, run1 = yb + SEAT_D, D / 2
    for sx in (-1, 1):
        for i in range(2):
            ya = run0 + (run1 - run0) / 2 * i + gap
            yc = run0 + (run1 - run0) / 2 * (i + 1) - gap
            if sx < 0:
                p.box("leather", (x0 + rest - 0.01, ya, PLINTH), (x0 + SEAT_D, yc, SEAT_TOP), 0.025)
            else:
                p.box("leather", (x1 - SEAT_D, ya, PLINTH), (x1 - rest + 0.01, yc, SEAT_TOP), 0.025)
        # the backrest down the outside of the side bench, from the back backrest to the open end, in two pieces
        mid = (yb + rest + gap + D / 2) / 2
        for ya, yc in ((yb + rest + gap, mid - gap), (mid + gap, D / 2)):
            if sx < 0:
                p.box("leather", (x0, ya, SEAT_TOP + 0.015), (x0 + rest, yc, BACK_TOP), 0.03)
            else:
                p.box("leather", (x1 - rest, ya, SEAT_TOP + 0.015), (x1, yc, BACK_TOP), 0.03)
    # piping along the tops of the backrests
    pipe_z = BACK_TOP + 0.002
    p.cylinder("chrome", (x0, yb + rest * 0.5, pipe_z), (x1, yb + rest * 0.5, pipe_z), 0.011, segments=8)
    for sx in (x0 + rest * 0.5, x1 - rest * 0.5):
        p.cylinder("chrome", (sx, yb + rest, pipe_z), (sx, D / 2, pipe_z), 0.011, segments=8)
    # the table: a black lacquer top on a chrome pedestal and a round foot, in the middle of the horseshoe
    ty = 0.175
    p.box("lacquer", (-0.7, ty - 0.375, 0.70), (0.7, ty + 0.375, 0.74), 0.008, 1)
    p.cylinder("chrome", (0, ty, 0.0), (0, ty, 0.02), 0.27, 0.24, 24)
    p.cylinder("chrome", (0, ty, 0.02), (0, ty, 0.70), 0.04, segments=12)
    return p.finish("club_booth")


# ---- export ------------------------------------------------------------------------------------------------------------------------------

def export(obj, filename):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.export_scene.gltf(
        filepath=OUT.rstrip("/") + "/" + filename,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_materials="NONE",
        export_texcoords=True,
        export_normals=True,
        export_yup=True,
    )
    mesh = obj.data
    print("EXPORTED %s: %d verts, %d tris" % (filename, len(mesh.vertices), sum(len(poly.vertices) - 2 for poly in mesh.polygons)))


bpy.ops.wm.read_factory_settings(use_empty=True)
stool = make_stool()
booth = make_booth()
export(stool, "club_stool.glb")
export(booth, "club_booth.glb")
