# Physical pickup: the original metre-scale asset, with a fitted grip for each real hand.
class_name KitchenKnife
extends RigidBody3D

const MODEL := "res://assets/props/knife/kitchen_knife.glb"
const SOLUTION := "res://assets/props/knife/grip_solution.json"
const GRAB_TIME := 0.08
const THROW_LIMIT := 9.0
const HANDLE_START := Vector3(0.0, 0.0, -0.05)
const HANDLE_END := Vector3(0.0, 0.0, 0.05)

var held_by := ""
var model: Node3D
var grip_point := Vector3.ZERO
var blade_tip: Node3D
var solution := {}
var _controller: Node3D
var _hold := Transform3D.IDENTITY
var _grab_from := Transform3D.IDENTITY
var _grab_t := 1.0
var _history: Array = []
var _t := 0.0

func _ready() -> void:
	solution = JSON.parse_string(FileAccess.get_file_as_string(SOLUTION))
	model = (load(MODEL) as PackedScene).instantiate()
	add_child(model)
	KillRoom.apply_anisotropic(model)
	var marker := model.find_child("GripPoint", true, false) as Node3D
	grip_point = model.to_local(marker.global_position)
	blade_tip = model.find_child("BladeTip", true, false)
	var mesh := model.find_child("Knife_Mesh", true, false) as MeshInstance3D
	var collision := CollisionShape3D.new()
	collision.shape = mesh.mesh.create_convex_shape(true, false)
	collision.shape.margin = 0.001
	add_child(collision)
	mass = 0.22
	collision_layer = 2
	collision_mask = 1
	continuous_cd = true
	linear_damp = 0.1
	angular_damp = 0.8
	var material := PhysicsMaterial.new()
	material.friction = 0.8
	material.bounce = 0.05
	physics_material_override = material

func _process(delta: float) -> void:
	_t += delta
	if held_by == "":
		return
	if not is_instance_valid(_controller):
		release()
		return
	var target := _controller.global_transform * _hold
	_grab_t = minf(1.0, _grab_t + delta / GRAB_TIME)
	global_transform = _grab_from.interpolate_with(target, smoothstep(0.0, 1.0, _grab_t)) if _grab_t < 1.0 else target
	_history.append([_t, global_position, global_basis])
	while _history.size() > 2 and _t - _history[0][0] > 0.12:
		_history.pop_front()

func grab_distance(world_point: Vector3) -> float:
	var p := to_local(world_point)
	return (p - Geometry3D.get_closest_point_to_segment(p, HANDLE_START, HANDLE_END)).length()

func grab(hand: String, controller: Node3D) -> void:
	if held_by != "" or not is_instance_valid(controller):
		return
	var mine: Dictionary = solution.get(hand, {})
	if mine.is_empty():
		return
	var angles := Basis(Vector3.UP, deg_to_rad(mine.yaw)) * Basis(Vector3.RIGHT, deg_to_rad(mine.pitch)) * Basis(Vector3.BACK, deg_to_rad(mine.roll))
	var offset := Vector3(mine.offset[0], mine.offset[1], mine.offset[2])
	_hold = Transform3D(Basis(Vector3.RIGHT, VrHands.HAND_PITCH), Vector3.ZERO) * Transform3D(angles, offset - angles * grip_point)
	_grab_from = global_transform
	_grab_t = 0.0
	_history.clear()
	_controller = controller
	held_by = hand
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true

func finger_amounts(hand: String) -> Dictionary:
	return solution.get(hand, {}).get("fingers", {}).duplicate()

func release() -> void:
	if held_by == "":
		return
	var velocity := Vector3.ZERO
	var spin := Vector3.ZERO
	if _history.size() >= 2:
		var a: Array = _history[0]
		var b: Array = _history[-1]
		var dt := maxf(b[0] - a[0], 0.001)
		velocity = (b[1] - a[1]) / dt
		var turn := Quaternion(b[2]) * Quaternion(a[2]).inverse()
		if absf(turn.w) < 0.9999:
			spin = turn.get_axis() * turn.get_angle() / dt
	held_by = ""
	_controller = null
	freeze = false
	linear_velocity = velocity.limit_length(THROW_LIMIT)
	angular_velocity = spin.limit_length(25.0)
