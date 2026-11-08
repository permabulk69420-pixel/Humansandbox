# Renders the woman to PNGs so the gaze and the punch reaction can be looked at. Software rendering is fine.
#   xvfb-run -a godot --path . --rendering-driver opengl3 --rendering-method gl_compatibility -s res://tests/woman_shot.gd -- <out dir>
extends SceneTree

var out_dir := "/tmp"
var camera: Camera3D
var woman: Woman
var player: Node3D


# Stands in for an XRController3D.
class FakeController extends Node3D:
	var floats := {}
	func get_float(action: String) -> float:
		return floats.get(action, 0.0)
	func get_has_tracking_data() -> bool:
		return true


func _init() -> void:
	run.call_deferred()


func snap(file: String) -> void:
	for i in 3:
		await process_frame
	root.get_texture().get_image().save_png("%s/%s.png" % [out_dir, file])


func aim(from: Vector3, at: Vector3, fov: float = 40.0) -> void:
	camera.fov = fov
	camera.global_position = from
	camera.look_at(at, Vector3.UP)


func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0]
	root.size = Vector2i(900, 900)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("6d8796")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("c9d6dd")
	env.ambient_light_energy = 0.7
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.2
	root.add_child(sun)
	sun.look_at_from_position(Vector3(1, 2.5, 3), Vector3.ZERO)
	camera = Camera3D.new()
	root.add_child(camera)
	camera.current = true

	woman = Woman.new()
	root.add_child(woman)
	player = Node3D.new()
	root.add_child(player)
	player.global_position = Vector3(0, 1.62, 0.85)
	woman.target = player
	await process_frame
	for i in 150:
		woman.update(1.0 / 72.0)

	# 1: standing, watching the player (full body from the front-right, then from the player's own eyes, close on the face)
	aim(Vector3(1.5, 1.1, 2.6), Vector3(0, 0.85, 0), 38.0)
	await snap("1_full_body")
	aim(Vector3(0, 1.62, 0.85), woman.head_center(), 22.0)
	await snap("2_face_from_player")

	# 2: the player moves to her left; she follows with her eyes first, then her head (watched from the side)
	player.global_position = Vector3(1.0, 1.55, 0.35)
	aim(Vector3(0.45, 1.65, 1.0), Vector3(0, 1.5, 0.05), 18.0)
	for frame in [4, 14, 60]:
		var n: int = frame
		while n > 0:
			woman.update(1.0 / 72.0)
			n -= 1
		await snap("3_follow_%02d" % frame)

	# 3: a punch in the face from the player's right hand, then a hook from her left
	player.global_position = Vector3(0, 1.62, 0.85)
	for i in 200:
		woman.update(1.0 / 72.0)
	aim(Vector3(1.0, 1.55, 1.1), Vector3(0, 1.45, 0.0), 22.0)
	woman.hit(woman.head_center() + Vector3(0.03, -0.03, 0.10), Vector3(-0.3, 0.2, -5.0), 1.0)
	var done := 0
	for t in [3, 9, 18, 32]:
		while done < t:
			woman.update(1.0 / 72.0)
			done += 1
		await snap("4_punch_%02d" % t)
	for i in 300:
		woman.update(1.0 / 72.0)
	woman.hit(woman.head_center() + Vector3(0.10, 0.0, 0.03), Vector3(-5.0, 0, 0), 1.0)
	aim(Vector3(0.5, 1.6, 1.4), Vector3(0, 1.45, 0.0), 22.0)
	done = 0
	for t in [3, 9, 18, 32]:
		while done < t:
			woman.update(1.0 / 72.0)
			done += 1
		await snap("5_hook_%02d" % t)

	# 4: the player's own view: both hands up, then a fist at her face
	for i in 300:
		woman.update(1.0 / 72.0)
	var left := FakeController.new()
	var right := FakeController.new()
	root.add_child(left)
	root.add_child(right)
	var hands := VrHands.new({"left": left, "right": right})
	left.global_position = Vector3(-0.22, 1.30, 0.50)
	right.global_position = Vector3(0.22, 1.30, 0.50)
	left.floats = {"trigger": 1.0, "grip": 1.0}
	right.floats = {"trigger": 1.0, "grip": 1.0}
	hands.update(0.2)
	aim(Vector3(0, 1.62, 0.85), Vector3(0, 1.4, 0.0), 80.0)
	await snap("6_player_view_fists")
	left.floats = {}
	right.global_position = Vector3(0.05, 1.50, 0.22)
	hands.update(0.2)
	aim(Vector3(0.55, 1.58, 0.75), Vector3(0.0, 1.45, 0.15), 45.0)
	await snap("7_fist_at_face")
	quit()
