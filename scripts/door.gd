# The room's door: hinged on one side and swung by taking hold of a handle (grip) and moving your hand round the hinge. It stays wherever
# you leave it. Positive angles swing it into the room, negative ones into the hallway.
class_name HingedDoor
extends Node3D

const LIMIT := deg_to_rad(105.0)

var held_by := ""
var locked := false                  # a locked door cannot be taken hold of
var base_yaw := 0.0                  # how the closed door is turned in the world (the swing is added to it)
var handles: Array[Vector3] = []     # where to take hold of it, in the door's own space (one on each face)
var angle := 0.0
var _grab_hand_angle := 0.0
var _grab_door_angle := 0.0


func set_angle(value: float) -> void:
	angle = clampf(value, -LIMIT, LIMIT)
	rotation.y = base_yaw + angle


# How far a point (a hand, in the world) is from the nearest handle.
func grab_distance(world_point: Vector3) -> float:
	var best := INF
	for handle in handles:
		best = minf(best, (global_transform * handle).distance_to(world_point))
	return best


func grab(hand: String, world_point: Vector3) -> void:
	if locked:
		return
	held_by = hand
	_grab_hand_angle = _hand_angle(world_point)
	_grab_door_angle = angle


# While held: the door follows the hand round the hinge.
func drag(world_point: Vector3) -> void:
	var moved := wrapf(_hand_angle(world_point) - _grab_hand_angle, -PI, PI)
	set_angle(_grab_door_angle - moved)


func release() -> void:
	held_by = ""


# Where a point is, as a bearing round the hinge on the floor plan.
func _hand_angle(point: Vector3) -> float:
	var from_hinge := point - global_position
	return atan2(from_hinge.z, from_hinge.x)
