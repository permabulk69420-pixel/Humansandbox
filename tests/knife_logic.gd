# Real knife asset, both hand grips and pickup ownership; no headset required.
extends SceneTree

var failures := 0
var checks := 0
var skin_checks := {}

class FakeController extends Node3D:
	var floats := {"grip": 0.0, "trigger": 0.0}
	var tracked := true
	func get_float(action: String) -> float:
		return floats.get(action, 0.0)
	func get_has_tracking_data() -> bool:
		return tracked

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("%s %s" % ["ok" if ok else "FAIL", label])

func _init() -> void:
	run.call_deferred()

func run() -> void:
	var left := FakeController.new()
	var right := FakeController.new()
	root.add_child(left)
	root.add_child(right)
	left.position = Vector3(-0.3, 1.3, 0)
	right.position = Vector3(0.3, 1.3, 0)
	left.rotation.y = 0.3
	right.rotation.y = -0.2
	var hands := VrHands.new({"left": left, "right": right})
	var knife := KitchenKnife.new()
	root.add_child(knife)
	var interactions := HandInteractions.new(hands, null, null, knife)
	var mesh := knife.model.find_child("Knife_Mesh", true, false) as MeshInstance3D
	check(absf(mesh.mesh.get_aabb().size.z - 0.32) < 0.002, "knife keeps its 32 cm metre-scale length")
	check(knife.model.scale.is_equal_approx(Vector3.ONE), "no hidden model scaling")
	check(knife.grip_point.length() < 0.0001, "root aligns with supplied handle-centre GripPoint")
	check(knife.continuous_cd and knife.collision_layer == 2 and knife.collision_mask == 1, "CCD and room collision enabled")
	check(knife.grab_distance(knife.to_global(Vector3(0, 0, 0.04))) < 0.001, "pickup targets the handle")
	check(knife.grab_distance(knife.blade_tip.global_position) > HandInteractions.GRAB_RADIUS, "blade tip cannot act as the pickup handle")
	for state in hands.states:
		var controller: FakeController = state.controller
		knife.global_transform = Transform3D(Basis.IDENTITY, controller.global_position)
		controller.floats.grip = 0.9
		interactions.update(0.1)
		knife._process(0.1)
		hands.update(0.1)
		check(knife.held_by == state.handedness and knife.freeze, "%s hand picks up and freezes the knife" % state.handedness)
		for i in 3:
			await physics_frame
			await process_frame
		var mine: Dictionary = knife.solution[state.handedness]
		var offset := Vector3(mine.offset[0], mine.offset[1], mine.offset[2])
		var expected := controller.global_transform * (Basis(Vector3.RIGHT, VrHands.HAND_PITCH) * offset)
		check(knife.to_global(knife.grip_point).distance_to(expected) < 0.0001, "%s grip marker matches fitted palm location" % state.handedness)
		var blade := (knife.blade_tip.global_position - knife.to_global(knife.grip_point)).normalized()
		check(blade.dot(-controller.global_basis.z) > 0.5, "%s blade points away from wrist" % state.handedness)
		check(mine.handle_contacts >= 4, "%s fingers contact the handle instead of closing in air" % state.handedness)
		check(mine.fingers.index_pressed == mine.fingers.index_released, "%s knife grip stays fixed when trigger is pressed" % state.handedness)
		state.model.prepare_skinning()
		var matrices := state.model.skin_matrices()
		var vertices := []
		for i in state.model.verts.size():
			var p := knife.to_local(state.model.skeleton.global_transform * state.model.skinned_vertex(i, matrices))
			vertices.append([p.x, p.y, p.z])
		skin_checks[state.handedness] = {"vertices": vertices, "triangles": Array(state.model.triangles)}
		var other := right if controller == left else left
		knife.grab("right" if controller == left else "left", other)
		check(knife.held_by == state.handedness, "other hand cannot steal a held knife")
		controller.position += Vector3(0.02, 0.01, 0)
		knife._process(0.02)
		controller.floats.grip = 0.2
		interactions.update(0.02)
		check(knife.held_by == "" and not knife.freeze and state.hold == null, "%s grip release drops knife and clears finger pose" % state.handedness)
		check(knife.linear_velocity.length() > 0.0 and knife.linear_velocity.length() <= KitchenKnife.THROW_LIMIT, "release preserves bounded throw velocity")
		controller.floats.grip = 0.0
		interactions.update(0.02)
	# Losing tracking cannot leave a knife permanently stuck in an invisible hand.
	knife.position = left.position
	left.floats.grip = 0.9
	interactions.update(0.1)
	left.tracked = false
	interactions.update(0.1)
	check(knife.held_by == "" and not knife.freeze, "tracking loss releases held knife")
	# Exercise the actual game wiring, including a stable physical resting position on its table.
	var room := KillRoom.new()
	root.add_child(room)
	check(room.knife is KitchenKnife and room.props.is_ancestor_of(room.knife), "the game room spawns the knife as a live physics prop")
	for i in 90:
		await physics_frame
	check(room.knife.global_position.y > KillRoom.TABLE_TOP and room.knife.global_position.y < KillRoom.TABLE_TOP + 0.05, "knife rests on table without falling through it (y=%.4f)" % room.knife.global_position.y)
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		var f := FileAccess.open(args[0], FileAccess.WRITE)
		f.store_string(JSON.stringify(skin_checks))
	print("Knife: %d checks, %d failures" % [checks, failures])
	room.free()
	knife.free()
	for s in hands.states:
		s.anchor.free()
	left.free()
	right.free()
	quit(0 if failures == 0 else 1)
