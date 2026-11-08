# Solves how each hand holds the blowtorch without any finger going into it.
#
# It uses the hand's real skinned mesh (HandModel does the CPU skinning) and a signed distance grid of the torch's body
# (tools/make_torch_sdf.py). For a candidate placement of the torch in the controller's grip frame it finds, for every finger, the most
# closed pose that still has no skin inside the torch, then keeps the placement where the fingers close furthest around the grip.
# The trigger lever is tested as a box that swings through its travel, so the index finger rests on it released and pushes it pressed.
#
#   python3 tools/make_torch_sdf.py assets/props/blowtorch/cinder_blowtorch.glb /tmp/torch_sdf.bin
#   godot --headless --path . -s res://tools/solve_torch_grip.gd -- /tmp/torch_sdf.bin assets/props/blowtorch/grip_solution.json [scale] [yaw_limit_degrees]
#
# The result is read by Blowtorch (scripts/blowtorch.gd) and VrHands (scripts/vr_hands.gd): the torch's offset and yaw in the grip frame,
# and one curl amount per finger (0 open .. 1 closed, in HandModel.set_joint's terms).
extends SceneTree

const TOLERANCE := 0.0008              # metres of skin allowed inside the (already 1.5 mm thickened) torch
const LEVER_PIVOT := Vector3(0.0, 0.245, -0.026)
const LEVER_BOX_MIN := Vector3(-0.0045, -0.0385, -0.0165)    # the lever's extent below and in front of its pivot, a hair oversize
const LEVER_BOX_MAX := Vector3(0.0045, 0.0025, 0.0035)
const LEVER_TRAVEL := deg_to_rad(-11.5)                        # Trigger_Press: rotation about X when fully pulled
const FINGERS := ["thumb", "index", "middle", "ring", "pinky"]


class Sdf:
	var origin := Vector3.ZERO
	var voxel := 0.0015
	var size := Vector3i.ZERO
	var data := PackedFloat32Array()

	func load_file(path: String) -> void:
		var f := FileAccess.open(path, FileAccess.READ)
		origin = Vector3(f.get_float(), f.get_float(), f.get_float())
		voxel = f.get_float()
		size = Vector3i(f.get_32(), f.get_32(), f.get_32())
		data = f.get_buffer(size.x * size.y * size.z * 4).to_float32_array()

	func at(x: int, y: int, z: int) -> float:
		return data[x + size.x * (y + size.y * z)]

	func sample(p: Vector3) -> float:
		var fx := (p.x - origin.x) / voxel - 0.5
		var fy := (p.y - origin.y) / voxel - 0.5
		var fz := (p.z - origin.z) / voxel - 0.5
		var x0 := int(floor(fx))
		var y0 := int(floor(fy))
		var z0 := int(floor(fz))
		if x0 < 0 or y0 < 0 or z0 < 0 or x0 + 1 >= size.x or y0 + 1 >= size.y or z0 + 1 >= size.z:
			return 1.0
		var tx := fx - x0
		var ty := fy - y0
		var tz := fz - z0
		var c00 := lerpf(at(x0, y0, z0), at(x0 + 1, y0, z0), tx)
		var c10 := lerpf(at(x0, y0 + 1, z0), at(x0 + 1, y0 + 1, z0), tx)
		var c01 := lerpf(at(x0, y0, z0 + 1), at(x0 + 1, y0, z0 + 1), tx)
		var c11 := lerpf(at(x0, y0 + 1, z0 + 1), at(x0 + 1, y0 + 1, z0 + 1), tx)
		return lerpf(lerpf(c00, c10, ty), lerpf(c01, c11, ty), tz)


class Joint:
	var bone := -1
	var open: Quaternion
	var grip: Quaternion
	var fist: Quaternion


var sdf := Sdf.new()
var grip_point := Vector3.ZERO
var model: HandModel
var skeleton_to_grip := Transform3D.IDENTITY
var joints := {}
var parts := {}                        # finger or "palm" -> PackedInt32Array of vertex indices
var part_edges := {}                   # part -> PackedInt32Array of vertex pairs (an edge each) touching that part
var part_faces := {}                   # part -> PackedInt32Array of vertex triples (a triangle each) touching that part


func _init() -> void:
	run.call_deferred()


