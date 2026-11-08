# The woman: the rigged human in assets/woman/woman.glb (rigged by tools/rig_woman.py). She stands where she is put, faces +Z, and
#   * watches whoever `target` is: the head and neck turn towards it within human limits, and each eye aims at it on its own
#   * plays baked mocap clips for her base motion (idle, walk; tools/bake_clips.gd retargets them from a CC0 library onto her skeleton)
#   * walks: she turns her body to face the player when they move round her, can walk to a point (walk_to) or wander about her spot
#   * takes a punch: hit() turns the fist's speed and where it landed into a spin on her head, which a spring carries through
#     the spine, neck and head and then settles; she loses track of the player for a moment and then finds them again.
#
# Every bone is posed by writing its rotation directly (nothing is left to an AnimationPlayer). A bone is turned by a rotation in
# model space about its own joint; a child inherits its parents' turns, so the offsets just stack from the hips up. The clip sets each
# bone's offset first and the looking and the punch reaction are stacked on top of it.
class_name Woman
extends Node3D

signal hit_taken(point: Vector3, strength: float)

const MODEL := "res://assets/woman/woman.glb"
const HEAD_CENTER_REST := Vector3(0.0, 1.52, 0.055)   # the middle of the skull when she stands at rest, in model space
const HEAD_RADIUS := 0.12                             # round her face, jaw and the back of her skull

# Looking
const LOOK_SHARE := {"Neck": 0.35, "Head": 0.65}      # how the turn towards the target is split
const MAX_YAW := deg_to_rad(66.0)                     # the most the head can turn either way
const MAX_PITCH_UP := deg_to_rad(30.0)
const MAX_PITCH_DOWN := deg_to_rad(35.0)
const MAX_EYE_ANGLE := deg_to_rad(38.0)               # the most an eye can turn away from where the head points
const HEAD_RATE := 5.0                                # how briskly the head follows (per second)
const EYE_RATE := 16.0                                # eyes move much faster than heads

# Taking a punch
const REACTION_SHARE := {"Spine": 0.04, "Chest": 0.06, "UpperChest": 0.10, "Neck": 0.30, "Head": 0.50}
const SPIN_GAIN := 34.0                               # radians per second of head spin per (metre * metre-per-second) of torque
const MAX_SPIN := 11.0
const NECK_FREEDOM := Vector3(1.0, 1.4, 0.5)          # pitch, yaw, roll: a neck turns far more easily than it tips sideways
const MAX_REACTION := deg_to_rad(42.0)                # the head never swings further than this
const SPRING_HZ := 1.6
const SPRING_DAMPING := 0.30                          # < 1: it overshoots a little before it settles
const ATTENTION_RETURN := 2.5                         # per second, once she has recovered

# Clips and walking
const CLIPS := "res://assets/woman/clips.json"
const FADE_TIME := 0.25                               # seconds to blend from one clip to the next
const TURN_STEP_RATE := 0.8                           # playback rate of the walk when she is only turning on the spot
const TURN_RATE := deg_to_rad(130.0)                  # the fastest she turns her body
const TURN_ACCEL := deg_to_rad(500.0)
const WALK_ACCEL := 1.2
const FACE_AFTER := deg_to_rad(50.0)                  # she turns her body once the player is further than this off her front...
const FACE_DONE := deg_to_rad(8.0)                    # ...and stops when they are this close to it
const WANDER_RADIUS := 1.2
const KEEP_AWAY := 0.9                                # wandering never takes her this close to the player

var target: Node3D                 # who she watches (the player's camera)
var skeleton: Skeleton3D
var model: Node3D
var hits := 0
var look_weight := 1.0             # 1 = fully watching the target, 0 = staring straight ahead
var hit_angle := Vector3.ZERO      # the head's reaction, as a rotation vector in model space
var hit_velocity := Vector3.ZERO
var stun := 0.0                    # seconds left before she starts watching again
var look_yaw := 0.0                # where the head is turned now (radians; + is her left)
var look_pitch := 0.0              # + is up
var time := 0.0

