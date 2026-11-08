# Walking: her walk, turning and wandering, and the player's own movement. No headset needed.
#   godot --headless --path . -s res://tests/walk_logic.gd
extends SceneTree

var failures := 0


# Stands in for an XRController3D.
class FakeController extends Node3D:
	func get_float(_action: String) -> float:
		return 0.0

	func get_has_tracking_data() -> bool:
		return true


func check(ok: bool, what: String) -> void:
	print("  %s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		failures += 1


func _init() -> void:
	run.call_deferred()


func run() -> void:
	await process_frame
	test_clips()
	test_standing_still()
	test_walk_to()
	test_feet()
	test_turn_to_face()
	test_wander()
	test_hit_while_walking()
	test_knockdown()
	test_detector_ignores_your_own_movement()
	await test_player_movement()
	print("\n%s" % ("all walking checks pass" if failures == 0 else "%d checks FAILED" % failures))
	quit(0 if failures == 0 else 1)


func make_woman(player_at: Vector3 = Vector3(0, 1.62, 3.0)) -> Woman:
	var w := Woman.new()
	root.add_child(w)
	var t := Node3D.new()
	root.add_child(t)
	t.global_position = player_at
	w.target = t
	w.pause_timer = 0.0
	return w


func step(w: Woman, seconds: float) -> void:
	for i in int(seconds * 72.0):
		w.update(1.0 / 72.0)


func ankle(w: Woman, side: String) -> Vector3:
	return w.skeleton.global_transform * w.skeleton.get_bone_global_pose(w.bone[side + "Foot"]).origin


func test_clips() -> void:
	print("clips")
	var w := make_woman()
	check(w.clips.has("Idle_Loop") and w.clips.has("Walk_Loop"), "idle and walk clips are loaded")
	check(w.walk_speed > 0.5 and w.walk_speed < 1.2, "walk clip's ground speed is a stroll (%.2f m/s)" % w.walk_speed)
	check(w.clip_bones.size() == 22, "22 bones animated (%d)" % w.clip_bones.size())
	w.queue_free()


func test_standing_still() -> void:
	print("standing")
	var w := make_woman()
	var start := w.global_position
	step(w, 5.0)
	check(w.global_position.distance_to(start) < 0.01, "she stays where she is put when she has nothing to do")
	check(w.clip_name == "Idle_Loop", "and idles")
	w.queue_free()


func test_walk_to() -> void:
	print("walking to a point")
	var w := make_woman()
	w.walk_to(Vector3(2.0, 0, 0))
	var top_speed := 0.0
	var turned_first := false
	var off_line := 0.0
	for i in int(7.0 * 72):
		w.update(1.0 / 72.0)
		top_speed = maxf(top_speed, w.speed)
		if w.speed < 0.05 and absf(w.turn_velocity) > 0.3 and w.clip_name == "Walk_Loop":
			turned_first = true
		off_line = maxf(off_line, absf(w.global_position.z))
	check(w.global_position.distance_to(Vector3(2.0, 0, 0)) < 0.15, "gets there (%.2f m short)" % w.global_position.distance_to(Vector3(2.0, 0, 0)))
	check(top_speed <= w.walk_speed + 0.02 and top_speed > w.walk_speed * 0.9, "at her walking pace (%.2f m/s)" % top_speed)
	check(turned_first, "turning on the spot first, then setting off")
	check(off_line < 0.35, "and in a straight line (%.2f m off)" % off_line)
	check(w.clip_name == "Idle_Loop" and w.speed < 0.01, "then stands and idles")
	w.queue_free()


# Feet on the floor: while a foot is down it should hardly move over the ground, and no foot should sink through the floor.
func test_feet() -> void:
	print("feet")
	var w := make_woman()
	w.walk_to(Vector3(6.0, 0, 0))
	step(w, 3.5)   # turned, accelerated, at full pace
	check(w.speed > w.walk_speed * 0.98, "at a steady pace (%.2f m/s)" % w.speed)
	var dt := 1.0 / 72.0
	var low := 10.0
	var high := 0.0
	var slide := {"Left": [], "Right": []}
	var heights := {"Left": [], "Right": []}
	var positions := {"Left": [], "Right": []}
	for i in int(2.4 * 72):
		w.update(dt)
		for side in ["Left", "Right"]:
			var p := ankle(w, side)
			positions[side].append(p)
			heights[side].append(p.y)
			low = minf(low, p.y)
			high = maxf(high, p.y)
	for side in ["Left", "Right"]:
		var floor_y: float = heights[side].min()
		var total := 0.0
		var count := 0
		for i in range(1, positions[side].size()):
			if heights[side][i] < floor_y + 0.02:
				var d: Vector3 = positions[side][i] - positions[side][i - 1]
				d.y = 0.0
				total += d.length() / dt
				count += 1
		var avg := total / maxf(1.0, float(count))
		check(count > 10 and avg < 0.25, "%s foot barely skates while it is down (%.2f m/s over %d frames, walking at %.2f)" % [side, avg, count, w.speed])
	check(low > 0.03, "her ankles never sink into the floor (lowest %.3f m)" % low)
	check(high < 0.45, "or fly off it (highest %.3f m)" % high)
	w.queue_free()


func test_turn_to_face() -> void:
	print("turning to face the player")
	var w := make_woman(Vector3(1.5, 1.62, 0.0))   # off to her side
	step(w, 0.3)
	check(w.clip_name == "Walk_Loop" and absf(w.turn_velocity) > 0.5, "she steps round")
	step(w, 3.0)
	var want := rad_to_deg(atan2(1.5, 0.0))
	check(absf(rad_to_deg(w.rotation.y) - want) < 15.0, "until she faces them (%.0f deg, wanted %.0f)" % [rad_to_deg(w.rotation.y), want])
	check(w.global_position.length() < 0.15, "without wandering off (%.2f m)" % w.global_position.length())
	check(w.clip_name == "Idle_Loop", "then settles into her idle")
	# the player stays close to her front: she does not fidget round to face them
	var yaw := w.rotation.y
	w.target.global_position = Vector3(1.5, 1.62, 0.4)
	step(w, 2.0)
	check(absf(rad_to_deg(wrapf(w.rotation.y - yaw, -PI, PI))) < 2.0, "she does not shuffle for a small change")
	w.queue_free()


func test_wander() -> void:
	print("wandering")
	var w := make_woman(Vector3(0, 1.62, 1.1))   # the player is standing in front of her
	w.wander = true
	var farthest := 0.0
	var nearest_to_player := 10.0
	var walked := 0.0
	var last := w.global_position
	for i in int(70.0 * 72):
		w.update(1.0 / 72.0)
		farthest = maxf(farthest, w.global_position.distance_to(w.home))
		nearest_to_player = minf(nearest_to_player, Vector2(w.global_position.x, w.global_position.z).distance_to(Vector2(0, 1.1)))
		walked += w.global_position.distance_to(last)
		last = w.global_position
	check(walked > 2.0, "she wanders about (%.1f m walked in 70 s)" % walked)
	check(farthest < Woman.WANDER_RADIUS + 0.3, "but not far from her spot (%.2f m)" % farthest)
	check(nearest_to_player > 0.7, "and never walks into the player (closest %.2f m)" % nearest_to_player)
	w.queue_free()


func test_hit_while_walking() -> void:
	print("hit while walking")
	var w := make_woman()
	w.walk_to(Vector3(6.0, 0, 0))
	step(w, 4.0)
	check(w.speed > 0.6, "walking (%.2f m/s)" % w.speed)
	w.hit(w.head_center() + Vector3(0, 0, 0.1), Vector3(0, 0, -4.0), 1.0)
	check(w.move_target == null, "a punch ends her walk")
	step(w, 1.5)
	check(w.speed < 0.02, "and she stops (%.2f m/s)" % w.speed)
	step(w, 1.0)
	check(w.move_target == null, "and she does not set straight off again")
	w.queue_free()


func test_knockdown() -> void:
	print("being knocked down")
	var w := make_woman()
	step(w, 0.5)
	for i in 10:
		w.hit(w.head_center() + Vector3(0, 0, 0.1), Vector3(0, 0, -2.0), 0.3)
		step(w, 1.5)
	check(w.knockdowns == 0 and w.fall_state == Woman.Fall.STANDING, "light taps never knock her down (%d of them)" % w.hits)
	w.queue_free()

	w = make_woman()
	step(w, 0.5)
	w.hit(w.head_center() + Vector3(0, 0, 0.1), Vector3(0, 0, -4.0), 0.75)
	step(w, 3.0)
	check(w.knockdowns == 0, "one decent punch on its own does not")
	w.hit(w.head_center() + Vector3(0, 0, 0.1), Vector3(0, 0, -4.0), 0.75)
	step(w, 0.4)
	w.hit(w.head_center() + Vector3(0, 0, 0.1), Vector3(0, 0, -4.0), 0.75)
	check(w.knockdowns == 1, "but two close together do")
	var weak_lie := w.lie_timer
	w.queue_free()

	w = make_woman()
	step(w, 0.5)
	w.hit(w.head_center() + Vector3(0, 0, 0.1), Vector3(0, 0, -5.0), 1.0)
	check(w.fall_state == Woman.Fall.FALLING and w.knockdowns == 1, "a full-strength punch knocks her down")
	check(w.lie_timer > weak_lie, "and she stays down longer than after softer ones (%.1f s against %.1f s)" % [w.lie_timer, weak_lie])
	var strong_lie := w.lie_timer
	step(w, 2.6)
	var hips: float = (w.skeleton.global_transform * w.skeleton.get_bone_global_pose(w.bone["Hips"]).origin).y
	check(w.fall_state == Woman.Fall.LYING, "she is down")
	check(hips < 0.3 and w.head_center().y < 0.5, "flat on the floor (hips %.2f m, head %.2f m up)" % [hips, w.head_center().y])
	check(w.head_center().z < -0.4, "fallen away from the punch (head %.2f m back)" % -w.head_center().z)
	var count := w.hits
	w.hit(w.head_center(), Vector3(0, 0, -5.0), 1.0)
	check(w.hits == count + 1 and w.knockdowns == 1 and w.fall_state == Woman.Fall.LYING, "hitting her while she is down does not start another fall")
	step(w, strong_lie + 3.6)
	check(w.fall_state == Woman.Fall.STANDING, "then she gets up")
	check(w.head_center().y > 1.4 and w.clip_name == "Idle_Loop" and w.damage == 0.0, "standing, recovered (head %.2f m up)" % w.head_center().y)
	step(w, 6.0)
	w.hit(w.head_center() + Vector3(0, 0, 0.1), Vector3(0, 0, -5.0), 1.0)
	check(w.knockdowns == 2, "and she can be knocked down again")
	w.queue_free()

	# she goes down the way the punch was travelling, from the side too
	w = make_woman()
	step(w, 0.5)
	w.hit(w.head_center() + Vector3(0.1, 0, 0), Vector3(-5.0, 0, 0), 1.0)
	step(w, 2.6)
	check(w.fall_state == Woman.Fall.LYING and w.head_center().x < -0.4 and w.head_center().y < 0.5, "a punch from the side puts her down sideways (head %.2f m across)" % w.head_center().x)
	w.queue_free()

	# and a walker stops
	w = make_woman()
	w.walk_to(Vector3(6.0, 0, 0))
	step(w, 4.0)
	w.hit(w.head_center() + Vector3(0, 0, 0.1), Vector3(0, 0, -5.0), 1.0)
	step(w, 1.0)
	check(w.speed < 0.02 and w.knockdowns == 1, "a walking woman is stopped in her tracks and goes down")
	w.queue_free()


# Walking into her with your hand in front of you is not a punch; swinging your fist while you walk is.
func test_detector_ignores_your_own_movement() -> void:
	print("punching while walking")
	var w := make_woman(Vector3(0, 1.62, 3.0))
	step(w, 0.5)
	var rig := Node3D.new()
	root.add_child(rig)
	var hand := FakeController.new()
	rig.add_child(hand)
	var centre := w.head_center()
	var with_reference := PunchDetector.new()
	with_reference.reference = rig
	with_reference.add_hand("right", hand)
	var without := PunchDetector.new()
	without.add_hand("right", hand)
	var landed := {"with": 0, "without": 0}
	with_reference.punched.connect(func(_h, _p, _v, _s): landed.with += 1)
	without.punched.connect(func(_h, _p, _v, _s): landed.without += 1)
	rig.global_position = centre + Vector3(0, 0, 0.9)
	hand.position = Vector3.ZERO
	var dt := 1.0 / 72.0
	with_reference.update(dt, w)
	without.update(dt, w)
	for i in 40:   # the whole play space walks at her head at 3 m/s with the hand held still in it
		rig.global_position += Vector3(0, 0, -3.0 * dt)
		with_reference.update(dt, w)
		without.update(dt, w)
	check(landed.without >= 1, "(without the play-space reference a walking hand looks like a punch)")
	check(landed.with == 0, "with it, walking at her is not a punch")
	# now throw the fist inside the moving play space
	rig.global_position = centre + Vector3(0, 0, 1.0)
	hand.position = Vector3.ZERO
	with_reference.update(dt, w)
	landed.with = 0
	for i in 40:
		rig.global_position += Vector3(0, 0, -1.0 * dt)
		hand.position += Vector3(0, 0, -3.0 * dt)
		with_reference.update(dt, w)
	check(landed.with == 1, "but a real swing while walking still lands (%d)" % landed.with)
	rig.queue_free()
	w.queue_free()


func test_player_movement() -> void:
	print("player movement")
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	main.woman.wander = false
	main.woman.global_position = Vector3(8, 0, 8)     # out of the way
	var rig: Node3D = main.rig
	var cam: Camera3D = main.camera
	var start := cam.global_position
	main.locomote(Vector2(0, 1), 0.0, 1.0)
	check(absf((cam.global_position - start).z + Main_speed(main)) < 0.01 and absf((cam.global_position - start).x) < 0.01, "forward walks along where you look (%.2f m in 1 s)" % (start - cam.global_position).z)
	main.locomote(Vector2(1, 0), 0.0, 1.0)
	check(absf((cam.global_position - start).x - Main_speed(main)) < 0.01, "strafing goes sideways")
	# turning pivots on your head
	var before := cam.global_position
	main.locomote(Vector2.ZERO, 1.0, 0.5)
	check(cam.global_position.distance_to(before) < 0.001, "turning does not move your head")
	check(absf(rad_to_deg(rig.rotation.y) - -rad_to_deg(main.TURN_SPEED) * 0.5) < 0.5, "turning right by %.0f deg" % (-rad_to_deg(rig.rotation.y)))
	# ...and walking follows the new heading
	rig.rotation.y = deg_to_rad(-90.0)
	before = cam.global_position
	main.locomote(Vector2(0, 1), 0.0, 1.0)
	var moved: Vector3 = cam.global_position - before
	check(moved.x > Main_speed(main) * 0.99 and absf(moved.z) < 0.01, "forward follows the turn (%s)" % str(moved.snapped(Vector3.ONE * 0.01)))
	# a head at a tilt still walks level
	cam.rotation_degrees = Vector3(-40, 0, 0)
	before = cam.global_position
	main.locomote(Vector2(0, 1), 0.0, 0.5)
	check(absf((cam.global_position - before).y) < 0.001, "looking up or down does not lift you off the floor")
	cam.rotation = Vector3.ZERO
	# dead zone
	check(main.stick_value(Vector2(0.1, 0.1)) == Vector2.ZERO, "a resting thumbstick does nothing")
	check(main.stick_value(Vector2(1, 0)).is_equal_approx(Vector2(1, 0)), "a full push is a full push")
	check(main.stick_value(Vector2(0.6, 0)).x > 0.0 and main.stick_value(Vector2(0.6, 0)).x < 0.6, "and it eases in past the dead zone")
	# you cannot walk through her
	main.woman.global_position = cam.global_position + Vector3(0.0, 0.0, 0.0) + (-cam.global_basis.z).normalized() * 1.0
	main.woman.global_position.y = 0.0
	for i in 120:
		main.locomote(Vector2(0, 1), 0.0, 1.0 / 60.0)
	var gap := Vector2(cam.global_position.x - main.woman.global_position.x, cam.global_position.z - main.woman.global_position.z).length()
	check(gap > main.PERSONAL_SPACE - 0.02, "walking at her stops you at arm's length (%.2f m)" % gap)
	# the edge of the floor
	main.woman.global_position = Vector3(-8, 0, -8)
	rig.rotation.y = deg_to_rad(-90.0)
	for i in 60 * 20:
		main.locomote(Vector2(0, 1), 0.0, 1.0 / 60.0)
	check(rig.global_position.x <= main.ARENA + 0.01, "and you stop at the edge of the floor (%.1f m)" % rig.global_position.x)
	main.queue_free()


func Main_speed(main) -> float:
	return main.MOVE_SPEED
