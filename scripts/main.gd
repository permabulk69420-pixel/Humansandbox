# The sandbox: a woman a little way in front of you who watches you, turns to face you, wanders about, and who you can punch. In a
# headset (OpenXR, Quest) you have the skinned hands from the skatepark game on your controllers: the left stick walks, the right stick
# turns. On a flat screen the camera stands where you would: WASD walks, Q/E or the arrow keys turn, and Space or a click throws a punch.
extends Node3D

const REFRESH_RATE := 72.0          # SpaceWarp needs the display at a rate it can evenly halve; Meta's own example is 72 Hz display / 36 fps render
var space_warp: Object = null       # OpenXRFbSpaceWarpExtension singleton, if the runtime and build support it
const RENDER_SCALE := 1.5          # headset render resolution as a multiple of the Quest's recommended size, per eye
const WOMAN_DISTANCE := 0.8        # metres in front of you; she faces +Z, so by default she faces the play-space centre
const SETTLE_FRAMES := 30          # let headset tracking settle before reading where you are looking
const GIVE_UP_FRAMES := 270        # ...but never wait longer than this (a few seconds) for a sensible head height
const MOVE_SPEED := 1.6            # m/s walking with the left stick (or WASD)
const TURN_SPEED := deg_to_rad(110.0)   # rad/s turning with the right stick (or Q/E, the arrow keys)
const STICK_DEADZONE := 0.2
const PERSONAL_SPACE := 0.45       # walking cannot take you closer than this to her
const ROOM_MIN := Vector2(KillRoom.X0 + 0.3, KillRoom.Z0 + 0.3)   # the walls, as a backstop in case the collision ever lets you through (x, z)
const ROOM_MAX := Vector2(KillRoom.X1 - 0.3, KillRoom.Z1 - 0.3)
const BODY_RADIUS := 0.28          # your body, for bumping into the room and its props
const BODY_HEIGHT := 1.6
const BODY_LIFT := 0.15            # it floats this far off the floor, so low things (the drain cover, a threshold) do not stop you
const EYE_HEIGHT := 1.62           # flat-screen camera height

var vr := false
var rig: Node3D
var camera: Camera3D
var left_controller: XRController3D
var right_controller: XRController3D
var hands: VrHands
var woman: Woman
var room: KillRoom
var body: CharacterBody3D
var detector := PunchDetector.new()
var thud: AudioStreamPlayer3D
var flat_hit_hand := "right"
var settle_frames := 0
var placed := false
var resolution_label: Label3D
var resolution_timer := 0.0


func _ready() -> void:
	vr = _start_xr()
	_build_environment()

	woman = Woman.new()
	woman.name = "Woman"
	woman.position = Vector3(0.0, 0.0, -WOMAN_DISTANCE)
	woman.visible = not vr   # in a headset she appears once you have been placed, not somewhere you were not looking
	add_child(woman)
	KillRoom.apply_anisotropic(woman)

	if vr:
		rig = XROrigin3D.new()
		camera = XRCamera3D.new()
		left_controller = _make_controller(&"left_hand")
		right_controller = _make_controller(&"right_hand")
		rig.add_child(left_controller)
		rig.add_child(right_controller)
	else:
		rig = Node3D.new()
		camera = Camera3D.new()
		camera.position = Vector3(0.0, EYE_HEIGHT, 0.0)
	rig.name = "Rig"
	add_child(rig)
	camera.name = "Camera"
	camera.fov = 72.0
	camera.near = 0.05
	camera.current = true
	rig.add_child(camera)
	resolution_label = _make_resolution_label()
	camera.add_child(resolution_label)
	woman.target = camera

	if vr:
		hands = VrHands.new({"left": left_controller, "right": right_controller})
		KillRoom.apply_anisotropic(left_controller)    # the hand models hang off the controllers
		KillRoom.apply_anisotropic(right_controller)
		detector.add_hand("left", left_controller)
		detector.add_hand("right", right_controller)
	detector.punched.connect(_on_punched)
	detector.reference = rig
	woman.wander = true
	if vr:
		var xr := XRServer.find_interface("OpenXR")
		if xr != null and xr.has_signal("pose_recentered"):
			# recentring the headset brings her back in front of you
			xr.connect("pose_recentered", func() -> void:
				_skip_space_warp_frame()
				get_tree().create_timer(0.3).timeout.connect(place_woman))
		# Application SpaceWarp: the runtime renders real frames at half rate and fills in the rest itself. It needs the play
		# space to hold still between frames, so locomote() tells it to skip a frame whenever you walk or turn.
		if Engine.has_singleton("OpenXRFbSpaceWarpExtension"):
			space_warp = Engine.get_singleton("OpenXRFbSpaceWarpExtension")
			if space_warp.has_method("set_space_warp_enabled"):
				space_warp.set_space_warp_enabled(true)
			else:
				space_warp = null

	thud = AudioStreamPlayer3D.new()
	thud.stream = _make_thud()
	thud.unit_size = 4.0
	woman.add_child(thud)
	print("Humansandbox ready%s" % (" · headset" if vr else ""))