var bone := {}                     # name -> bone index
var rest_q: Array[Quaternion] = []     # each bone's rest rotation relative to its parent
var rest_gq: Array[Quaternion] = []    # ... and in model space
var rest_origin: Array[Vector3] = []   # each bone's rest position in model space
var parents: Array[int] = []
var head_center_local := Vector3.ZERO  # HEAD_CENTER_REST in the head bone's own frame
var eye_q := {"LeftEye": Quaternion.IDENTITY, "RightEye": Quaternion.IDENTITY}
var saccade := Vector2.ZERO        # a small random flick of the eyes (yaw, pitch)
var saccade_timer := 1.0
var rng := RandomNumberGenerator.new()

var clips := {}                    # clip name -> baked frames (see _load_clips)
var clip_bones: Array[int] = []    # the bones the clips animate, in the order the baked frames list them
var clip_name := "Idle_Loop"
var clip_time := 0.0
var clip_rate := 1.0
var fade_name := ""                # the clip we are blending away from
var fade_time := 0.0
var fade_rate := 1.0
var fade := 1.0                    # 1 = all on the current clip
var walk_speed := 0.8              # m/s her feet cover the ground at in the walk clip, at normal playback

var body_turns := true              # turn the whole body to face the player when they move round to her side
var wander := false                # stroll about `home` when nothing else is going on
var home := Vector3.ZERO           # the spot she wanders round
var move_target = null             # a world point she is walking to (Vector3), or null
var speed := 0.0                   # m/s along her facing
var turn_velocity := 0.0           # rad/s of the body turning
var turning_to_face := false
var pause_timer := 3.0             # seconds before she sets off somewhere
var rest_local_origin: Array[Vector3] = []


