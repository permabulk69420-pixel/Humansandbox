# Bakes animation clips from another humanoid rig onto the woman's skeleton and writes them as JSON that scripts/woman.gd plays.
#
#   godot --headless --path . -s res://tools/bake_clips.gd -- <source.glb> <out.json> <clip> [<clip> ...]
#
# How a clip is carried across: each bone's rotation is taken as "how far has it turned from its own rest pose, in model space", which does
# not depend on how either rig orients its bones. The arms are the exception where the rests differ in a way that matters (the source is in
# a T-pose, the woman in an A-pose), so they get a fixed correction that turns her rest arm direction onto the source's. Hips travel is
# scaled to her proportions. For walking clips it also measures how fast the planted foot moves, so she can be walked at the speed her
# feet actually cover the ground (otherwise they skate).
#
# BONE_MAP is the only thing that is specific to a source rig. This table is for the Quaternius Universal Animation Library (CC0);
# for another rig (Mixamo is "mixamorig:Hips", "mixamorig:Spine", ... "mixamorig:LeftUpLeg", ...) change the names on the left.
extends SceneTree

const CENTRE_MAP := {"DEF-hips": "Hips", "DEF-spine.001": "Spine", "DEF-spine.002": "Chest", "DEF-spine.003": "UpperChest",
	"DEF-neck": "Neck", "DEF-head": "Head"}
const SIDE_MAP := {"DEF-shoulder.%s": "%sShoulder", "DEF-upper_arm.%s": "%sUpperArm", "DEF-forearm.%s": "%sLowerArm", "DEF-hand.%s": "%sHand",
	"DEF-thigh.%s": "%sUpperLeg", "DEF-shin.%s": "%sLowerLeg", "DEF-foot.%s": "%sFoot", "DEF-toe.%s": "%sToes"}
const ARM_CORRECTED := ["UpperArm", "LowerArm", "Hand"]
const HAND_DIRECTION_BONE := "DEF-f_middle.01.%s"      # what the source hand points at
const SOURCE_FOOT := "DEF-foot.L"
const FPS := 30.0

var src: Skeleton3D
var tgt: Skeleton3D
var map := {}                 # source bone name -> woman bone name
var tgt_to_src := {}


func _init() -> void:
	run.call_deferred()


func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 3:
		print("usage: -s res://tools/bake_clips.gd -- <source.glb> <out.json> <clip> [<clip> ...]")
		quit(1)
		return
	for k in CENTRE_MAP:
		map[k] = CENTRE_MAP[k]
	for side in ["L", "R"]:
		for k in SIDE_MAP:
			map[k % side] = SIDE_MAP[k] % ("Left" if side == "L" else "Right")
	for k in map:
		tgt_to_src[map[k]] = k

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(args[0], state) != OK:
		push_error("cannot read " + args[0])
		quit(1)
		return
	var scene := doc.generate_scene(state)
	root.add_child(scene)
	src = scene.find_child("Skeleton3D", true, false)
	var player: AnimationPlayer = scene.find_child("AnimationPlayer", true, false)
	var woman := (load("res://assets/woman/woman.glb") as PackedScene).instantiate()
	root.add_child(woman)
	tgt = woman.find_child("Skeleton3D", true, false)

	# woman bones that get animation, parents first
	var bones: Array[String] = []
	for i in tgt.get_bone_count():
		if tgt_to_src.has(tgt.get_bone_name(i)):
			bones.append(tgt.get_bone_name(i))
	var fix := {}                # woman bone -> correction (arms)
	for side in ["Left", "Right"]:
		var s := "L" if side == "Left" else "R"
		var pairs := [["UpperArm", "LowerArm"], ["LowerArm", "Hand"]]
		for pair in pairs:
			var a := tgt.find_bone(side + pair[0])
			var b := tgt.find_bone(side + pair[1])
			var tgt_dir: Vector3 = (tgt.get_bone_global_rest(b).origin - tgt.get_bone_global_rest(a).origin).normalized()
			var sa := src.find_bone(tgt_to_src[side + pair[0]])
			var sb := src.find_bone(tgt_to_src[side + pair[1]])
			var src_dir: Vector3 = (src.get_bone_global_rest(sb).origin - src.get_bone_global_rest(sa).origin).normalized()
			fix[side + pair[0]] = Quaternion(tgt_dir, src_dir)
		var hand := tgt.find_bone(side + "Hand")
		var sh := src.find_bone(tgt_to_src[side + "Hand"])
		var fingers := src.find_bone(HAND_DIRECTION_BONE % s)
		fix[side + "Hand"] = Quaternion(tgt.get_bone_global_rest(hand).basis.y.normalized(),
			(src.get_bone_global_rest(fingers).origin - src.get_bone_global_rest(sh).origin).normalized())
		print("%s arm correction (deg): upper %.0f  lower %.0f  hand %.0f" % [side, rad_to_deg(fix[side + "UpperArm"].get_angle()), rad_to_deg(fix[side + "LowerArm"].get_angle()), rad_to_deg(fix[side + "Hand"].get_angle())])

	var hips_scale := tgt.get_bone_global_rest(tgt.find_bone("Hips")).origin.y / src.get_bone_global_rest(src.find_bone("DEF-hips")).origin.y
	var leg_ratio := (tgt.get_bone_global_rest(tgt.find_bone("LeftUpperLeg")).origin.y - tgt.get_bone_global_rest(tgt.find_bone("LeftFoot")).origin.y) \
		/ (src.get_bone_global_rest(src.find_bone("DEF-thigh.L")).origin.y - src.get_bone_global_rest(src.find_bone(SOURCE_FOOT)).origin.y)
	print("hips scale %.3f, leg ratio %.3f" % [hips_scale, leg_ratio])

	var out := {"source": "Quaternius Universal Animation Library (Standard), CC0 1.0 - https://quaternius.com/packs/universalanimationlibrary.html",
		"fps": FPS, "bones": bones, "clips": {}}
	for clip_name in args.slice(2):
		var anim := player.get_animation(clip_name)
		if anim == null:
			push_error("no clip called " + clip_name)
			continue
		out.clips[clip_name] = bake(anim, bones, fix, hips_scale, leg_ratio)
		var c: Dictionary = out.clips[clip_name]
		print("%-14s %2d frames, %.2fs%s" % [clip_name, c.frames, c.length, ("  ground speed %.2f m/s" % c.speed) if c.speed > 0.0 else ""])

	var file := FileAccess.open(args[1], FileAccess.WRITE)
	file.store_string(JSON.stringify(out))
	file.close()
	print("wrote ", args[1], " (", FileAccess.get_file_as_bytes(args[1]).size() / 1024, " KB)")
	quit()


