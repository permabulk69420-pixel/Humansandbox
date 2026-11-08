# Rigs the unrigged MakeHuman-style woman (woman_clothed_fixed_1.glb) and exports a skinned GLB for Godot.
#
#   blender -b --factory-startup --python tools/rig_woman.py -- <source.glb> <out.glb> [out.blend]
#
# What it does
#   * splits the single "eyes" mesh into a left and a right eyeball so each can turn on its own bone
#   * builds a humanoid skeleton named like Godot's SkeletonProfileHumanoid (Hips, Spine, Chest, UpperChest, Neck, Head,
#     LeftEye/RightEye, arms, hands, legs, feet, toes) with joints placed from measurements of this mesh
#   * body, clothes and shoes get Blender's automatic weights; head, neck, eyes, brows, lashes and hair are weighted by hand
#   * caps every texture at 2048 px (the suit normal map is 4096) so it is comfortable on a Quest
#
# Blender axes: Z up, the figure faces -Y, her left is +X. The glTF export turns that into Y up, facing +Z.
import bpy, sys, math
from mathutils import Vector

args = sys.argv[sys.argv.index("--") + 1:]
SRC, OUT_GLB = args[0], args[1]
OUT_BLEND = args[2] if len(args) > 2 else None
MAX_TEXTURE = 2048

# ---- joints (metres, Blender axes, her left = +X; right side is mirrored) ---------------------------------------------------------
EYE_CENTER = Vector((0.0288, -0.1127, 1.4988))     # eyeball sphere centre (front pole at y = -0.1273, radius 0.0147)
EYE_FORWARD = 0.02
CENTRE_BONES = [
    # name, parent, head, tail
    ("Hips",       None,         (0, -0.015, 0.900), (0, -0.020, 0.975)),
    ("Spine",      "Hips",       (0, -0.020, 0.975), (0, -0.035, 1.085)),
    ("Chest",      "Spine",      (0, -0.035, 1.085), (0, -0.040, 1.190)),
    ("UpperChest", "Chest",      (0, -0.040, 1.190), (0, -0.030, 1.350)),
    ("Neck",       "UpperChest", (0, -0.030, 1.350), (0, -0.030, 1.445)),
    ("Head",       "Neck",       (0, -0.030, 1.445), (0, -0.040, 1.610)),
]
SIDE_BONES = [   # left side (x > 0); mirrored for the right
    ("Shoulder", "UpperChest", (0.020, -0.040, 1.335), (0.165, 0.015, 1.270)),
    ("UpperArm", "Shoulder",   (0.165, 0.015, 1.270),  (0.300, -0.025, 1.105)),
    ("LowerArm", "UpperArm",   (0.300, -0.025, 1.105), (0.412, -0.149, 0.995)),
    ("Hand",     "LowerArm",   (0.412, -0.149, 0.995), (0.452, -0.228, 0.914)),
    ("UpperLeg", "Hips",       (0.088, -0.015, 0.865), (0.125, -0.040, 0.470)),
    ("LowerLeg", "UpperLeg",   (0.125, -0.040, 0.470), (0.160, -0.025, 0.085)),
    ("Foot",     "LowerLeg",   (0.160, -0.025, 0.085), (0.172, -0.135, 0.030)),
    ("Toes",     "Foot",       (0.172, -0.135, 0.030), (0.175, -0.205, 0.020)),
]


def mirror(v):
    return (-v[0], v[1], v[2])


def bone_table():
    rows = list(CENTRE_BONES)
    for side, sign in (("Left", 1), ("Right", -1)):
        for name, parent, head, tail in SIDE_BONES:
            h, t = (head, tail) if sign > 0 else (mirror(head), mirror(tail))
            p = parent if parent == "Hips" or parent == "UpperChest" else side + parent
            rows.append((side + name, p, h, t))
        c = EYE_CENTER if sign > 0 else Vector(mirror(EYE_CENTER))
        rows.append((side + "Eye", "Head", tuple(c), (c.x, c.y - EYE_FORWARD, c.z)))
    return rows


def smoothstep(a, b, x):
    t = max(0.0, min(1.0, (x - a) / (b - a)))
    return t * t * (3.0 - 2.0 * t)


# ---- scene ---------------------------------------------------------------------------------------------------------------------------
bpy.ops.wm.read_factory_settings(use_empty=True)
# merge_vertices: the glTF importer splits vertices along every UV seam; welded again, a seam can no longer get two different sets of weights
bpy.ops.import_scene.gltf(filepath=SRC, merge_vertices=True)

NAMES = {"woman": "Body", "woman.eyebrow001": "Eyebrows", "woman.eyelashes01": "Eyelashes", "woman.female_casualsuit01": "Clothes",
         "woman.long01": "Hair", "woman.low-poly": "Eyes", "woman.shoes01": "Shoes"}
for old, new in NAMES.items():
    bpy.data.objects[old].name = new
