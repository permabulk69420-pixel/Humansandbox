# One skinned hand (assets/hands/LeftHand.glb, RightHand.glb): its skeleton, the five authored poses (Open, Grip, Fist, Pinch, Point,
# each a 1 second clip of the finger bones) and the grip socket bone that held things attach to. Poses are applied by writing
# the bone rotations directly, so nothing is left to an AnimationPlayer to overwrite.
class_name HandModel
extends RefCounted

const FINGERS := ["index", "middle", "ring", "pinky", "thumb"]
const SKIN_DIRECTORY := "res://assets/hands/skin/"

var handedness := "left"
var side := "l"
var root: Node3D
var skeleton: Skeleton3D
var mesh: MeshInstance3D
var clips := {}              # clip name -> Animation
var clip_tracks := {}        # clip name -> Array of [bone index, track index]
var grip_bone := -1          # b_?_grip: where a held thing sits in the hand
var finger_bones := {}       # finger -> Array of bone indices (the pinky has four, the rest three)
# For skinning on the CPU (the offline grip solver only)
var skin_bone := PackedInt32Array()   # skin slot -> bone index
var skin_bind: Array[Transform3D] = []
var verts := PackedVector3Array()
var vert_bones := PackedInt32Array() # four skin slots per vertex
var vert_weights := PackedFloat32Array()
var triangles := PackedInt32Array()


static func create(p_handedness: String) -> HandModel:
	var h := HandModel.new()
	h.handedness = p_handedness
	h.side = "l" if p_handedness == "left" else "r"
	var packed := load("res://assets/hands/%sHand.glb" % p_handedness.capitalize()) as PackedScene
	if packed == null:
		return null
	h.root = packed.instantiate()
	h.skeleton = h.root.find_child("Skeleton3D", true, false)
	for child in h.skeleton.get_children():
		if child is MeshInstance3D:
			h.mesh = child
	var player: AnimationPlayer = h.root.find_child("AnimationPlayer", true, false)
	for clip_name in player.get_animation_list():
		var anim := player.get_animation(clip_name)
		h.clips[String(clip_name)] = anim
		var tracks := []
		for t in anim.get_track_count():
			if anim.track_get_type(t) != Animation.TYPE_ROTATION_3D:
				continue
			var bone := h.skeleton.find_bone(String(anim.track_get_path(t).get_concatenated_subnames()))
			if bone >= 0:
				tracks.append([bone, t])
		h.clip_tracks[String(clip_name)] = tracks
	player.free()
	h.grip_bone = h.skeleton.find_bone("b_%s_grip" % h.side)
	for finger in FINGERS:
		var numbers := [0, 1, 2, 3] if finger == "pinky" else [1, 2, 3]
		var list := []
		for n in numbers:
			var bone := h.skeleton.find_bone("b_%s_%s%d" % [h.side, finger, n])
			if bone >= 0:
				list.append(bone)
		h.finger_bones[finger] = list
	h._apply_skin()
	h.set_pose("Open", 0.0)
	return h


# Anatomical CC0 skin is baked separately to each hand's original UV atlas.
# Colours already contain skin tone; fine normals stay subtle at headset distance.
func _apply_skin() -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.albedo_texture = load(SKIN_DIRECTORY + handedness + "_albedo.png")
	material.roughness = 1.0
	material.roughness_texture = load(SKIN_DIRECTORY + handedness + "_roughness.png")
	material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	material.metallic_specular = 0.35
	material.normal_enabled = true
	material.normal_texture = load(SKIN_DIRECTORY + handedness + "_normal.png")
	material.normal_scale = 0.3
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	material.texture_repeat = false
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.extra_cull_margin = 1.0   # skinned bounds do not follow the pose


# Apply one of the authored poses: the clip is read at `amount` seconds (0 = open, 1 = fully closed).
func set_pose(clip_name: String, amount: float) -> void:
	var anim: Animation = clips.get(clip_name)
	if anim == null:
		return
	var time := clampf(amount, 0.0, anim.length)
	for pair in clip_tracks[clip_name]:
		skeleton.set_bone_pose_rotation(pair[0], anim.rotation_track_interpolate(pair[1], time))


# Where a finger bone ends up at the end of a clip (the fully-open / gripped / fisted pose of that joint).
func end_rotation(clip_name: String, bone: int) -> Quaternion:
	var anim: Animation = clips[clip_name]
	for pair in clip_tracks[clip_name]:
		if pair[0] == bone:
			return anim.rotation_track_interpolate(pair[1], anim.length).normalized()
	return skeleton.get_bone_pose_rotation(bone)


# A joint between its open pose and its gripped pose, then on to a fist: the asset's own mirrored rotation axes, including thumb
# opposition and the pinky metacarpal, rather than aiming every finger at one point.
func set_joint(bone: int, amount: float, open: Quaternion, grip: Quaternion, fist: Quaternion) -> void:
	if amount <= 0.65:
		skeleton.set_bone_pose_rotation(bone, open.slerp(grip, amount / 0.65))
	else:
		skeleton.set_bone_pose_rotation(bone, grip.slerp(fist, (amount - 0.65) / 0.35))


# The tip of the index finger in the world: a little way on from the last joint, along the last bone.
func index_tip() -> Vector3:
	var bones: Array = finger_bones["index"]
	var last: Vector3 = (skeleton.global_transform * skeleton.get_bone_global_pose(bones[bones.size() - 1])).origin
	var before: Vector3 = (skeleton.global_transform * skeleton.get_bone_global_pose(bones[bones.size() - 2])).origin
	return last + (last - before) * 0.9


# The grip socket in the world.
func socket_global() -> Transform3D:
	return skeleton.global_transform * skeleton.get_bone_global_pose(grip_bone)


# ---- CPU skinning, for the offline grip solver (tools/solve_grip.gd) -------------------------------------------------------------
func prepare_skinning() -> void:
	var skin := mesh.skin
	for slot in skin.get_bind_count():
		var bone_name := skin.get_bind_name(slot)
		var bone := skeleton.find_bone(bone_name) if bone_name != "" else skin.get_bind_bone(slot)
		skin_bone.append(bone)
		skin_bind.append(skin.get_bind_pose(slot))
	var arrays := mesh.mesh.surface_get_arrays(0)
	verts = arrays[Mesh.ARRAY_VERTEX]
	vert_bones = arrays[Mesh.ARRAY_BONES]
	vert_weights = arrays[Mesh.ARRAY_WEIGHTS]
	triangles = arrays[Mesh.ARRAY_INDEX]


# The skin matrices for the current pose (skeleton space).
func skin_matrices() -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for slot in skin_bone.size():
		out.append(skeleton.get_bone_global_pose(skin_bone[slot]) * skin_bind[slot])
	return out


# One vertex, skinned, in skeleton space.
func skinned_vertex(i: int, matrices: Array[Transform3D]) -> Vector3:
	var out := Vector3.ZERO
	var v := verts[i]
	for channel in 4:
		var w := vert_weights[i * 4 + channel]
		if w > 0.0:
			out += (matrices[vert_bones[i * 4 + channel]] * v) * w
	return out