func _process(delta: float) -> void:
	var dt := minf(delta, 0.05)
	resolution_timer -= delta
	if resolution_timer <= 0.0:
		resolution_timer = 0.5
		resolution_label.text = _resolution_text()
	if vr and not placed:
		# the play space's "forward" is wherever you faced when you last recentred, not necessarily where you are looking now:
		# stand her where you are looking once tracking has settled
		settle_frames += 1
		if (settle_frames > SETTLE_FRAMES and camera.position.y > 0.4) or settle_frames > GIVE_UP_FRAMES:
			place_woman()
			placed = true
	var move := Vector2.ZERO
	var turn := 0.0
	if vr:
		move = stick_value(left_controller.get_vector2("primary"))
		turn = stick_value(right_controller.get_vector2("primary")).x
	else:
		move = Vector2(float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
			float(Input.is_key_pressed(KEY_W)) - float(Input.is_key_pressed(KEY_S)))
		turn = float(Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_LEFT))
	locomote(move, turn, dt)
	if hands != null:
		hands.update(dt)
	detector.update(dt, woman)


func _unhandled_input(event: InputEvent) -> void:
	if vr:
		return
	var fire: bool = (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE) \
		or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT)
	if fire:
		throw_flat_punch()


# Stands her in front of where the player is looking, on the floor, facing them.
func place_woman() -> void:
	woman.visible = true
	woman.global_transform = placement(camera.global_position, -camera.global_basis.z, rig.global_position.y, WOMAN_DISTANCE)
	woman.home = woman.global_position
	woman.move_target = null
	woman.pause_timer = 3.0


# A thumbstick reading with its dead zone taken out (so it rests at exactly zero and ramps up from there).
static func stick_value(raw: Vector2) -> Vector2:
	var length := raw.length()
	if length < STICK_DEADZONE:
		return Vector2.ZERO
	return raw / length * minf(1.0, (length - STICK_DEADZONE) / (1.0 - STICK_DEADZONE))


# Walk (move.y forward, move.x right, relative to where you are looking) and turn (+ is right). Turning pivots on your head, so the room
# does not swing round you. Everything you hold moves with the play space.
func locomote(move: Vector2, turn: float, dt: float) -> void:
	if absf(turn) > 0.001 or move.length() > 0.001:
		_skip_space_warp_frame()
	if absf(turn) > 0.001:
		var angle := -turn * TURN_SPEED * dt
		var pivot := camera.global_position
		rig.global_position = pivot + (rig.global_position - pivot).rotated(Vector3.UP, angle)
		rig.rotate_y(angle)
	if move.length() > 0.001:
		var forward := -camera.global_basis.z
		forward.y = 0.0
		var right := camera.global_basis.x
		right.y = 0.0
		var heading := (forward.normalized() * move.y + right.normalized() * move.x) if forward.length() > 0.01 else Vector3.ZERO
		rig.global_position += _slide(heading * MOVE_SPEED * dt)
		# you cannot walk through her, or through the walls
		var away := Vector2(camera.global_position.x - woman.global_position.x, camera.global_position.z - woman.global_position.z)
		if away.length() < PERSONAL_SPACE:
			var push := (away.normalized() if away.length() > 0.001 else Vector2.DOWN) * (PERSONAL_SPACE - away.length())
			rig.global_position += Vector3(push.x, 0.0, push.y)
		rig.global_position.x = clampf(rig.global_position.x, ROOM_MIN.x, ROOM_MAX.x)
		rig.global_position.z = clampf(rig.global_position.z, ROOM_MIN.y, ROOM_MAX.y)


# Moves your body through the room's collision and returns how far it really got, sliding along walls and props instead of sticking.
func _slide(motion: Vector3) -> Vector3:
	body.global_position = Vector3(camera.global_position.x, rig.global_position.y + BODY_LIFT + BODY_HEIGHT * 0.5, camera.global_position.z)
	var start := body.global_position
	for i in 3:
		var hit := body.move_and_collide(motion)
		if hit == null:
			break
		motion = hit.get_remainder().slide(hit.get_normal())
		motion.y = 0.0
		if motion.length() < 0.0005:
			break
	return body.global_position - start


static func placement(camera_position: Vector3, camera_forward: Vector3, floor_y: float, distance: float) -> Transform3D:
	var forward := Vector3(camera_forward.x, 0.0, camera_forward.z)
	forward = forward.normalized() if forward.length() > 0.1 else Vector3.FORWARD   # looking straight up or down: use the play-space heading
	var position := Vector3(camera_position.x, floor_y, camera_position.z) + forward * distance
	var yaw := atan2(-forward.x, -forward.z)   # her front (+Z) must point back at the player
	return Transform3D(Basis(Vector3.UP, yaw), position)


# Flat-screen punch: a fist from the camera, straight at her face.
func throw_flat_punch() -> void:
	var from := camera.global_transform * Vector3(0.18 if flat_hit_hand == "right" else -0.18, -0.25, -0.3)
	var velocity := (woman.head_center() - from).normalized() * 5.0
	_on_punched(flat_hit_hand, woman.head_center() - velocity.normalized() * (Woman.HEAD_RADIUS * 0.8), velocity, 0.8)
	flat_hit_hand = "left" if flat_hit_hand == "right" else "right"


