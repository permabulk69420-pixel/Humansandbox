# The VR hands: a skinned hand model on each controller, posed from how far the trigger and grip are squeezed. A hand that is holding the
# board's edge closes its fingers round it by the pre-solved path in assets/hands/grip_solution.json (tools/solve_grip.gd).
class_name VrHands
extends RefCounted

const GRIP_ROTATION := {"left": PI / 2.0, "right": -PI / 2.0}   # the hand meshes are authored with fingers along -Z and palms along -Y
const CLOSE_TIME := 0.12                                         # seconds the fingers take to close onto what they hold
const SOLUTION := "res://assets/hands/grip_solution.json"
# Conventional authored grip profiles: the hand holds a fixed pose instead of closing blindly through the mesh.
const GRIP_POSES := {
	"thin": {"animation": "Grip", "amount": 0.86},
	"medium": {"animation": "Grip", "amount": 0.72},
	"large": {"animation": "Grip", "amount": 0.58},
	"pinch": {"animation": "Pinch", "amount": 1.0},
}


class Joint:
	var bone := -1
	var open: Quaternion
	var grip: Quaternion
	var fist: Quaternion


class HandState:
	var handedness := ""
	var controller: Node3D          # an XRController3D (anything with get_float, position and a transform will do)
	var anchor: Node3D              # the hand model's own offset on the controller
	var model: HandModel
	var home := Transform3D.IDENTITY
	var joints := {}                # finger -> Array[Joint]
	var held := false               # holding the board's edge
	var pointing := false           # showing the menu: the hand points instead of following the trigger and grip
	var held_pose = null            # { animation, amount } while holding
	var path_elapsed := 0.0
	var was_squeezed := false
	var bar_offset := Vector3.ZERO  # the solved plate in the grip socket's frame
	var plate_out := Vector3.RIGHT
	var paths := {}                 # finger -> Array of poses (a joint amount per joint) the fingers pass through closing on the plate

	func squeeze() -> float:
		return controller.get_float("grip")

	func trigger() -> float:
		return controller.get_float("trigger")

	func tracked() -> bool:
		return controller.get_has_tracking_data() if controller.has_method("get_has_tracking_data") else true


var states: Array[HandState] = []
var visible := true


# Puts a hand on each controller that exists (controllers: { "left": node, "right": node }).
func _init(controllers: Dictionary) -> void:
	var solution = JSON.parse_string(FileAccess.get_file_as_string(SOLUTION)) if FileAccess.file_exists(SOLUTION) else null
	for handedness in ["left", "right"]:
		var controller: Node3D = controllers.get(handedness)
		if controller == null:
			continue
		var model := HandModel.create(handedness)
		if model == null:
			continue
		var s := HandState.new()
		s.handedness = handedness
		s.controller = controller
		s.model = model
		s.anchor = Node3D.new()
		s.anchor.name = "%s-hand-grip-offset" % handedness
		s.anchor.rotation = Vector3(0.0, 0.0, GRIP_ROTATION[handedness])
		s.anchor.add_child(model.root)
		controller.add_child(s.anchor)
		s.home = s.anchor.transform
		for finger in HandModel.FINGERS:
			var list: Array[Joint] = []
			for bone: int in model.finger_bones[finger]:
				var j := Joint.new()
				j.bone = bone
				j.open = model.end_rotation("Open", bone)
				j.grip = model.end_rotation("Grip", bone)
				j.fist = model.end_rotation("Fist", bone)
				list.append(j)
			s.joints[finger] = list
		if solution != null and solution.has(handedness):
			var mine: Dictionary = solution[handedness]
			s.bar_offset = Vector3(mine.bar_offset[0], mine.bar_offset[1], mine.bar_offset[2])
			s.plate_out = Vector3(mine.plate_out[0], mine.plate_out[1], mine.plate_out[2])
			s.paths = mine.fingers
		states.append(s)


func set_visible(value: bool) -> void:
	visible = value
	for s in states:
		s.anchor.visible = value


# Positions of the two grips in play space (null for one that is not tracked), for hand balancing.
func grip_positions() -> Dictionary:
	var out := {"left": null, "right": null}
	for s in states:
		if s.tracked():
			out[s.handedness] = s.controller.position
	return out


func update(dt: float) -> void:
	for s in states:
		_update_pose(s, dt)


func _update_pose(s: HandState, dt: float) -> void:
	var trigger := s.trigger()
	var squeeze := s.squeeze()
	# A hand that holds something (a board grab) takes the authored pose for that grip; the solved path then fits each finger to it.
	if s.pointing:
		s.model.set_pose("Point", 1.0)
	elif s.held_pose != null and squeeze > 0.08:
		s.model.set_pose(s.held_pose.animation, s.held_pose.amount)
	elif squeeze > 0.08 and trigger > 0.08:
		s.model.set_pose("Fist", maxf(trigger, squeeze))
	elif squeeze > 0.08:
		s.model.set_pose("Grip", squeeze)
	elif trigger > 0.08:
		s.model.set_pose("Pinch", trigger)
	else:
		s.model.set_pose("Open", 0.0)
	if s.held and not s.paths.is_empty():
		s.path_elapsed = minf(CLOSE_TIME, s.path_elapsed + maxf(0.0, dt))
		for finger in s.joints:
			var path: Array = s.paths[finger]
			var t := s.path_elapsed / CLOSE_TIME * (path.size() - 1)
			var index := int(floor(t))
			var a: Array = path[index]
			var b: Array = path[mini(index + 1, path.size() - 1)]
			var joints: Array = s.joints[finger]
			for i in joints.size():
				var j: Joint = joints[i]
				s.model.set_joint(j.bone, lerpf(a[i], b[i], t - index), j.open, j.grip, j.fist)