func _ready() -> void:
	rng.seed = 7
	var packed := load(MODEL) as PackedScene
	assert(packed != null, "woman.glb is missing")
	model = packed.instantiate()
	add_child(model)
	skeleton = model.find_child("Skeleton3D", true, false)
	var count := skeleton.get_bone_count()
	for i in count:
		bone[skeleton.get_bone_name(i)] = i
		var g := skeleton.get_bone_global_rest(i)
		rest_q.append(skeleton.get_bone_rest(i).basis.get_rotation_quaternion())
		rest_gq.append(g.basis.get_rotation_quaternion())
		rest_origin.append(g.origin)
		rest_local_origin.append(skeleton.get_bone_rest(i).origin)
		parents.append(skeleton.get_bone_parent(i))
		assert(parents[i] < i, "bones must be listed parent first")
	head_center_local = skeleton.get_bone_global_rest(bone["Head"]).affine_inverse() * HEAD_CENTER_REST
	home = global_position
	_load_clips()
	# The hair, brows and lashes stay put when she turns her head only because they are skinned; keep them from being culled.
	for m: MeshInstance3D in skeleton.find_children("*", "MeshInstance3D", false, false):
		m.extra_cull_margin = 1.0
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Brows and lashes are hair-thin: cut out with a hard alpha threshold they break up into jagged black dashes (the Compatibility
	# renderer has no alpha antialiasing), so they are blended softly instead.
	for part in ["Eyebrows", "Eyelashes"]:
		var m := skeleton.get_node_or_null(part) as MeshInstance3D
		var source := m.get_active_material(0) as BaseMaterial3D if m != null else null
		if source != null:
			var soft := source.duplicate() as BaseMaterial3D
			soft.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			soft.cull_mode = BaseMaterial3D.CULL_DISABLED
			m.set_surface_override_material(0, soft)
	update(0.0)


func _process(delta: float) -> void:
	update(delta)


# ---- what the rest of the game asks of her -----------------------------------------------------------------------------------------

# A fist landed at `point` moving at `velocity` (both in world space).
func hit(point: Vector3, velocity: Vector3, strength: float = 1.0) -> void:
	var to_model := skeleton.global_transform.affine_inverse()
	var r: Vector3 = to_model * point - to_model * _head_pivot_world()
	var v: Vector3 = to_model.basis * velocity
	var spin := r.cross(v) * SPIN_GAIN * NECK_FREEDOM   # a push off the neck's axis is a torque on the head
	if spin.length() > MAX_SPIN:
		spin = spin.normalized() * MAX_SPIN
	hit_velocity += spin
	stun = 0.55 + 0.45 * clampf(strength, 0.0, 1.0)
	move_target = null                              # a punch stops her in her tracks
	pause_timer = maxf(pause_timer, 1.5 + strength)
	hits += 1
	hit_taken.emit(point, strength)


# Walk to a point (world space). She turns to it first, then sets off.
func walk_to(point: Vector3) -> void:
	move_target = point
	pause_timer = 0.0


func head_center() -> Vector3:
	return skeleton.global_transform * skeleton.get_bone_global_pose(bone["Head"]) * head_center_local


# The direction her head points (world space).
func head_forward() -> Vector3:
	return (skeleton.global_transform.basis * skeleton.get_bone_global_pose(bone["Head"]).basis * Basis(rest_gq[bone["Head"]].inverse()) * Vector3.BACK).normalized()


# The direction an eye points (world space). side: "Left" or "Right".
func eye_forward(side: String) -> Vector3:
	var b: int = bone[side + "Eye"]
	return (skeleton.global_transform.basis * skeleton.get_bone_global_pose(b).basis * Basis(rest_gq[b].inverse()) * Vector3.BACK).normalized()


func eye_position(side: String) -> Vector3:
	return skeleton.global_transform * skeleton.get_bone_global_pose(bone[side + "Eye"]).origin


func _head_pivot_world() -> Vector3:
	return skeleton.global_transform * skeleton.get_bone_global_pose(bone["Head"]).origin   # where the skull sits on the neck


# ---- the frame ------------------------------------------------------------------------------------------------------------------------

func update(dt: float) -> void:
	if skeleton == null:
		return
	dt = clampf(dt, 0.0, 0.05)
	time += dt
	_update_attention(dt)
	_update_reaction(dt)
	_update_movement(dt)
	_update_clip(dt)

	var offsets: Array[Quaternion] = []
	offsets.resize(skeleton.get_bone_count())
	offsets.fill(Quaternion.IDENTITY)
	var hips_move := _add_clip(offsets)
	_add_look(offsets, dt)
	_add_reaction(offsets)

	for i in offsets.size():
		_pose_bone(i, offsets[i])
	skeleton.set_bone_pose_position(bone["Hips"], rest_local_origin[bone["Hips"]] + hips_move)
	_aim_eyes(offsets, dt)


func _pose_bone(i: int, q: Quaternion) -> void:
	# A rotation q about model-space axes, in this bone's own frame: its rest orientation conjugated by q.
	skeleton.set_bone_pose_rotation(i, rest_q[i] * (rest_gq[i].inverse() * q * rest_gq[i]))


static func rotation_from_vector(v: Vector3) -> Quaternion:
	var a := v.length()
	if a < 1e-6:
		return Quaternion.IDENTITY
	return Quaternion(v / a, a)


func _stack(offsets: Array[Quaternion], bone_name: String, q: Quaternion) -> void:
	var i: int = bone[bone_name]
	offsets[i] = offsets[i] * q


func _update_attention(dt: float) -> void:
	if stun > 0.0:
		stun = maxf(0.0, stun - dt)
		look_weight = maxf(0.0, look_weight - dt * 10.0)
	else:
		look_weight = minf(1.0, look_weight + dt * ATTENTION_RETURN)
	saccade_timer -= dt
	if saccade_timer <= 0.0:
		saccade_timer = rng.randf_range(0.7, 2.4)
		saccade = Vector2(rng.randf_range(-0.045, 0.045), rng.randf_range(-0.03, 0.03))


func _update_reaction(dt: float) -> void:
	var k := pow(TAU * SPRING_HZ, 2.0)
	var c := 2.0 * SPRING_DAMPING * TAU * SPRING_HZ
	hit_velocity += (-k * hit_angle - c * hit_velocity) * dt
	hit_angle += hit_velocity * dt
	if hit_angle.length() > MAX_REACTION:
		hit_angle = hit_angle.normalized() * MAX_REACTION
		hit_velocity *= 0.5
	if hit_angle.length() < 1e-5 and hit_velocity.length() < 1e-4:
		hit_angle = Vector3.ZERO
		hit_velocity = Vector3.ZERO


func _add_look(offsets: Array[Quaternion], dt: float) -> void:
	var yaw := 0.0
	var pitch := 0.0
	if target != null and is_instance_valid(target) and target.is_inside_tree():
		var to_target: Vector3 = skeleton.global_transform.affine_inverse() * target.global_position - _eyes_rest_middle()
		yaw = clampf(atan2(to_target.x, to_target.z), -MAX_YAW, MAX_YAW)
		pitch = clampf(atan2(to_target.y, Vector2(to_target.x, to_target.z).length()), -MAX_PITCH_DOWN, MAX_PITCH_UP)
	# a little idle drift so the head is never perfectly still
	yaw += 0.02 * sin(time * 0.53) * look_weight
	pitch += 0.015 * sin(time * 0.71 + 2.0) * look_weight
	var follow := 1.0 - exp(-HEAD_RATE * dt)
	look_yaw += (yaw * look_weight - look_yaw) * follow
	look_pitch += (pitch * look_weight - look_pitch) * follow
	# pitch first about the model's own X axis (looking up is a negative turn about it), then yaw about the vertical
	var aim := Quaternion(Vector3.UP, look_yaw) * Quaternion(Vector3.RIGHT, -look_pitch)
	# The clip already holds her spine, neck and head in some pose (and swings the pelvis and spine as she walks). Ask the neck and head
	# only for what is still needed to point the head exactly where `aim` says, however the clip has them: the neck takes its share
	# and the head takes whatever is left, so the gaze neither bobs with her stride nor drifts with her idle posture.
	var below := offsets[bone["Hips"]] * offsets[bone["Spine"]] * offsets[bone["Chest"]] * offsets[bone["UpperChest"]]
	var clip_neck := offsets[bone["Neck"]]
	var clip_head := offsets[bone["Head"]]
	var needed := (below * clip_neck * clip_head).inverse() * aim
	if needed.w < 0.0:
		needed = -needed
	var neck_turn := Quaternion.IDENTITY.slerp(needed, LOOK_SHARE["Neck"])
	var head_turn := clip_head.inverse() * neck_turn.inverse() * (below * clip_neck).inverse() * aim
	_stack(offsets, "Neck", neck_turn)
	_stack(offsets, "Head", head_turn)


func _add_reaction(offsets: Array[Quaternion]) -> void:
	for part in REACTION_SHARE:
		_stack(offsets, part, rotation_from_vector(hit_angle * REACTION_SHARE[part]))


# ---- clips ------------------------------------------------------------------------------------------------------------------------------

# assets/woman/clips.json is written by tools/bake_clips.gd: for each clip, per frame, how far each animated bone is turned from its
# parent's pose (as a quaternion), and how far the hips travel.
func _load_clips() -> void:
	if not FileAccess.file_exists(CLIPS):
		push_warning("no baked clips at " + CLIPS)
		return
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CLIPS))
	for bone_name in data.bones:
		clip_bones.append(bone[bone_name])
	for name_in_file in data.clips:
		var c: Dictionary = data.clips[name_in_file]
		var frames := int(c.frames)
		var rot: Array = []
		for f in frames:
			var row: Array = c.rot[f]
			var qs: Array[Quaternion] = []
			for k in clip_bones.size():
				qs.append(Quaternion(row[k * 4], row[k * 4 + 1], row[k * 4 + 2], row[k * 4 + 3]).normalized())
			rot.append(qs)
		var hips: Array[Vector3] = []
		for h in c.hips:
			hips.append(Vector3(h[0], h[1], h[2]))
		clips[name_in_file] = {"frames": frames, "length": float(c.length), "loop": bool(c.loop), "speed": float(c.speed),
			"fps": float(data.fps), "rot": rot, "hips": hips}
	if clips.has("Walk_Loop") and clips["Walk_Loop"].speed > 0.1:
		walk_speed = clips["Walk_Loop"].speed