objs = {n: bpy.data.objects[n] for n in NAMES.values()}

# The importer parents everything to the body. Everything sits at the origin with no transform, so unparenting changes nothing.
for o in objs.values():
    o.parent = None
    o.matrix_world.identity()


def select_only(*items, active=None):
    bpy.ops.object.select_all(action='DESELECT')
    for it in items:
        it.select_set(True)
    bpy.context.view_layer.objects.active = active or items[0]


# Two eyeballs in one mesh -> two meshes.
select_only(objs["Eyes"])
bpy.ops.object.mode_set(mode='EDIT')
bpy.ops.mesh.select_all(action='SELECT')
bpy.ops.mesh.separate(type='LOOSE')
bpy.ops.object.mode_set(mode='OBJECT')
halves = [o for o in bpy.data.objects if o.name.startswith("Eyes")]
assert len(halves) == 2, "expected two loose eyeballs"
for o in halves:
    cx = sum(v.co.x for v in o.data.vertices) / len(o.data.vertices)
    o.name = "EyeLeft" if cx > 0 else "EyeRight"
    o.data.name = o.name
objs["EyeLeft"] = bpy.data.objects["EyeLeft"]
objs["EyeRight"] = bpy.data.objects["EyeRight"]
del objs["Eyes"]

# ---- skeleton --------------------------------------------------------------------------------------------------------------------------
arm_data = bpy.data.armatures.new("Armature")
arm_obj = bpy.data.objects.new("Armature", arm_data)
bpy.context.scene.collection.objects.link(arm_obj)
select_only(arm_obj)
bpy.ops.object.mode_set(mode='EDIT')
for name, parent, head, tail in bone_table():
    eb = arm_data.edit_bones.new(name)
    eb.head, eb.tail = Vector(head), Vector(tail)
    if parent:
        eb.parent = arm_data.edit_bones[parent]
        eb.use_connect = (eb.parent.tail - eb.head).length < 1e-5
bpy.ops.object.mode_set(mode='OBJECT')

# ---- weights ---------------------------------------------------------------------------------------------------------------------------
for key in ("Body", "Clothes", "Shoes"):
    select_only(objs[key], arm_obj, active=arm_obj)
    bpy.ops.object.parent_set(type='ARMATURE_AUTO')


def bind_rigid(obj, weights_for_vertex):
    obj.parent = arm_obj
    obj.parent_type = 'OBJECT'
    mod = obj.modifiers.new("Armature", 'ARMATURE')
    mod.object = arm_obj
    for b in arm_data.bones:
        obj.vertex_groups.new(name=b.name)
    for v in obj.data.vertices:
        for bone, w in weights_for_vertex(v.co).items():
            if w > 1e-4:
                obj.vertex_groups[bone].add([v.index], w, 'REPLACE')


# Hair hangs down her back: a 1D skin along the spine by height, so it follows the head, then the neck, then the upper body, and
# never the arms.
HAIR_STACK = [(1.445, "Head"), (1.350, "Neck"), (1.260, "UpperChest"), (1.140, "Chest"), (1.000, "Spine")]


def hair_weights(co):
    z = co.z
    if z >= HAIR_STACK[0][0]:
        return {"Head": 1.0}
    if z <= HAIR_STACK[-1][0]:
        return {HAIR_STACK[-1][1]: 1.0}
    for (z0, b0), (z1, b1) in zip(HAIR_STACK, HAIR_STACK[1:]):
        if z1 <= z <= z0:
            t = smoothstep(z1, z0, z)
            return {b0: t, b1: 1.0 - t}
    return {"Head": 1.0}


bind_rigid(objs["Hair"], hair_weights)
bind_rigid(objs["Eyebrows"], lambda co: {"Head": 1.0})
bind_rigid(objs["Eyelashes"], lambda co: {"Head": 1.0})
bind_rigid(objs["EyeLeft"], lambda co: {"LeftEye": 1.0})
bind_rigid(objs["EyeRight"], lambda co: {"RightEye": 1.0})


def weights_of(obj, v):
    return {obj.vertex_groups[g.group].name: g.weight for g in v.groups}


def set_weights(obj, v, wd):
    for vg in obj.vertex_groups:
        try:
            vg.remove([v.index])
        except RuntimeError:
            pass
    total = sum(wd.values()) or 1.0
    for bone, w in wd.items():
        if w / total > 1e-4:
            obj.vertex_groups[bone].add([v.index], w / total, 'REPLACE')