func run() -> void:
	var args := OS.get_cmdline_user_args()
	sdf.load_file(args[0])
	var out_path: String = args[1]
	var scale := float(args[2]) if args.size() > 2 else 1.0
	var yaw_limit := float(args[3]) if args.size() > 3 else 60.0
	var torch: Node3D = (load("res://assets/props/blowtorch/cinder_blowtorch.glb") as PackedScene).instantiate()
	grip_point = (torch.find_child("GripPoint", true, false) as Node3D).position
	var result := {"scale": scale}
	for handedness in ["right", "left"]:
		var t0 := Time.get_ticks_msec()
		result[handedness] = solve_hand(handedness, scale, yaw_limit)
		print("SOLVED %s in %d s: %s" % [handedness, (Time.get_ticks_msec() - t0) / 1000, JSON.stringify(result[handedness])])
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(result, "  "))
	f.close()
	print("WROTE ", out_path)
	quit()


# ---- the hand -------------------------------------------------------------------------------------------------------------------------

func make_hand(handedness: String) -> void:
	for c in root.get_children():
		c.queue_free()
	model = HandModel.create(handedness)
	var controller := Node3D.new()
	root.add_child(controller)
	var anchor := Node3D.new()
	anchor.rotation = Vector3(0.0, 0.0, VrHands.GRIP_ROTATION[handedness])
	anchor.position = -(anchor.basis * model.skeleton.get_bone_global_rest(model.grip_bone).origin)
	anchor.add_child(model.root)
	controller.add_child(anchor)
	model.prepare_skinning()
	skeleton_to_grip = model.skeleton.global_transform
	joints.clear()
	for finger in HandModel.FINGERS:
		var list: Array[Joint] = []
		for bone: int in model.finger_bones[finger]:
			var j := Joint.new()
			j.bone = bone
			j.open = model.end_rotation("Open", bone)
			j.grip = model.end_rotation("Grip", bone)
			j.fist = model.end_rotation("Fist", bone)
			list.append(j)
		joints[finger] = list
	# which finger moves each vertex most
	var lists := {"palm": [], "thumb": [], "index": [], "middle": [], "ring": [], "pinky": []}
	var bone_part := {}
	for finger in HandModel.FINGERS:
		for bone: int in model.finger_bones[finger]:
			bone_part[bone] = finger
	for i in model.verts.size():
		var best_w := -1.0
		var best_bone := -1
		for ch in 4:
			var w := model.vert_weights[i * 4 + ch]
			if w > best_w:
				best_w = w
				best_bone = model.skin_bone[model.vert_bones[i * 4 + ch]]
		lists[bone_part.get(best_bone, "palm")].append(i)
	parts.clear()
	var vertex_part := PackedStringArray()
	vertex_part.resize(model.verts.size())
	for k in lists:
		parts[k] = PackedInt32Array(lists[k])
		for i: int in lists[k]:
			vertex_part[i] = k
	# edges and faces, so a thin obstacle cannot slip between the sample points
	var edges := {}
	var faces := {}
	for k in lists:
		edges[k] = []
		faces[k] = []
	for t in range(0, model.triangles.size(), 3):
		var tri := [model.triangles[t], model.triangles[t + 1], model.triangles[t + 2]]
		var seen := {}
		for v: int in tri:
			seen[vertex_part[v]] = true
		for k in seen:
			faces[k].append_array(tri)
		for e in 3:
			var a: int = tri[e]
			var b: int = tri[(e + 1) % 3]
			var pa := vertex_part[a]
			var pb := vertex_part[b]
			edges[pa].append_array([a, b])
			if pb != pa:
				edges[pb].append_array([a, b])
	part_edges.clear()
	part_faces.clear()
	for k in lists:
		part_edges[k] = PackedInt32Array(edges[k])
		part_faces[k] = PackedInt32Array(faces[k])


func pose(amounts: Dictionary) -> void:
	for finger in HandModel.FINGERS:
		var a: float = amounts.get(finger, 0.0)
		for j: Joint in joints[finger]:
			model.set_joint(j.bone, a, j.open, j.grip, j.fist)


# ---- the torch ------------------------------------------------------------------------------------------------------------------------

# The torch in the controller's grip frame: turned (yaw about Y, then pitch about X, then roll about Z; degrees) and moved so that its
# GripPoint sits at `adjust`.
func placement(scale: float, angles: Vector3, adjust: Vector3) -> Transform3D:
	var basis := Basis(Vector3.UP, deg_to_rad(angles.x)) * Basis(Vector3.RIGHT, deg_to_rad(angles.y)) * Basis(Vector3.BACK, deg_to_rad(angles.z)) * Basis.from_scale(Vector3.ONE * scale)
	return Transform3D(basis, adjust - basis * grip_point)


