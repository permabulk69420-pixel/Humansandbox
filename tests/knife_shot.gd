# In-game screenshots of the shelf prop and both fitted grips.
# godot --xr-mode off --audio-driver Dummy --path . -s res://tests/knife_shot.gd -- /tmp
extends SceneTree
var out_dir := "/tmp"
class Controller extends Node3D:
	func get_float(action: String) -> float:
		return 0.95 if action == "grip" else 0.0
	func get_has_tracking_data() -> bool:
		return true
func _init() -> void:
	run.call_deferred()
func run() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		out_dir = args[0]
	root.size = Vector2i(1280, 900)
	var game: Node3D = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(game)
	await process_frame
	game.set_process(false)
	var room: KillRoom = game.room
	room.set_process(false)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.current = true
	camera.near = 0.01
	camera.fov = 42.0
	# First show the supplied knife resting in the actual game room.
	for i in 60:
		await physics_frame
	camera.position = Vector3(2.85, 1.05, -4.90)
	camera.look_at(room.knife.global_position + Vector3(0, 0, -.07))
	await snap("knife_on_shelf")
	var collision := room.knife.get_child(1) as CollisionShape3D
	var lowest := 100.0
	for p in (collision.shape as ConvexPolygonShape3D).points:
		lowest = minf(lowest, collision.to_global(p).y)
	print("Resting origin ", room.knife.global_position, " lowest collision point ", lowest)
	for side in ["right", "left"]:
		var controller := Controller.new()
		root.add_child(controller)
		controller.position = room.knife.global_position
		var hands := VrHands.new({side: controller})
		var pickup := HandInteractions.new(hands, null, null, room.knife)
		pickup.update(0.1)
		assert(room.knife.held_by == side)
		controller.position = Vector3(.48 if side == "right" else -.15, 1.30, -2.75)
		room.knife._process(.15)
		hands.update(.15)
		var focus := room.knife.global_position + Vector3(0, .025, -.09)
		camera.position = focus + Vector3(-.40 if side == "right" else .40, .24, .53)
		camera.look_at(focus)
		await snap("knife_" + side + "_grip")
		room.knife.release()
		for state in hands.states:
			state.anchor.free()
		controller.free()
	quit()
func snap(file: String) -> void:
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out_dir + "/" + file + ".png")
	print("PHOTO ", file)
