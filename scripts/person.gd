# One of the club's people: a Mixamo-rigged character (assets/club/people/<name>.glb) that loops a single mocap clip.
#
# The clip is baked onto the character's own skeleton by tools/bake_clips.gd (--target=...) into assets/club/people/<name>_clips.json: per frame,
# how far each bone is turned from its rest pose in model space (the woman's clips are the same format). Here that is turned into an ordinary
# Animation (a rotation track per bone, and the hips' travel) that an AnimationPlayer loops, but only while the person can be seen (the club
# hides whole rooms). The person stands on the floor where it is put.
class_name Person
extends Node3D

const FOLDER := "res://assets/club/people/"

var model: Node3D
var skeleton: Skeleton3D
var player: AnimationPlayer


# Builds the person: the model, and `clip` from its baked clips, looping. Safe to run on a worker thread (the club is built on one).
# `outfit` is the same character in other clothes (<character>_<outfit>.glb): the person is built from the character's own model, so the body,
# hair, boots and every texture are the very same resources, and only the clothes the outfit has (and the character's do not) are taken from
# the other file, in place of the clothes the outfit lacks.
func setup(character: String, clip: String, outfit := "") -> void:
	name = (character if outfit == "" else character + "_" + outfit).capitalize()
	var packed := load(FOLDER + character + ".glb") as PackedScene
	assert(packed != null, character + ".glb is missing")
	model = packed.instantiate()
	add_child(model)
	skeleton = model.find_child("Skeleton3D", true, false)
	if outfit != "":
		_change_clothes(load(FOLDER + character + "_" + outfit + ".glb") as PackedScene)
	# the rig sits a little above the floor (and the model with it): stand the feet on it
	var lift := 0.0
	var walker: Node = skeleton
	while walker != self:
		lift += (walker as Node3D).position.y
		walker = walker.get_parent()
	model.position.y = -lift
	# skinned meshes move away from where they are drawn from: keep them from being culled, and keep the soft brows soft
	for mesh: MeshInstance3D in skeleton.find_children("*", "MeshInstance3D", false, false):
		mesh.extra_cull_margin = 1.0
	var brows := skeleton.get_node_or_null("Eyebrows") as MeshInstance3D
	var source := brows.get_active_material(0) as BaseMaterial3D if brows != null else null
	if source != null:
		var soft := source.duplicate() as BaseMaterial3D
		soft.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		soft.cull_mode = BaseMaterial3D.CULL_DISABLED
		brows.set_surface_override_material(0, soft)
	var library := AnimationLibrary.new()
	library.add_animation(clip, _animation(character, clip))
	player = AnimationPlayer.new()
	player.name = "Player"
	player.add_animation_library("", library)
	player.autoplay = clip
	add_child(player)
	visibility_changed.connect(_on_visibility_changed)


func _on_visibility_changed() -> void:
	player.active = is_visible_in_tree()


func _change_clothes(outfit_scene: PackedScene) -> void:
	var other := outfit_scene.instantiate()
	var other_skeleton: Skeleton3D = other.find_child("Skeleton3D", true, false)
	for mesh in skeleton.get_children():
		if other_skeleton.get_node_or_null(NodePath(mesh.name)) == null:
			skeleton.remove_child(mesh)
			mesh.free()
	for mesh in other_skeleton.get_children():
		if skeleton.get_node_or_null(NodePath(mesh.name)) == null:
			other_skeleton.remove_child(mesh)
			skeleton.add_child(mesh)
	other.free()


func _animation(character: String, clip: String) -> Animation:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FOLDER + character + "_clips.json"))
	assert(data.clips.has(clip), "%s has no clip called %s" % [character, clip])
	var c: Dictionary = data.clips[clip]
	var fps: float = data.fps
	var frames := int(c.frames)
	var anim := Animation.new()
	anim.length = float(c.length)
	anim.loop_mode = Animation.LOOP_LINEAR if c.loop else Animation.LOOP_NONE
	var skeleton_path := String(get_path_to(skeleton))
	for k in data.bones.size():
		var bone_name: String = data.bones[k]
		var i := skeleton.find_bone(bone_name)
		var rest_q := skeleton.get_bone_rest(i).basis.get_rotation_quaternion()
		var rest_gq := skeleton.get_bone_global_rest(i).basis.get_rotation_quaternion()
		var track := anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(track, NodePath("%s:%s" % [skeleton_path, bone_name]))
		for f in frames:
			var row: Array = c.rot[f]
			var offset := Quaternion(row[k * 4], row[k * 4 + 1], row[k * 4 + 2], row[k * 4 + 3]).normalized()
			# the turn in model space, in this bone's own frame: its rest orientation conjugated by the turn (as woman.gd poses her bones)
			anim.rotation_track_insert_key(track, f / fps, rest_q * (rest_gq.inverse() * offset * rest_gq))
	var hips := skeleton.find_bone(String(data.bones[0]))
	var rest_origin := skeleton.get_bone_rest(hips).origin
	var travel := anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(travel, NodePath("%s:%s" % [skeleton_path, data.bones[0]]))
	for f in frames:
		var h: Array = c.hips[f]
		anim.position_track_insert_key(travel, f / fps, rest_origin + Vector3(h[0], h[1], h[2]))
	return anim
