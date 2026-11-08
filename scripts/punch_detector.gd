# Decides when a hand has punched her head. A punch is a hand that is moving fast, towards the head, and gets into it. The path a hand
# took since the last frame is tested against the head, not just where it ended up, so a quick swing cannot jump through.
class_name PunchDetector
extends RefCounted

signal punched(hand: String, point: Vector3, velocity: Vector3, strength: float)

const KNUCKLES := 0.075       # metres from the controller out along the fingers (-Z): where the fist actually lands
const MIN_SPEED := 1.5        # m/s: slower than this is a push or a wave, not a punch
const FULL_SPEED := 6.0       # m/s: a full-strength punch
const MAX_SPEED := 40.0       # m/s: faster than any arm; a tracking jump or a recenter, not a punch
const COOLDOWN := 0.30        # seconds before the same hand can hit again
const REACH := 0.025          # a graze this far outside the head still lands
const SMOOTHING := 0.5        # how much of each new speed reading is believed

var hands := {}               # name -> { node, last, velocity, cooldown }
var reference: Node3D         # the play space (XROrigin3D). Hands are measured relative to it, so walking or turning is not a punch.


func add_hand(hand_name: String, node: Node3D) -> void:
	hands[hand_name] = {"node": node, "last": null, "velocity": Vector3.ZERO, "cooldown": 0.0}


static func knuckle_point(node: Node3D) -> Vector3:
	return node.global_position - node.global_transform.basis.z * KNUCKLES


func _to_play_space(point: Vector3) -> Vector3:
	return reference.global_transform.affine_inverse() * point if reference != null else point


func _from_play_space(point: Vector3) -> Vector3:
	return reference.global_transform * point if reference != null else point


func speed_of(hand_name: String) -> float:
	return hands[hand_name].velocity.length()


func update(dt: float, woman: Woman) -> void:
	if dt <= 0.0:
		return
	var centre := woman.head_center()
	for hand_name in hands:
		var h: Dictionary = hands[hand_name]
		var point := knuckle_point(h.node)
		var local := _to_play_space(point)
		h.cooldown = maxf(0.0, h.cooldown - dt)
		if h.last == null:
			h.last = local
			continue
		var last_local: Vector3 = h.last
		var last := _from_play_space(last_local)          # where the hand was, in the play space as it is now
		h.velocity = h.velocity.lerp((point - last) / dt, SMOOTHING)
		h.last = local
		if h.cooldown > 0.0:
			continue
		var velocity: Vector3 = h.velocity
		var speed := velocity.length()
		if speed < MIN_SPEED or speed > MAX_SPEED:
			continue
		var closest := Geometry3D.get_closest_point_to_segment(centre, last, point)
		if closest.distance_to(centre) > Woman.HEAD_RADIUS + REACH:
			continue
		if velocity.normalized().dot((centre - last).normalized()) < 0.2:
			continue   # moving away from the head: pulling a punch back is not a punch
		h.cooldown = COOLDOWN
		var strength := 0.25 + 0.75 * clampf((speed - MIN_SPEED) / (FULL_SPEED - MIN_SPEED), 0.0, 1.0)
		punched.emit(hand_name, closest, velocity, strength)