func _on_punched(hand_name: String, point: Vector3, velocity: Vector3, strength: float) -> void:
	woman.hit(point, velocity, strength)
	thud.global_position = point
	thud.pitch_scale = 0.85 + 0.3 * (1.0 - strength) + randf_range(-0.04, 0.04)
	thud.volume_db = lerpf(-12.0, 0.0, strength)
	thud.play()
	var controller: XRController3D = left_controller if hand_name == "left" else right_controller
	if controller != null:
		controller.trigger_haptic_pulse("haptic", 0.0, lerpf(0.4, 1.0, strength), lerpf(0.04, 0.12, strength), 0.0)


func _skip_space_warp_frame() -> void:
	if space_warp != null and space_warp.has_method("skip_space_warp_frame"):
		space_warp.skip_space_warp_frame()


# ---- headset ----------------------------------------------------------------------------------------------------------------------

# A small panel low in your view showing what the headset is actually rendering at.
static func _make_resolution_label() -> Label3D:
	var label := Label3D.new()
	label.name = "ResolutionOverlay"
	label.position = Vector3(0.0, -0.22, -0.7)
	label.pixel_size = 0.0006
	label.font_size = 32
	label.outline_size = 8
	label.no_depth_test = true
	label.render_priority = 10
	label.modulate = Color(1.0, 1.0, 0.6)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	return label


func _resolution_text() -> String:
	var lines: PackedStringArray = []
	var viewport := get_viewport()
	var xr := XRServer.find_interface("OpenXR")
	if vr and xr != null and xr.is_initialized():
		var eye := xr.get_render_target_size()
		lines.append("Eye buffer: %d x %d per eye" % [eye.x, eye.y])
		lines.append("Multiplier: x%.2f" % float(xr.get("render_target_size_multiplier")))
		lines.append("Foveation: %d%s" % [int(xr.get("foveation_level")), " dynamic" if xr.get("foveation_dynamic") else ""])
		lines.append("Refresh: %.0f Hz" % float(xr.get("display_refresh_rate")))
	lines.append("3D scale: %.2f   MSAA: %s" % [viewport.scaling_3d_scale, ["off", "2x", "4x", "8x"][viewport.msaa_3d]])
	lines.append("Renderer: %s" % RenderingServer.get_current_rendering_method())
	lines.append("FPS: %d" % Engine.get_frames_per_second())
	return "\n".join(lines)


# Starts OpenXR if there is a headset to talk to. Returns false (and plays on a flat screen) if there is not.
func _start_xr() -> bool:
	var xr := XRServer.find_interface("OpenXR")
	if xr == null:
		return false
	if not xr.is_initialized() and not xr.initialize():
		return false
	get_viewport().use_xr = true
	xr.set("render_target_size_multiplier", RENDER_SCALE)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)   # the headset sets the pace
	if xr.has_method("get_available_display_refresh_rates"):
		var rates = xr.call("get_available_display_refresh_rates")
		if rates is Array and REFRESH_RATE in rates:
			xr.set("display_refresh_rate", REFRESH_RATE)
	return true


static func _make_controller(tracker: StringName) -> XRController3D:
	var controller := XRController3D.new()
	controller.tracker = tracker
	controller.pose = &"grip"       # where the hand holds the controller; the default pose is the aim ray, which points out ahead of it
	controller.name = String(tracker)
	return controller


# ---- the room ---------------------------------------------------------------------------------------------------------------------

func _build_environment() -> void:
	room = KillRoom.new()
	room.name = "Room"
	add_child(room)
	# your body: a capsule that only looks at the room's solid things (layer 1) and is moved by hand in _slide()
	body = CharacterBody3D.new()
	body.name = "Body"
	body.collision_layer = 0
	body.collision_mask = 1
	body.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	var capsule := CapsuleShape3D.new()
	capsule.radius = BODY_RADIUS
	capsule.height = BODY_HEIGHT
	var shape := CollisionShape3D.new()
	shape.shape = capsule
	body.add_child(shape)
	add_child(body)


# A dull thud for a punch landing, made in code: a falling low tone with a burst of noise on the front.
static func _make_thud() -> AudioStreamWAV:
	var rate := 22050
	var length := int(rate * 0.22)
	var data := PackedByteArray()
	data.resize(length * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var phase := 0.0
	for i in length:
		var t := float(i) / rate
		var freq := 52.0 + 110.0 * exp(-t * 28.0)
		phase += TAU * freq / rate
		var tone := sin(phase) * exp(-t * 16.0)
		var slap := rng.randf_range(-1.0, 1.0) * exp(-t * 90.0) * 0.55
		var sample := clampf((tone * 0.9 + slap) * 0.85, -1.0, 1.0)
		data.encode_s16(i * 2, int(sample * 32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.data = data
	return stream