# The lever as a box that swings about its pivot: negative inside it (torch units).
func lever_sd(p: Vector3, angle: float) -> float:
	var q := (p - LEVER_PIVOT)
	q = Basis(Vector3.RIGHT, -angle) * q
	var centre := (LEVER_BOX_MIN + LEVER_BOX_MAX) * 0.5
	var half := (LEVER_BOX_MAX - LEVER_BOX_MIN) * 0.5
	var d := (q - centre).abs() - half
	return d.max(Vector3.ZERO).length() + minf(maxf(d.x, maxf(d.y, d.z)), 0.0)


# The lowest signed distance (in metres, negative = skin inside the torch) of one part of the hand, with the hand as it is posed now:
# its vertices, the middles of its edges and the centres of its faces.
func clearance(group: String, to_torch: Transform3D, scale: float, lever_angle: float) -> float:
	var matrices := model.skin_matrices()
	var xf := to_torch * skeleton_to_grip
	var count := model.verts.size()
	var pts := PackedVector3Array()
	pts.resize(count)
	for i in count:
		pts[i] = xf * model.skinned_vertex(i, matrices)
	var worst := 1.0
	for i in parts[group]:
		worst = minf(worst, _sd(pts[i], lever_angle))
	var e: PackedInt32Array = part_edges[group]
	for k in range(0, e.size(), 2):
		worst = minf(worst, _sd((pts[e[k]] + pts[e[k + 1]]) * 0.5, lever_angle))
	var f: PackedInt32Array = part_faces[group]
	for k in range(0, f.size(), 3):
		worst = minf(worst, _sd((pts[f[k]] + pts[f[k + 1]] + pts[f[k + 2]]) / 3.0, lever_angle))
	return worst * scale


func _sd(p: Vector3, lever_angle: float) -> float:
	return minf(sdf.sample(p), lever_sd(p, lever_angle) - 0.0015)


# The most closed amount (0 open .. 1 closed) of one finger that stays clear of the torch.
func solve_finger(finger: String, to_torch: Transform3D, scale: float, others: Dictionary, lever_angle: float) -> float:
	var base := others.duplicate()
	base[finger] = 0.0
	pose(base)
	if clearance(finger, to_torch, scale, lever_angle) < -TOLERANCE:
		return -1.0                         # already inside the torch when open: this placement cannot work
	var lo := 0.0
	var hi := 1.0
	base[finger] = 1.0
	pose(base)
	if clearance(finger, to_torch, scale, lever_angle) >= -TOLERANCE:
		return 1.0
	for i in 11:
		var mid := (lo + hi) * 0.5
		base[finger] = mid
		pose(base)
		if clearance(finger, to_torch, scale, lever_angle) >= -TOLERANCE:
			lo = mid
		else:
			hi = mid
	return lo


# Evaluates one placement: how far the fingers close, and whether the palm is in clean contact.
func evaluate(scale: float, angles: Vector3, adjust: Vector3) -> Dictionary:
	var to_grip := placement(scale, angles, adjust)
	var to_torch := to_grip.affine_inverse()
	pose({})
	var palm := clearance("palm", to_torch, scale, 0.0)
	var res := {"angles": angles, "offset": adjust, "palm": palm, "score": -1.0e6}
	if palm < -TOLERANCE:
		res.score = -1.0e5 + palm * 1000.0
		return res
	var amounts := {}
	var feasible := true
	for finger in ["middle", "ring", "pinky", "thumb"]:
		var a := solve_finger(finger, to_torch, scale, amounts, 0.0)
		if a < 0.0:
			feasible = false
			break
		amounts[finger] = a
	if not feasible:
		res.score = -5.0e4
		return res
	var released := solve_finger("index", to_torch, scale, amounts, 0.0)
	var pressed := solve_finger("index", to_torch, scale, amounts, LEVER_TRAVEL)
	if released < 0.0 or pressed < 0.0:
		res.score = -4.0e4
		return res
	amounts["index_released"] = released
	amounts["index_pressed"] = maxf(pressed, released)
	res["amounts"] = amounts
	# The score. A finger only counts if the torch stops it (a finger that closes fully without touching anything is curling through
	# air); the palm has to be on the grip, not floating off it; and the torch should stay near where the controller really is.
	var closing := 0.0
	for finger in ["middle", "ring", "pinky"]:
		var a: float = amounts[finger]
		closing += (1.0 + a) if a < 0.999 else 0.0
	closing += (0.5 + 0.5 * amounts.thumb) if amounts.thumb < 0.999 else 0.0
	closing += (0.5 + 0.5 * released) if released < 0.999 else 0.0
	var gap := maxf(0.0, palm - 0.002)
	res.score = closing - 150.0 * gap - 0.01 * absf(angles.x) - 0.006 * absf(angles.y) - 0.006 * absf(angles.z) - 15.0 * adjust.length()
	return res


