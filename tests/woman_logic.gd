# The woman, her gaze, and getting punched, tested without a headset: the real rigged model, stand-in controllers.
#   godot --headless --path . -s res://tests/woman_logic.gd
extends SceneTree

var failures := 0


# Stands in for an XRController3D.
class FakeController extends Node3D:
	var floats := {}
	var buzzes := []

	func get_float(action: String) -> float:
		return floats.get(action, 0.0)

	func get_has_tracking_data() -> bool:
		return true

	func trigger_haptic_pulse(_action: String, _frequency: float, amplitude: float, duration: float, _delay: float) -> void:
		buzzes.append([amplitude, duration])


func check(ok: bool, what: String) -> void:
	print("  %s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		failures += 1


func _init() -> void:
	run.call_deferred()


func run() -> void:
	await process_frame
	test_rig()
	test_look()
	test_look_limits()
	test_hit_front()
	test_hit_side()
	test_hit_cap()
	test_detector()
	test_hands()
	await test_main_scene()
	print("\n%s" % ("all woman checks pass" if failures == 0 else "%d checks FAILED" % failures))
	quit(0 if failures == 0 else 1)


func make_woman(target_at: Vector3 = Vector3(0, 1.62, 1.0)) -> Woman:
	var w := Woman.new()
	root.add_child(w)
	var t := Node3D.new()
	root.add_child(t)
	t.global_position = target_at
	w.target = t
	return w


func step(w: Woman, seconds: float, dt: float = 1.0 / 72.0) -> void:
	for i in int(seconds / dt):
		w.update(dt)


func yaw_of(v: Vector3) -> float:
	return rad_to_deg(atan2(v.x, v.z))


func angle_between(a: Vector3, b: Vector3) -> float:
	return rad_to_deg(a.normalized().angle_to(b.normalized()))


func test_rig() -> void:
	print("rig")
	var w := make_woman()
	var sk := w.skeleton
	check(sk != null and sk.get_bone_count() == 24, "24-bone skeleton (%d)" % (sk.get_bone_count() if sk else -1))
	for b in ["Hips", "Spine", "Chest", "UpperChest", "Neck", "Head", "LeftEye", "RightEye", "LeftUpperArm", "RightUpperArm",
			"LeftLowerArm", "LeftHand", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "LeftToes"]:
		check(sk.find_bone(b) >= 0, "bone %s" % b)
	var meshes := sk.find_children("*", "MeshInstance3D", false, false)
	check(meshes.size() == 8, "8 skinned meshes (%d)" % meshes.size())
	var all_skinned := true
	for m: MeshInstance3D in meshes:
		all_skinned = all_skinned and m.skin != null
	check(all_skinned, "every mesh is skinned to the skeleton")
	check(angle_between(w.head_forward(), Vector3.BACK) < 6.0, "faces +Z at rest (target straight ahead)")
	var top := w.head_center().y + Woman.HEAD_RADIUS
	check(top > 1.55 and top < 1.75, "head is at human height (%.2f m)" % top)
	w.queue_free()


func test_look() -> void:
	print("look")
	var target := Vector3(0.8, 1.6, 1.0)
	var w := make_woman(target)
	step(w, 2.5)
	var expected_yaw := rad_to_deg(atan2(target.x - 0.0, target.z - 0.113))
	var head_yaw := yaw_of(w.head_forward())
	check(absf(head_yaw - expected_yaw) < 5.0, "head turns to the target: %.1f deg (wanted %.1f)" % [head_yaw, expected_yaw])
	for side in ["Left", "Right"]:
		var to_target: Vector3 = target - w.eye_position(side)
		var off := angle_between(w.eye_forward(side), to_target)
		check(off < 4.0, "%s eye is on the target (%.1f deg off)" % [side, off])
	# the eyes lead the head: right after the target jumps, the eyes are already closer to it than the head is
	w.target.global_position = Vector3(-0.9, 1.6, 0.8)
	step(w, 0.15)
	var new_yaw := rad_to_deg(atan2(-0.9, 0.8 - 0.113))
	var head_error := absf(yaw_of(w.head_forward()) - new_yaw)
	var eye_error := absf(yaw_of(w.eye_forward("Left")) - new_yaw)
	check(eye_error < head_error, "eyes get there before the head (eye %.0f deg off, head %.0f deg off)" % [eye_error, head_error])
	step(w, 2.0)
	check(absf(yaw_of(w.head_forward()) - new_yaw) < 5.0, "and the head follows")
	# up close the eyes converge: they look at the same point, so they point slightly towards each other
	w.target.global_position = Vector3(0, 1.5, 0.45)
	step(w, 2.0)
	var spread := angle_between(w.eye_forward("Left"), w.eye_forward("Right"))
	check(spread > 4.0 and spread < 20.0, "eyes converge on something close (%.1f deg between them)" % spread)
	w.queue_free()


func test_look_limits() -> void:
	print("look limits")
	var w := make_woman(Vector3(0, 1.6, -2.0))   # behind her
	w.body_turns = false                          # (left to herself she would turn right round: this checks the neck on its own)
	step(w, 3.0)
	var head_yaw := absf(yaw_of(w.head_forward()))
	check(head_yaw < 70.0 and head_yaw > 55.0, "head stops at its limit when the player is behind her (%.0f deg)" % head_yaw)
	for side in ["Left", "Right"]:
		var off := angle_between(w.eye_forward(side), w.head_forward())
		check(off <= 39.5, "%s eye stays within its range of the head (%.0f deg)" % [side, off])
	w.target.global_position = Vector3(0, 4.0, 0.3)   # far above
	step(w, 3.0)
	var pitch := rad_to_deg(asin(clampf(w.head_forward().y, -1.0, 1.0)))
	check(pitch > 15.0 and pitch < 36.0, "looking up is limited (%.0f deg)" % pitch)
	w.queue_free()


func test_hit_front() -> void:
	print("hit from the front")
	var w := make_woman()
	step(w, 2.0)
	var before := w.head_forward()
	check(w.look_weight > 0.99, "watching the player before the hit")
	w.hit(w.head_center() + Vector3(0, -0.02, 0.10), Vector3(0, 0, -4.0), 0.6)
	check(w.hits == 1, "hit counted")
	var peak := 0.0
	var snap_back := 0.0
	var weight_low := 1.0
	for i in int(2.0 * 72):
		w.update(1.0 / 72.0)
		peak = maxf(peak, angle_between(w.head_forward(), before))
		snap_back = maxf(snap_back, -w.hit_angle.x)   # a turn about X the negative way is the head going back and up
		weight_low = minf(weight_low, w.look_weight)
	check(peak > 10.0 and peak < 50.0, "head rocks %.0f deg" % peak)
	check(snap_back > 0.2, "a punch to the face snaps the head back (%.0f deg)" % rad_to_deg(snap_back))
	check(weight_low < 0.1, "she loses track of the player for a moment")
	step(w, 2.0)
	check(angle_between(w.head_forward(), before) < 4.0, "head settles back (%.1f deg off)" % angle_between(w.head_forward(), before))
	check(w.look_weight > 0.99, "and she is watching the player again")
	check(w.hit_angle.length() < 0.01, "reaction spring at rest")
	w.queue_free()


func test_hit_side() -> void:
	print("hit from the side")
	for sign in [1.0, -1.0]:
		var w := make_woman()
		step(w, 2.0)
		var before := yaw_of(w.head_forward())
		# a hook from her left (+X) travelling towards her right (-X) if sign > 0; mirrored otherwise
		w.hit(w.head_center() + Vector3(0.10 * sign, 0, 0.03), Vector3(-4.0 * sign, 0, 0), 0.6)
		var extreme := 0.0
		for i in int(0.6 * 72):
			w.update(1.0 / 72.0)
			var delta := yaw_of(w.head_forward()) - before
			if absf(delta) > absf(extreme):
				extreme = delta
		check(extreme * sign < -8.0, "head is turned the way the fist pushed it (%.0f deg)" % extreme)
		w.queue_free()


func test_hit_cap() -> void:
	print("a very hard hit")
	var w := make_woman()
	step(w, 1.0)
	for i in 5:
		w.hit(w.head_center() + Vector3(0, 0.05, 0.10), Vector3(0, 0, -30.0), 1.0)
	var worst := 0.0
	for i in int(1.5 * 72):
		w.update(1.0 / 72.0)
		worst = maxf(worst, w.hit_angle.length())
	check(worst <= Woman.MAX_REACTION + 0.001, "reaction never exceeds %.0f deg (peak %.0f)" % [rad_to_deg(Woman.MAX_REACTION), rad_to_deg(worst)])
	step(w, 3.0)
	check(w.hit_angle.length() < 0.01, "still recovers")
	w.queue_free()


func test_detector() -> void:
	print("punch detector")
	var w := make_woman()
	step(w, 0.5)
	var hand := FakeController.new()
	root.add_child(hand)
	# fingers point along the controller's -Z, as in the headset
	var det := PunchDetector.new()
	det.add_hand("right", hand)
	var landed: Array = []
	det.punched.connect(func(hand_name, point, velocity, strength): landed.append([hand_name, point, velocity, strength]))
	var centre := w.head_center()
	var dt := 1.0 / 72.0

	# a proper punch: 0.6 m out, straight at the face at 4 m/s
	hand.global_position = centre + Vector3(0, 0, 0.65)
	hand.global_basis = Basis.IDENTITY   # -Z is towards her
	det.update(dt, w)
	for i in 30:
		hand.global_position += Vector3(0, 0, -4.0 * dt)
		det.update(dt, w)
	check(landed.size() == 1, "a fast punch at the face lands once (%d)" % landed.size())
	if landed.size() > 0:
		check(landed[0][3] > 0.4, "strength reflects speed (%.2f)" % landed[0][3])
		check(landed[0][2].z < -2.0, "hit carries the fist's velocity")
	# the same hand cannot hit again straight away: wind the fist back and throw it again inside the cooldown
	var again := PunchDetector.new()
	again.add_hand("right", hand)
	var again_hits := []
	again.punched.connect(func(_h, _p, _v, _s): again_hits.append(1))
	hand.global_position = centre + Vector3(0, 0, 0.5)
	again.update(dt, w)
	for i in 12:   # a fast jab in and out (4 m/s, 0.17 s) then in again
		hand.global_position += Vector3(0, 0, (-4.0 if i < 6 else 4.0) * dt)
		again.update(dt, w)
	for i in 12:
		hand.global_position += Vector3(0, 0, -4.0 * dt)
		again.update(dt, w)
	check(again_hits.size() <= 1, "cooldown stops a second hit inside %.2f s (%d)" % [PunchDetector.COOLDOWN, again_hits.size()])

	# too slow
	landed.clear()
	var slow := PunchDetector.new()
	slow.add_hand("right", hand)
	slow.punched.connect(func(_h, _p, _v, _s): landed.append(1))
	hand.global_position = centre + Vector3(0, 0, 0.5)
	slow.update(dt, w)
	for i in 120:
		hand.global_position += Vector3(0, 0, -0.5 * dt)
		slow.update(dt, w)
	check(landed.is_empty(), "pushing slowly into her face is not a punch")

	# fast, but past her: misses by 40 cm
	var miss := PunchDetector.new()
	miss.add_hand("right", hand)
	miss.punched.connect(func(_h, _p, _v, _s): landed.append(2))
	hand.global_position = centre + Vector3(0.4, 0, 0.65)
	miss.update(dt, w)
	for i in 30:
		hand.global_position += Vector3(0, 0, -4.0 * dt)
		miss.update(dt, w)
	check(landed.is_empty(), "a swing 40 cm wide misses")

	# fast, with the knuckles already in the head, but pulling away
	var away := PunchDetector.new()
	away.add_hand("right", hand)
	away.punched.connect(func(_h, _p, _v, _s): landed.append(3))
	hand.global_position = centre + Vector3(0, 0, 0.20)   # the knuckles are 7.5 cm further on, inside the head
	away.update(dt, w)
	for i in 10:
		hand.global_position += Vector3(0, 0, 4.0 * dt)
		away.update(dt, w)
	check(landed.is_empty(), "pulling a hand away from her face is not a punch")

	# very fast: a single frame carries the fist right through the head (29 m/s at 72 Hz)
	var tunnel := PunchDetector.new()
	tunnel.add_hand("right", hand)
	tunnel.punched.connect(func(_h, _p, _v, _s): landed.append(4))
	hand.global_position = centre + Vector3(0, 0, 0.4)
	tunnel.update(dt, w)
	for i in 2:   # the first reading is only half believed, so it takes a frame to get up to speed
		hand.global_position += Vector3(0, 0, -0.4)
		tunnel.update(dt, w)
	check(landed.has(4), "a fist that jumps clean through the head in a single frame still counts")

	# a tracking glitch (the hand teleports) is not a punch
	landed.clear()
	var glitch := PunchDetector.new()
	glitch.add_hand("right", hand)
	glitch.punched.connect(func(_h, _p, _v, _s): landed.append(5))
	hand.global_position = centre + Vector3(0, 0, -2.0)
	glitch.update(dt, w)
	hand.global_position = centre + Vector3(0, 0, 3.0)
	glitch.update(dt, w)
	check(landed.is_empty(), "a hand that teleports through her is a tracking glitch, not a punch")
	hand.queue_free()
	w.queue_free()


func test_hands() -> void:
	print("hands")
	var left := FakeController.new()
	var right := FakeController.new()
	root.add_child(left)
	root.add_child(right)
	var hands := VrHands.new({"left": left, "right": right})
	check(hands.states.size() == 2, "a hand on each controller")
	for s in hands.states:
		var mat := s.model.mesh.material_override as StandardMaterial3D
		check(mat != null and mat.albedo_texture != null and mat.normal_texture != null, "%s hand has its skin textures" % s.handedness)
	for c in [left, right]:
		c.floats = {"trigger": 1.0, "grip": 1.0}
	hands.update(0.1)
	check(true, "fists close without errors")
	left.queue_free()
	right.queue_free()


func test_main_scene() -> void:
	print("main scene (flat screen)")
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	check(not main.vr, "runs on a flat screen without a headset")
	check(main.woman != null and main.woman.target == main.camera, "she is watching the camera")
	check(main.woman.global_position.z < -0.5, "she stands in front of the player")
	for i in 72:   # a second for her gaze to settle on the player
		main.woman.update(1.0 / 72.0)
	check(angle_between(main.woman.head_forward(), main.camera.global_position - main.woman.head_center()) < 8.0, "and faces the player")
	var before: int = main.woman.hits
	main.throw_flat_punch()
	check(main.woman.hits == before + 1, "a flat-screen punch lands")
	check(main.thud.stream != null and main.thud.stream.get_length() > 0.1, "with a thud")
	main.queue_free()

	print("placement in front of the player")
	var main_script := load("res://scripts/main.gd")
	var t: Transform3D = main_script.placement(Vector3(1, 1.6, 2), Vector3(0, 0, -1), 0.0, 0.8)
	check(t.origin.is_equal_approx(Vector3(1, 0, 1.2)), "ahead of a player looking down -Z: %s" % t.origin)
	check(t.basis.z.is_equal_approx(Vector3.BACK), "and facing back at them")
	t = main_script.placement(Vector3(0, 1.7, 0), Vector3(1, -0.3, 0), 0.0, 0.8)
	check(t.origin.is_equal_approx(Vector3(0.8, 0, 0)), "ahead of a player looking along +X, on the floor: %s" % t.origin)
	check(t.basis.z.is_equal_approx(Vector3.LEFT), "facing them (-X)")
	t = main_script.placement(Vector3(0, 1.7, 0), Vector3(0, -1, 0), 0.2, 0.8)
	check(t.origin.is_equal_approx(Vector3(0, 0.2, -0.8)), "looking straight down falls back to the play-space heading")