def smooth_weights(obj, iterations, factor, only=None):
    """Diffuse each vertex's weights towards its neighbours', so a hard 0/1 switch (a sleeve seam) becomes a gradient."""
    me = obj.data
    neighbours = [[] for _ in me.vertices]
    for e in me.edges:
        a, b = e.vertices
        neighbours[a].append(b)
        neighbours[b].append(a)
    current = [weights_of(obj, v) for v in me.vertices]
    for _ in range(iterations):
        nxt = []
        for v in me.vertices:
            nb = neighbours[v.index]
            if not nb or (only is not None and not only(v.co)):
                nxt.append(current[v.index])
                continue
            mixed = {}
            for k, w in current[v.index].items():
                mixed[k] = w * (1.0 - factor)
            for n in nb:
                for k, w in current[n].items():
                    mixed[k] = mixed.get(k, 0.0) + w * factor / len(nb)
            nxt.append(mixed)
        current = nxt
    for v in me.vertices:
        if only is None or only(v.co):
            set_weights(obj, v, current[v.index])


# Soften the shoulder seam of the shirt and the body under it (the sleeve would otherwise peel off the torso when the arm swings).
smooth_weights(objs["Clothes"], 14, 0.5)
smooth_weights(objs["Body"], 8, 0.4, only=lambda co: co.z < 1.38)

# The head is rigid: everything above the jaw follows the Head bone completely. The neck skin is the narrow tube round the neck's axis;
# anything outside that tube (jaw, chin, cheeks, ears) belongs to the head, and the tube itself eases from Neck to Head by height.
NECK_AXIS = (0.0, -0.020)
body = objs["Body"]
for v in body.data.vertices:
    r = math.hypot(v.co.x - NECK_AXIS[0], v.co.y - NECK_AXIS[1])
    t = max(smoothstep(1.415, 1.455, v.co.z), smoothstep(0.050, 0.085, r) * smoothstep(1.385, 1.415, v.co.z))
    if t <= 0.0:
        continue
    wd = {k: w * (1.0 - t) for k, w in weights_of(body, v).items()}
    wd["Head"] = wd.get("Head", 0.0) + t
    set_weights(body, v, wd)

# The collar sits on the neck: let its vertices take the weights of the skin right under them (easing in over the last few centimetres),
# so the two move as one when the head, neck and chest tilt against each other and no skin shows through the neckline.
from mathutils import kdtree
tree = kdtree.KDTree(len(body.data.vertices))
for v in body.data.vertices:
    tree.insert(v.co, v.index)
tree.balance()
clothes = objs["Clothes"]
for v in clothes.data.vertices:
    t = smoothstep(1.28, 1.33, v.co.z)
    if t <= 0.0:
        continue
    _, nearest, _ = tree.find(v.co)
    own = weights_of(clothes, v)
    skin = weights_of(body, body.data.vertices[nearest])
    mixed = {k: own.get(k, 0.0) * (1.0 - t) + skin.get(k, 0.0) * t for k in set(own) | set(skin)}
    set_weights(clothes, v, mixed)

# glTF holds four influences per vertex.
for key in ("Body", "Clothes", "Shoes"):
    select_only(objs[key])
    bpy.ops.object.vertex_group_limit_total(group_select_mode='ALL', limit=4)
    bpy.ops.object.vertex_group_clean(group_select_mode='ALL', limit=0.01)
    bpy.ops.object.vertex_group_normalize_all(group_select_mode='ALL', lock_active=False)

# ---- report ----------------------------------------------------------------------------------------------------------------------------
print("=== WEIGHT REPORT")
for name, o in objs.items():
    unweighted = sum(1 for v in o.data.vertices if sum(g.weight for g in v.groups) < 0.99)
    used = {}
    for v in o.data.vertices:
        for g in v.groups:
            if g.weight > 0.01:
                used[o.vertex_groups[g.group].name] = used.get(o.vertex_groups[g.group].name, 0) + 1
    print("%-10s verts %5d  not fully weighted %4d  bones used %2d  %s" % (name, len(o.data.vertices), unweighted, len(used),
          "" if len(used) > 2 else dict(used)))
missing = [b.name for b in arm_data.bones if not any(b.name in {o.vertex_groups[g.group].name for v in o.data.vertices for g in v.groups if g.weight > 0.01}
                                                      for o in objs.values())]
print("bones with no vertices:", missing)

# ---- textures --------------------------------------------------------------------------------------------------------------------------
for img in bpy.data.images:
    w, h = img.size
    if max(w, h) > MAX_TEXTURE:
        s = MAX_TEXTURE / max(w, h)
        img.scale(int(w * s), int(h * s))
        print("scaled", img.name, (w, h), "->", tuple(img.size))

# ---- save / export ---------------------------------------------------------------------------------------------------------------------
if OUT_BLEND:
    bpy.ops.wm.save_as_mainfile(filepath=OUT_BLEND)
bpy.ops.object.select_all(action='DESELECT')
bpy.ops.export_scene.gltf(filepath=OUT_GLB, export_format='GLB', export_animations=False, export_skins=True, export_apply=False,
                          export_yup=True, export_materials='EXPORT', export_image_format='AUTO', export_cameras=False,
                          export_lights=False, export_extras=False, export_all_influences=False)
print("exported", OUT_GLB)