func solve_hand(handedness: String, scale: float, yaw_limit: float) -> Dictionary:
	make_hand(handedness)
	var best := {"score": -1.0e9}
	var count := 0
	# coarse sweep over where the torch sits in the grip frame and how it is turned
	var side := -1.0 if handedness == "right" else 1.0      # the palm faces -X on the right hand, +X on the left: the torch is on that side
	for yaw in [-yaw_limit, 0.0, yaw_limit]:
		for pitch in [-20.0, 0.0, 20.0]:
			for roll in [-10.0, 0.0, 10.0]:
				for dx_i in 8:
					var dx := side * (0.005 + 0.007 * dx_i)
					var dz := -0.04
					while dz <= 0.0401:
						var r := evaluate(scale, Vector3(yaw, pitch, roll), Vector3(dx, 0.0, dz))
						count += 1
						if r.score > best.score:
							best = r
						dz += 0.01
	print("  coarse sweep of %d placements: best score %.2f angles %s offset %s" % [count, best.score, best.angles, best.offset])
	# refine around the best, moving one thing at a time while it keeps improving
	var step := Vector3(0.005, 0.004, 0.005)
	var angle_step := 6.0
	for round in 4:
		var improved := true
		while improved:
			improved = false
			for d in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, -1, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
				var r := evaluate(scale, best.angles, best.offset + d * step)
				if r.score > best.score + 1.0e-4:
					best = r
					improved = true
			for axis in 3:
				for sign in [1.0, -1.0]:
					var a: Vector3 = best.angles
					a[axis] += sign * angle_step
					if absf(a.x) > yaw_limit + 12.0 or absf(a.y) > 32.0 or absf(a.z) > 18.0:
						continue
					var r := evaluate(scale, a, best.offset)
					if r.score > best.score + 1.0e-4:
						best = r
						improved = true
		step *= 0.5
		angle_step *= 0.5
	# The index finger can only close as far as the torch lets it, and that is the pulled position. Released, it rests half way, so that
	# squeezing the trigger visibly curls it in (any amount short of the solved one is clear of the torch too).
	var amounts: Dictionary = best.amounts
	amounts["index_pressed"] = maxf(amounts.index_pressed, amounts.index_released)
	amounts["index_released"] = 0.5 * amounts.index_pressed
	# the final check, with every finger in its solved pose and the lever both ways
	var to_torch := placement(scale, best.angles, best.offset).affine_inverse()
	var check := {}
	for state in ["released", "pressed"]:
		var set := {}
		for f in ["thumb", "middle", "ring", "pinky"]:
			set[f] = amounts[f]
		set["index"] = amounts["index_" + state]
		pose(set)
		var lever := 0.0 if state == "released" else LEVER_TRAVEL
		for part in parts:
			check["%s_%s" % [part, state]] = snappedf(clearance(part, to_torch, scale, lever) * 1000.0, 0.01)
	return {
		"yaw": snappedf(best.angles.x, 0.1),
		"pitch": snappedf(best.angles.y, 0.1),
		"roll": snappedf(best.angles.z, 0.1),
		"offset": [snappedf(best.offset.x, 0.0001), snappedf(best.offset.y, 0.0001), snappedf(best.offset.z, 0.0001)],
		"palm_clearance_mm": snappedf(best.palm * 1000.0, 0.01),
		"fingers": {
			"thumb": snappedf(amounts.thumb, 0.001), "index_released": snappedf(amounts.index_released, 0.001),
			"index_pressed": snappedf(amounts.index_pressed, 0.001), "middle": snappedf(amounts.middle, 0.001),
			"ring": snappedf(amounts.ring, 0.001), "pinky": snappedf(amounts.pinky, 0.001),
		},
		"clearance_mm": check,
	}