func _sample(name_of_clip: String, t: float) -> Dictionary:
	var c: Dictionary = clips[name_of_clip]
	var f: float = t * c.fps
	var i0 := int(floor(f))
	var u := f - float(i0)
	var n: int = c.frames
	var i1 := i0 + 1
	if c.loop:
		i0 = posmod(i0, n)
		i1 = posmod(i1, n)
	else:
		i0 = clampi(i0, 0, n - 1)
		i1 = clampi(i1, 0, n - 1)
	var a: Array = c.rot[i0]
	var b: Array = c.rot[i1]
	var out: Array[Quaternion] = []
	for k in a.size():
		out.append(a[k].slerp(b[k], u))
	return {"rot": out, "hips": c.hips[i0].lerp(c.hips[i1], u)}


func _advance(name_of_clip: String, t: float, by: float) -> float:
	var c: Dictionary = clips[name_of_clip]
	t += by
	return fposmod(t, c.length) if c.loop else minf(t, c.length)


func _update_clip(dt: float) -> void:
	if clips.is_empty():
		return
	var moving := speed > 0.05
	var stepping := absf(turn_velocity) > deg_to_rad(14.0)
	var wanted := "Walk_Loop" if ((moving or stepping) and clips.has("Walk_Loop")) else "Idle_Loop"
	if wanted != clip_name:
		fade_name = clip_name
		fade_time = clip_time
		fade_rate = clip_rate
		fade = 0.0
		clip_name = wanted
		clip_time = 0.0
	if moving:
		clip_rate = clampf(speed / walk_speed, 0.5, 1.4)     # her feet keep up with the ground whatever her speed
	else:
		clip_rate = TURN_STEP_RATE if stepping else 1.0
	clip_time = _advance(clip_name, clip_time, dt * clip_rate)
	if fade < 1.0:
		fade_time = _advance(fade_name, fade_time, dt * fade_rate)
		fade = minf(1.0, fade + dt / FADE_TIME)


