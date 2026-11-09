# The club upstairs and the stairwell that loads it: what can be seen from where, the floor you walk on, and building it on a worker
# thread as you go up the stairs. No headset needed.
#   godot --headless --path . -s res://tests/club_logic.gd
extends SceneTree

const Main := preload("res://scripts/main.gd")

var failures := 0


func check(ok: bool, what: String) -> void:
	print("  %s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		failures += 1


func _init() -> void:
	run.call_deferred()


func run() -> void:
	await process_frame
	test_visibility()
	test_level_cells()
	await test_club()
	await test_stairwell_loads_the_club()
	print("\n%s" % ("all club checks pass" if failures == 0 else "%d checks FAILED" % failures))
	quit(0 if failures == 0 else 1)


func sees(pvs: Dictionary, from: String, to: String) -> bool:
	return (pvs[from] as Array).has(to)


func test_visibility() -> void:
	print("what can be seen from where")
	var pvs := Club.visibility(Club.ZONES, Club.DOORWAYS)
	var symmetric := true
	var neighbours := true
	var itself := true
	for a in pvs:
		itself = itself and sees(pvs, a, a)
		for b in pvs[a]:
			symmetric = symmetric and sees(pvs, b, a)
	check(itself, "every zone sees itself")
	for d in Club.DOORWAYS:
		neighbours = neighbours and sees(pvs, d[0], d[1]) and sees(pvs, d[1], d[0])
	check(symmetric, "seeing runs both ways")
	check(neighbours, "every zone sees the zones through its own doorways")
	check(sees(pvs, "stairs", "foyer") and not sees(pvs, "stairs", "bar"), "from the top of the stairs: the foyer, not the bar")
	check(not sees(pvs, "foyer", "bar"), "the foyer does not see the bar through their shared wall")
	check(sees(pvs, "stage", "dance") and sees(pvs, "bar", "dance") and sees(pvs, "bar", "stage"), "the hall and the bar see each other")
	check(sees(pvs, "entry", "dance") and sees(pvs, "dance", "entry"), "the entrance foyer and the dance floor see each other")
	check(not sees(pvs, "stairs", "entry") and not sees(pvs, "entry", "room1"), "the entrance cannot see the stairs or the first private room")
	check(not sees(pvs, "lounge", "vip") and not sees(pvs, "lounge", "room1"), "the lounge sees neither the VIP corridor nor the private rooms")
	check(not sees(pvs, "room1", "lounge") and not sees(pvs, "room1", "room2"), "a private room sees no other private room, nor the lounge")


func test_level_cells() -> void:
	print("basement, stairs, club")
	var cz := (KillRoom.HALL_ZN + KillRoom.HALL_ZS) * 0.5
	var north := KillRoom.HALL_ZN + 0.5
	var south := KillRoom.HALL_ZS - 0.5
	check(Main.level_cell(Vector3(0, 1.6, -2), 0.0) == "basement", "the room is the basement")
	check(Main.level_cell(Vector3(KillRoom.HALL_X1 - 1.0, 1.6, cz), 0.0) == "basement", "so is the hallway")
	check(Main.level_cell(Vector3(KillRoom.HALL_X1 + 0.6, 1.6, cz), 0.0) == "lower", "behind the bottom door: the lower stairs")
	check(Main.level_cell(Vector3(KillRoom.STAIR_X0 + 1.0, 2.2, north), 0.6) == "lower", "the first flight: lower")
	check(Main.level_cell(Vector3(KillRoom.STAIR_LANDING_X0 + 0.5, 3.4, cz), 1.8) == "landing", "halfway up: the landing")
	check(Main.level_cell(Vector3(KillRoom.STAIR_X0 + 2.5, 3.6, south), 2.0) == "upper", "the foot of the second flight: upper")
	check(Main.level_cell(Vector3(KillRoom.HALL_X1 + 0.6, 5.2, cz), KillRoom.STAIR_RISE) == "upper", "the top landing: upper")
	check(Main.level_cell(Vector3(10.0, 5.2, -8.0), KillRoom.STAIR_RISE) == "club", "through the top door: the club")


func test_club() -> void:
	print("the club")
	var club := Club.new()
	var task := WorkerThreadPool.add_task(club.build, true, "build the club (test)")
	WorkerThreadPool.wait_for_task_completion(task)
	check(club.built, "builds on a worker thread")
	root.add_child(club)
	await physics_frame
	await physics_frame
	for zone in Club.ZONES:
		if zone == "stairs":
			continue
		var node := club.zone_node(zone)
		check(node != null and node.find_children("*", "MeshInstance3D", true, false).size() > 0, "%s has meshes" % zone)
	check(club.zone_at(Vector3(10.0, 5.0, -8.0)) == "foyer" and club.zone_at(Vector3(1.5, 5.0, 0.0)) == "dance" and club.zone_at(Vector3(-10.0, 5.0, -4.4)) == "vip", "knows which room a point is in")
	club.view_from("room1")
	check(club.zone_node("room1").visible and club.zone_node("vip").visible and not club.zone_node("lounge").visible and not club.zone_node("room2").visible, "in a private room, the lounge and the other rooms are hidden")
	club.view_from("stage")
	check(club.zone_node("bar").visible and club.zone_node("dance").visible, "in the hall, the bar and the dance floor are shown")
	# the floor you stand on, the stage you can climb onto, the walls you cannot walk through
	var space := club.get_world_3d().direct_space_state
	var floor_hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(1.5, Club.FLOOR_Y + 0.45, 0.0), Vector3(1.5, Club.FLOOR_Y - 0.8, 0.0), KillRoom.WALKABLE))
	check(not floor_hit.is_empty() and absf(floor_hit.position.y - Club.FLOOR_Y) < 0.01, "the dance floor is walkable at the top of the stairs (y=%.2f)" % (floor_hit.position.y if not floor_hit.is_empty() else -1.0))
	var stage_hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(1.5, Club.FLOOR_Y + 1.0, -9.0), Vector3(1.5, Club.FLOOR_Y - 0.5, -9.0), KillRoom.WALKABLE))
	check(not stage_hit.is_empty() and absf(stage_hit.position.y - (Club.FLOOR_Y + Club.STAGE_H)) < 0.01, "the stage top is walkable")
	var step_hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(-2.2, Club.FLOOR_Y + 0.45, -9.3), Vector3(-2.2, Club.FLOOR_Y - 0.5, -9.3), KillRoom.WALKABLE))
	check(not step_hit.is_empty() and step_hit.position.y > Club.FLOOR_Y + 0.1 and step_hit.position.y < Club.FLOOR_Y + 0.2, "the first step up to it is within a stride")
	var wall_hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(10.0, Club.FLOOR_Y + 1.0, -6.5), Vector3(10.0, Club.FLOOR_Y + 1.0, -4.5), 1))
	check(not wall_hit.is_empty(), "the wall between the foyer and the bar is solid")
	var door_hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(9.0, Club.FLOOR_Y + 1.0, -6.7), Vector3(7.0, Club.FLOOR_Y + 1.0, -6.7), 1))
	check(door_hit.is_empty(), "the doorway from the foyer into the hall is open")
	# the entrance: an open doorway into the hall, a closed door to the outside, a floor to stand on
	var through := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(6.9, Club.FLOOR_Y + 1.0, 2.0), Vector3(6.9, Club.FLOOR_Y + 1.0, 5.0), 1))
	check(through.is_empty(), "the doorway from the hall into the entrance foyer is open")
	var outside := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(6.05, Club.FLOOR_Y + 1.0, 5.0), Vector3(6.05, Club.FLOOR_Y + 1.0, 7.0), 1))
	check(not outside.is_empty() and outside.position.z < Club.ENTRY_Z1 + 0.01, "the door to the outside is shut (z=%.2f)" % (outside.position.z if not outside.is_empty() else -1.0))
	var entry_floor := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(6.5, Club.FLOOR_Y + 0.45, 5.0), Vector3(6.5, Club.FLOOR_Y - 0.8, 5.0), KillRoom.WALKABLE))
	check(not entry_floor.is_empty() and absf(entry_floor.position.y - Club.FLOOR_Y) < 0.01, "the entrance foyer has a floor")
	check(club.zone_at(Vector3(6.5, 5.0, 5.0)) == "entry", "knows the entrance foyer")
	check(Main.ROOM_MAX.y >= Club.ENTRY_Z1 - 0.31, "the movement backstop reaches the entrance")
	var foyer_signs := club.zone_node("foyer").find_children("*", "Label3D", true, false)
	var entry_signs := club.zone_node("entry").find_children("*", "Label3D", true, false)
	check(foyer_signs.is_empty(), "the room at the top of the stairs has no admission sign")
	check(entry_signs.size() == 1 and (entry_signs[0] as Label3D).text == "ADMISSION", "the admission sign is in the entrance foyer")
	# the seating: all the stools (or booths) in a room are one MultiMesh, on one material
	var seats := {"bar": ["club_stool", 9], "stage": ["club_stool", 11], "dance": ["club_stool", 4], "lounge": ["club_booth", 3]}
	for zone in seats:
		var multi := club.zone_node(zone).find_child(seats[zone][0], false, false) as MultiMeshInstance3D
		check(multi != null and multi.multimesh.instance_count == seats[zone][1] and multi.multimesh.mesh.get_surface_count() == 1 and multi.material_override != null,
			"%s: %d %ss in one draw call" % [zone, seats[zone][1], seats[zone][0]])
		check(club.zone_node(zone).find_child("Leather", false, false) == null, "%s: no separate leather mesh" % zone)
	var layers_ok := true
	for zone in Club.ZONES:
		layers_ok = layers_ok and (Club.zone_layer(zone) & Club.LAYERS) == Club.zone_layer(zone) or zone == "stairs"
	check(layers_ok, "every zone's render layer is one the stairwell's lamps leave alone")
	club.free()