func bake(anim: Animation, bones: Array[String], fix: Dictionary, hips_scale: float, leg_ratio: float) -> Dictionary:
	var rot_track := {}
	var pos_track := {}
	for i in anim.get_track_count():
		var bone_name := String(anim.track_get_path(i).get_concatenated_subnames())
		if anim.track_get_type(i) == Animation.TYPE_ROTATION_3D:
			rot_track[bone_name] = i
		elif anim.track_get_type(i) == Animation.TYPE_POSITION_3D:
			pos_track[bone_name] = i
	var frames := int(round(anim.length * FPS))
	var rots: Array = []
	var hips: Array = []
	var feet_y: Array[float] = []
	var feet_z: Array[float] = []
	var src_hips_rest := src.get_bone_global_rest(src.find_bone("DEF-hips")).origin
	var foot_index := src.find_bone(SOURCE_FOOT)
	for f in frames:
		var t := float(f) / FPS
		var g := {}                                # source bone index -> model-space transform at this time
		for b in src.get_bone_count():
			_global(b, t, anim, rot_track, pos_track, g)
		var total := {}                            # woman bone name -> model-space rotation away from its rest
		var row: Array = []
		for name in bones:
			var s := src.find_bone(tgt_to_src[name])
			var delta: Quaternion = g[s].basis.get_rotation_quaternion() * src.get_bone_global_rest(s).basis.get_rotation_quaternion().inverse()
			if fix.has(name):
				delta = delta * fix[name]
			total[name] = delta
		for name in bones:
			var parent := tgt.get_bone_parent(tgt.find_bone(name))
			var parent_total := Quaternion.IDENTITY
			if parent >= 0 and total.has(tgt.get_bone_name(parent)):
				parent_total = total[tgt.get_bone_name(parent)]
			var own: Quaternion = parent_total.inverse() * total[name]
			if own.w < 0.0:
				own = -own
			row.append_array([snappedf(own.x, 0.0001), snappedf(own.y, 0.0001), snappedf(own.z, 0.0001), snappedf(own.w, 0.0001)])
		rots.append(row)
		var hp: Vector3 = (g[src.find_bone("DEF-hips")].origin - src_hips_rest) * hips_scale
		hips.append([snappedf(hp.x, 0.0001), snappedf(hp.y, 0.0001), snappedf(hp.z, 0.0001)])
		feet_y.append(g[foot_index].origin.y)
		feet_z.append(g[foot_index].origin.z)

	# ground speed: while the foot is down, how fast does it travel backwards relative to the (stationary) model
	var speed := 0.0
	var low: float = feet_y.min()
	var moved := 0.0
	var time := 0.0
	for f in frames:
		var nxt := (f + 1) % frames
		if feet_y[f] < low + 0.03 and feet_y[nxt] < low + 0.03:
			var dz: float = feet_z[nxt] - feet_z[f]
			if f + 1 == frames:
				dz = 0.0
			moved += -dz
			time += 1.0 / FPS
	if time > 0.2:
		speed = moved / time * leg_ratio
	return {"frames": frames, "length": anim.length, "loop": anim.loop_mode != Animation.LOOP_NONE, "speed": snappedf(speed, 0.01),
		"hips": hips, "rot": rots}


func _global(b: int, t: float, anim: Animation, rot_track: Dictionary, pos_track: Dictionary, cache: Dictionary) -> Transform3D:
	if cache.has(b):
		return cache[b]
	var name := src.get_bone_name(b)
	var rest := src.get_bone_rest(b)
	var q := rest.basis.get_rotation_quaternion()
	var p := rest.origin
	if rot_track.has(name):
		q = anim.rotation_track_interpolate(rot_track[name], t)
	if pos_track.has(name):
		p = anim.position_track_interpolate(pos_track[name], t)
	var local := Transform3D(Basis(q), p)
	var parent := src.get_bone_parent(b)
	var result := local if parent < 0 else _global(parent, t, anim, rot_track, pos_track, cache) * local
	cache[b] = result
	return result
