# A physical body for a strapped woman: a solid capsule for each part of her, which is pulled towards where her animation wants it (the
# struggle) but cannot go through the table or the straps, and gets shoved by hits. Her skeleton is then posed from these bodies, so what
# you see is the body as the physics leaves it. Not a limp ragdoll: it is driven, with the straps and the table holding it in.
class_name RagdollBody
extends Node3D

const FOLLOW := 26.0              # how fast (per second) each part closes on where the animation wants it
const MAX_SPEED := 3.0
const MAX_SPIN := 18.0
const KICK_DECAY := 8.0           # a shove fades over about an eighth of a second
const BODY_LAYER := 4             # these bodies only collide with the room's solid things (layer 1), not each other

class Part:
	var bone := -1
	var body: RigidBody3D
	var to_body := Transform3D.IDENTITY      # the capsule's frame, in its bone's frame
	var target := Transform3D.IDENTITY       # where the animation wants the capsule (world)
	var kick := Vector3.ZERO
	var radius := 0.05
	var half_cylinder := 0.0                 # half the straight part of the capsule

var skeleton: Skeleton3D
var parts: Array[Part] = []
var floor_y := -INF                    # the table's top: no part is ever asked to go below it


# specs: [bone index, from the bone to the capsule's far end (in the bone's own frame), radius, lift (the capsule's middle moved this far
# along the bone's own frame's +Z, for bones that run along her back rather than through the middle of her)]
func setup(p_skeleton: Skeleton3D, specs: Array) -> void:
	skeleton = p_skeleton
	for spec in specs:
		var part := Part.new()
		part.bone = spec[0]
		var axis: Vector3 = spec[1]
		var radius: float = spec[2]
		var lift: Vector3 = spec[3]
		var length := axis.length()
		var direction := axis / length
		var align := Quaternion(Vector3.UP, direction) if direction.dot(Vector3.UP) > -0.999 else Quaternion(Vector3.RIGHT, PI)
		part.to_body = Transform3D(Basis(align), axis * 0.5 + lift)
		var body := RigidBody3D.new()
		body.name = "Part%d" % part.bone
		body.gravity_scale = 0.0
		body.can_sleep = false
		body.collision_layer = BODY_LAYER
		body.collision_mask = 1
		body.continuous_cd = true
		var shape := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = radius
		capsule.height = maxf(length, radius * 2.0 + 0.002)
		part.radius = radius
		part.half_cylinder = (capsule.height - radius * 2.0) * 0.5
		shape.shape = capsule
		body.add_child(shape)
		add_child(body)
		part.body = body
		parts.append(part)


# Reads where her animation has every part right now (call after she is posed, before pose_skeleton()).
func read_targets() -> void:
	var to_world := skeleton.global_transform
	for part in parts:
		part.target = to_world * skeleton.get_bone_global_pose(part.bone) * part.to_body
		# do not drive a part into the table: its lowest point (the cap on its lower end) stays on or above it
		var lowest := part.target.origin.y - part.radius - part.half_cylinder * absf(part.target.basis.y.normalized().y)
		if lowest < floor_y:
			part.target.origin.y += floor_y - lowest


# Puts every body exactly where it should be, so nothing starts out moving.
func snap() -> void:
	for part in parts:
		part.body.global_transform = part.target
		part.body.linear_velocity = Vector3.ZERO
		part.body.angular_velocity = Vector3.ZERO


func _physics_process(dt: float) -> void:
	for part in parts:
		var body := part.body
		var velocity := (part.target.origin - body.global_position) * FOLLOW
		velocity = velocity.limit_length(MAX_SPEED)
		body.linear_velocity = velocity + part.kick
		var turn := (part.target.basis.get_rotation_quaternion() * body.global_basis.get_rotation_quaternion().inverse()).normalized()
		if turn.w < 0.0:
			turn = -turn
		var spin := Vector3(turn.x, turn.y, turn.z)
		if spin.length() > 1e-5:
			body.angular_velocity = (spin.normalized() * 2.0 * acos(clampf(turn.w, -1.0, 1.0)) * FOLLOW).limit_length(MAX_SPIN)
		else:
			body.angular_velocity = Vector3.ZERO
		part.kick *= exp(-KICK_DECAY * dt)


# Poses her skeleton from the bodies (after read_targets(), so the targets are the animation and not last frame's physics).
func pose_skeleton() -> void:
	var to_skeleton := skeleton.global_transform.affine_inverse()
	for part in parts:
		skeleton.set_bone_global_pose(part.bone, to_skeleton * part.body.global_transform * part.to_body.affine_inverse())


# A hit at `point` moving at `velocity` (world): the parts near it are shoved, the nearest the most.
func push(point: Vector3, velocity: Vector3, strength: float) -> void:
	var shove := velocity.limit_length(6.0) * 0.1 * clampf(strength, 0.0, 1.5)
	for part in parts:
		var near := clampf(1.0 - part.body.global_position.distance_to(point) / 0.45, 0.0, 1.0)
		part.kick += shove * near * near