func test_stairwell_loads_the_club() -> void:
	print("the stairwell is the loading screen")
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	var room: KillRoom = main.room
	check(room.stair_door_top.locked, "the top door is locked while there is no club")
	main.update_levels()
	check(main.club == null, "nothing is built while you are in the basement")
	# into the vestibule behind the bottom door
	var rig: Node3D = main.rig
	rig.global_position = Vector3(KillRoom.HALL_X1 + 0.6, 0.0, (KillRoom.HALL_ZN + KillRoom.HALL_ZS) * 0.5)
	for i in 600:
		main.update_levels()
		if main.club != null:
			break
		await process_frame
	check(main.club != null and main.club.is_inside_tree(), "stepping into the stairwell builds the club")
	check(not room.stair_door_top.locked, "and unlocks the top door")
	check(not main.club.visible and main.woman.visible, "on the lower stairs: the basement, not the club")
	# up to the top landing
	rig.global_position = Vector3(KillRoom.HALL_X1 + 0.6, KillRoom.STAIR_RISE, (KillRoom.HALL_ZN + KillRoom.HALL_ZS) * 0.5)
	main.update_levels()
	check(main.club.visible and not main.woman.visible and main.woman.process_mode == Node.PROCESS_MODE_DISABLED, "at the top: the club, and she is hidden and paused")
	check(room.stair_door_top.visible and room.stair_door_bottom.visible, "the stairwell's doors stay")
	var room_meshes := 0
	for c in room.get_children():
		if c is MeshInstance3D and not room.stairwell.has(c) and (c as MeshInstance3D).visible:
			room_meshes += 1
	check(room_meshes == 0, "the basement's meshes are hidden (%d shown)" % room_meshes)
	check(room.world_env.environment == main.club.environment, "the club's fog and light")
	# into the club
	rig.global_position = Vector3(10.0, KillRoom.STAIR_RISE, -8.0)
	main.update_levels()
	check(main.level == "club" and main.club.current_zone == "foyer", "in the foyer")
	# and back down
	rig.global_position = Vector3(0.0, 0.0, -2.0)
	main.update_levels()
	check(not main.club.visible and main.woman.visible and main.woman.process_mode != Node.PROCESS_MODE_DISABLED, "back in the basement: she is back, the club is hidden")
	check(room.world_env.environment == room.basement_environment, "and the basement's own fog and light")
	main.queue_free()
	await process_frame