# Sets each animated bone's offset from the clip (blending from the previous one) and returns how far the hips travel.
func _add_clip(offsets: Array[Quaternion]) -> Vector3:
	if clips.is_empty():
		return Vector3.ZERO
	var now := _sample(clip_name, clip_time)
	var rot: Array = now.rot
	var hips: Vector3 = now.hips
	if fade < 1.0 and fade_name != "":
		var before := _sample(fade_name, fade_time)
		var w := smoothstep(0.0, 1.0, fade)
		for k in rot.size():
			rot[k] = before.rot[k].slerp(rot[k], w)
		hips = before.hips.lerp(hips, w)
	for k in clip_bones.size():
		offsets[clip_bones[k]] = rot[k]
	return hips


# ---- walking ----------------------------------------------------------------------------------------------------------------------------

func _has_target() -> bool:
	return target != null and is_instance_valid(target) and target.is_inside_tree()


# Decides where she is going and how she is turning, then moves her body (this node). Her parent is expected to be unrotated.
func _update_movement(dt: float) -> void:
	var player := Vector3.ZERO
	var watching := _has_target()
	if watching:
		player = Vector3(target.global_position.x, global_position.y, target.global_position.z)
	pause_timer = maxf(0.0, pause_timer - dt)
	var staggered := stun > 0.0
	if move_target == null and wander and pause_timer <= 0.0 and not staggered:
		move_target = _pick_wander_target(player if watching else null)
		if move_target == null:
			pause_timer = 1.0

	var desired_speed := 0.0
	var desired_turn := 0.0
	if move_target != null:
		var to_goal: Vector3 = move_target - global_position
		to_goal.y = 0.0
		var distance := to_goal.length()
		if distance < 0.08:
			move_target = null
			pause_timer = rng.randf_range(2.0, 5.0)
		else:
			var error := wrapf(atan2(to_goal.x, to_goal.z) - rotation.y, -PI, PI)
			desired_turn = clampf(error * 5.0, -TURN_RATE, TURN_RATE)
			if absf(error) < deg_to_rad(35.0):                       # turn on the spot first, walk once she is facing the way
				desired_speed = minf(walk_speed, 0.2 + distance * 1.5)
	elif watching:
		# standing: turn the body to face the player once they have moved well round to the side
		var to_player := player - global_position
		if to_player.length() > 0.05:
			var error := wrapf(atan2(to_player.x, to_player.z) - rotation.y, -PI, PI)
			if turning_to_face and absf(error) < FACE_DONE:
				turning_to_face = false
			elif not turning_to_face and absf(error) > FACE_AFTER:
				turning_to_face = true
			if turning_to_face and body_turns:
				desired_turn = clampf(error * 4.0, -TURN_RATE, TURN_RATE)
	if staggered:
		desired_speed = 0.0
	turn_velocity = move_toward(turn_velocity, desired_turn, TURN_ACCEL * dt)
	speed = move_toward(speed, desired_speed, WALK_ACCEL * (4.0 if staggered else 1.0) * dt)
	rotation.y += turn_velocity * dt
	global_position += Vector3(sin(rotation.y), 0.0, cos(rotation.y)) * speed * dt


