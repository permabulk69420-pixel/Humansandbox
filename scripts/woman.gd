# The woman: the rigged human in assets/woman/woman.glb (rigged by tools/rig_woman.py). She stands where she is put, faces +Z, and
#   * watches whoever `target` is: the head and neck turn towards it within human limits, and each eye aims at it on its own
#   * breathes, sways a little, and lets her arms hang relaxed instead of held out in the modelling A-pose
#   * takes a punch: hit() turns the fist's speed and where it landed into a spin on her head, which a spring carries through
#     the spine, neck and head and then settles; she loses track of the player for a moment and then finds them again.
#
# Every bone is posed by writing its rotation directly (nothing is left to an AnimationPlayer). A bone is turned by a rotation in
# model space about its own joint; a child inherits its parents' turns, so the offsets just stack from the hips up.
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

# Relaxed posture: the model is built with the arms held out; hang them nearer her sides.
const ARM_DROP := deg_to_rad(14.0)

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
		parents.append(skeleton.get_bone_parent(i))
		assert(parents[i] < i, "bones must be listed parent first")
	head_center_local = skeleton.get_bone_global_rest(bone["Head"]).affine_inverse() * HEAD_CENTER_REST
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
	hits += 1
	hit_taken.emit(point, strength)


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

	var offsets: Array[Quaternion] = []
	offsets.resize(skeleton.get_bone_count())
	offsets.fill(Quaternion.IDENTITY)
	_add_posture(offsets)
	_add_breathing(offsets)
	_add_look(offsets, dt)
	_add_reaction(offsets)

	for i in offsets.size():
		_pose_bone(i, offsets[i])
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


func _add_posture(offsets: Array[Quaternion]) -> void:
	_stack(offsets, "LeftUpperArm", Quaternion(Vector3.BACK, -ARM_DROP))
	_stack(offsets, "RightUpperArm", Quaternion(Vector3.BACK, ARM_DROP))


func _add_breathing(offsets: Array[Quaternion]) -> void:
	var breath := sin(time * TAU / 4.2)
	_stack(offsets, "Chest", Quaternion(Vector3.RIGHT, -0.008 * breath))
	_stack(offsets, "UpperChest", Quaternion(Vector3.RIGHT, -0.010 * breath))
	_stack(offsets, "LeftShoulder", Quaternion(Vector3.BACK, 0.010 * breath))
	_stack(offsets, "RightShoulder", Quaternion(Vector3.BACK, -0.010 * breath))
	# A weight shift now and then, so she is not carved from one block.
	_stack(offsets, "Spine", Quaternion(Vector3.UP, 0.018 * sin(time * 0.37)) * Quaternion(Vector3.BACK, 0.012 * sin(time * 0.29 + 1.0)))


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
	var turn := Quaternion(Vector3.UP, look_yaw) * Quaternion(Vector3.RIGHT, -look_pitch)
	for part in LOOK_SHARE:
		_stack(offsets, part, Quaternion.IDENTITY.slerp(turn, LOOK_SHARE[part]))


func _add_reaction(offsets: Array[Quaternion]) -> void:
	for part in REACTION_SHARE:
		_stack(offsets, part, rotation_from_vector(hit_angle * REACTION_SHARE[part]))


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