func _pick_wander_target(player: Variant) -> Variant:
	for attempt in 10:
		var angle := rng.randf() * TAU
		var point := home + Vector3(cos(angle), 0.0, sin(angle)) * rng.randf_range(0.4, WANDER_RADIUS)
		if point.distance_to(global_position) < 0.4:
			continue
		if player != null:
			var here := Vector2(global_position.x, global_position.z)
			var there := Vector2(point.x, point.z)
			var at := Vector2(player.x, player.z)
			if at.distance_to(there) < KEEP_AWAY:
				continue
			if at.distance_to(Geometry2D.get_closest_point_to_segment(at, here, there)) < KEEP_AWAY * 0.8:
				continue        # and the walk there must not brush past them either
		return point
	return null


func _eyes_rest_middle() -> Vector3:
	return (rest_origin[bone["LeftEye"]] + rest_origin[bone["RightEye"]]) * 0.5


# Each eye turns on its own to look at the target from where it actually is, so they converge as a person's do up close.
func _aim_eyes(offsets: Array[Quaternion], dt: float) -> void:
	var head_total := Quaternion.IDENTITY
	for bone_name in ["Hips", "Spine", "Chest", "UpperChest", "Neck", "Head"]:
		head_total = head_total * offsets[bone[bone_name]]
	var follow := 1.0 - exp(-EYE_RATE * dt)
	var has_target := target != null and is_instance_valid(target) and target.is_inside_tree()
	var target_model := Vector3.ZERO
	if has_target:
		target_model = skeleton.global_transform.affine_inverse() * target.global_position
	for eye in ["LeftEye", "RightEye"]:
		var b: int = bone[eye]
		var wanted := Quaternion.IDENTITY
		if has_target and look_weight > 0.001:
			var from: Vector3 = skeleton.get_bone_global_pose(b).origin
			var direction := (target_model - from).normalized()
			var aim := Quaternion(Vector3.BACK, direction)                               # straight ahead -> at the target
			aim = rotation_from_vector(Vector3.UP * saccade.x * look_weight) * rotation_from_vector(Vector3.LEFT * saccade.y * look_weight) * aim
			var in_head := head_total.inverse() * aim                                    # relative to where the head points
			if in_head.w < 0.0:
				in_head = -in_head                                                        # same turn, the short way round
			if in_head.get_angle() > MAX_EYE_ANGLE:
				in_head = Quaternion(in_head.get_axis(), MAX_EYE_ANGLE)
			wanted = Quaternion.IDENTITY.slerp(in_head, look_weight)
		eye_q[eye] = eye_q[eye].slerp(wanted, follow)
		_pose_bone(b, eye_q[eye])
