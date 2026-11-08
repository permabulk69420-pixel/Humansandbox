# The blowtorch (assets/props/blowtorch/cinder_blowtorch.glb): a physics prop you pick up with the grip button and light by pulling the
# trigger. Held, it sits in the hand exactly where tools/solve_torch_grip.gd found it fits without any finger going into it, and the
# fingers close onto it as solved (assets/props/blowtorch/grip_solution.json: the torch's turn and offset in the controller's grip frame,
# and how far each finger closes, for each hand). The trigger lever follows the trigger button through the model's Trigger_Press clip,
# and past about half way the flame lights. Let go and it drops, going out if it was lit.
class_name Blowtorch
extends RigidBody3D

signal lit_changed(is_lit: bool)

const MODEL := "res://assets/props/blowtorch/cinder_blowtorch.glb"
const SOLUTION := "res://assets/props/blowtorch/grip_solution.json"
const LIGHT_AT := 0.55                 # trigger pull that lights it, and
const OUT_AT := 0.25                   # the pull below which it goes out
const GRAB_TIME := 0.08                # seconds the torch takes to fly into the hand
const FLAME_LENGTH := 0.26             # metres, in the torch's own (unscaled) size: about 16 cm at the size it is held
const THROW_LIMIT := 9.0               # m/s

var solution := {}
var torch_scale := 1.0
var held_by := ""                       # "left" or "right" while someone holds it
var lit := false
var model: Node3D
var flame_origin: Node3D
var grip_point := Vector3.ZERO          # the model's GripPoint marker, torch space (unscaled)
var _controller: Node3D
var _hold := Transform3D.IDENTITY       # the torch in the controller's grip frame
var _grab_t := 1.0
var _grab_from := Transform3D.IDENTITY
var _lever: Node3D
var _lever_clip: Animation
var _lever_track := -1
var _flame_nodes: Array[MeshInstance3D] = []
var _flame_light: OmniLight3D
var _hiss: AudioStreamPlayer3D
var _ignite: AudioStreamPlayer3D
var _intensity := 0.0
var _history: Array = []                # [time, position, basis] of the controller, for throwing
var _t := 0.0


func _ready() -> void:
	var raw := FileAccess.get_file_as_string(SOLUTION) if FileAccess.file_exists(SOLUTION) else "{}"
	solution = JSON.parse_string(raw)
	torch_scale = float(solution.get("scale", 1.0))

	model = (load(MODEL) as PackedScene).instantiate()
	model.scale = Vector3.ONE * torch_scale
	add_child(model)
	KillRoom.apply_anisotropic(model)
	flame_origin = model.find_child("FlameOrigin", true, false)
	grip_point = (model.find_child("GripPoint", true, false) as Node3D).position
	_lever = model.find_child("TriggerPivot", true, false)
	var anim_player: AnimationPlayer = model.find_child("AnimationPlayer", true, false)
	_lever_clip = anim_player.get_animation("Trigger_Press")
	_lever_track = _lever_clip.find_track(NodePath("Cinder_Blowtorch/TriggerPivot"), Animation.TYPE_ROTATION_3D)
	anim_player.free()                  # the lever is driven by the trigger, not by a clip playing on its own

	# physics: a convex hull of the body, standing on its base, heavier towards the grip than the nozzle
	var body_mesh := (model.find_child("Blowtorch_Body", true, false) as MeshInstance3D).mesh
	var hull := body_mesh.create_convex_shape(true, false) as ConvexPolygonShape3D
	var points := hull.points
	for i in points.size():
		points[i] *= torch_scale
	hull.points = points
	var shape := CollisionShape3D.new()
	shape.shape = hull
	add_child(shape)
	mass = 0.7
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, 0.1 * torch_scale, 0.0)
	collision_layer = 2                 # props: the room (layer 1) holds them up, you do not bump into them
	collision_mask = 1
	continuous_cd = true
	linear_damp = 0.1
	angular_damp = 0.8
	var material := PhysicsMaterial.new()
	material.friction = 0.9
	material.bounce = 0.05
	physics_material_override = material

	_build_flame()
	_hiss = AudioStreamPlayer3D.new()
	_hiss.stream = _make_hiss()
	_hiss.unit_size = 2.5
	_hiss.max_distance = 20.0
	_hiss.volume_db = -60.0
	flame_origin.add_child(_hiss)
	_ignite = AudioStreamPlayer3D.new()
	_ignite.stream = _make_ignite()
	_ignite.unit_size = 3.0
	flame_origin.add_child(_ignite)
	_set_flame(0.0)


func _process(delta: float) -> void:
	_t += delta
	if held_by != "" and _controller != null:
		var target := _controller.global_transform * _hold
		if _grab_t < 1.0:
			_grab_t = minf(1.0, _grab_t + delta / GRAB_TIME)
			global_transform = _grab_from.interpolate_with(target, smoothstep(0.0, 1.0, _grab_t))
		else:
			global_transform = target
		_history.append([_t, _controller.global_position, _controller.global_basis])
		while _history.size() > 2 and _t - _history[0][0] > 0.12:
			_history.pop_front()
	# the flame fades in and out, and flickers
	var goal := 1.0 if lit else 0.0
	_intensity = move_toward(_intensity, goal, delta * (9.0 if lit else 6.0))
	_set_flame(_intensity)
	if not lit and _intensity <= 0.0 and _hiss.playing:
		_hiss.stop()


# ---- picking it up ---------------------------------------------------------------------------------------------------------------------

# How far a point (a hand, in the world) is from the torch's grip, for deciding whether a hand can pick it up.
func grab_distance(world_point: Vector3) -> float:
	var local := to_local(world_point) / torch_scale
	var closest := Geometry3D.get_closest_point_to_segment(local, Vector3(0.0, 0.03, 0.0), Vector3(0.0, 0.27, 0.0))
	return (local - closest).length() * torch_scale


# Puts the torch in a hand. `controller` is the XRController3D (its grip pose is where a held thing sits).
func grab(hand: String, controller: Node3D) -> void:
	var mine: Dictionary = solution.get(hand, {})
	if mine.is_empty():
		push_warning("no grip solution for the %s hand" % hand)
		return
	held_by = hand
	_controller = controller
	var offset := Vector3(mine.offset[0], mine.offset[1], mine.offset[2])
	var basis := Basis(Vector3.UP, deg_to_rad(mine.get("yaw", 0.0))) * Basis(Vector3.RIGHT, deg_to_rad(mine.get("pitch", 0.0))) * Basis(Vector3.BACK, deg_to_rad(mine.get("roll", 0.0)))
	# the model is already scaled, so the torch node itself carries only the turn: GripPoint (scaled) lands on `offset`
	_hold = Transform3D(basis, offset - basis * (grip_point * torch_scale))
	_grab_from = global_transform
	_grab_t = 0.0
	_history.clear()
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true


# How far each finger of that hand closes onto the torch (see tools/solve_torch_grip.gd), for VrHands.
func finger_amounts(hand: String) -> Dictionary:
	var mine: Dictionary = solution.get(hand, {})
	return mine.get("fingers", {}).duplicate()


func release() -> void:
	if held_by == "":
		return
	var velocity := Vector3.ZERO
	var spin := Vector3.ZERO
	if _history.size() >= 2:
		var a: Array = _history[0]
		var b: Array = _history[_history.size() - 1]
		var dt: float = maxf(b[0] - a[0], 0.001)
		velocity = (b[1] - a[1]) / dt
		var turn := Quaternion(b[2]) * Quaternion(a[2]).inverse()      # how the hand turned over that time
		if absf(turn.w) < 0.9999:
			spin = turn.get_axis() * turn.get_angle() / dt
	held_by = ""
	_controller = null
	freeze = false
	linear_velocity = velocity.limit_length(THROW_LIMIT)
	angular_velocity = spin.limit_length(25.0)
	set_trigger(0.0)


# The trigger button's pull (0..1), while held: moves the lever, and lights or puts out the flame.
func set_trigger(pull: float) -> void:
	if _lever_track >= 0:
		_lever.quaternion = _lever_clip.rotation_track_interpolate(_lever_track, clampf(pull, 0.0, 1.0) * _lever_clip.length)
	if held_by == "":
		pull = 0.0
	if not lit and pull > LIGHT_AT:
		_light(true)
	elif lit and pull < OUT_AT:
		_light(false)


func _light(on: bool) -> void:
	lit = on
	if on:
		_ignite.play()
		_hiss.volume_db = -8.0
		_hiss.play()
	lit_changed.emit(on)


# ---- the flame -------------------------------------------------------------------------------------------------------------------------

func _build_flame() -> void:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, fog_disabled;
uniform vec3 base_color : source_color = vec3(0.35, 0.55, 1.0);
uniform vec3 tip_color : source_color = vec3(1.0, 0.5, 0.12);
uniform float flame_length = 0.26;
uniform float strength = 1.0;
uniform float flicker = 24.0;
varying float along;
void vertex() {
	along = clamp(-VERTEX.z / flame_length, 0.0, 1.0);
	VERTEX.x += sin(TIME * flicker + VERTEX.z * 70.0) * 0.0016 * along;
	VERTEX.y += cos(TIME * flicker * 1.3 + VERTEX.z * 50.0) * 0.0016 * along;
	VERTEX.z *= 1.0 + 0.07 * sin(TIME * 33.0);
}
void fragment() {
	float facing = pow(clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 1.3);
	ALBEDO = mix(base_color, tip_color, smoothstep(0.1, 1.0, along)) * strength * 1.6;
	ALPHA = clamp(facing * pow(1.0 - along, 0.55) * strength, 0.0, 1.0);
}
"""
	# an outer flame, orange at the tip, and a short hot blue core inside it
	for spec in [[FLAME_LENGTH, 0.022, Color(0.35, 0.55, 1.0), Color(1.0, 0.5, 0.12), 0.8], [FLAME_LENGTH * 0.55, 0.011, Color(0.75, 0.9, 1.0), Color(0.4, 0.6, 1.0), 1.1]]:
		var material := ShaderMaterial.new()
		material.shader = shader
		material.set_shader_parameter("flame_length", spec[0])
		material.set_shader_parameter("base_color", spec[2])
		material.set_shader_parameter("tip_color", spec[3])
		material.set_shader_parameter("strength", spec[4])
		var mi := MeshInstance3D.new()
		mi.mesh = _make_flame_mesh(spec[0], spec[1])
		mi.material_override = material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.extra_cull_margin = 0.2
		flame_origin.add_child(mi)
		_flame_nodes.append(mi)
	_flame_light = OmniLight3D.new()
	_flame_light.light_color = Color(1.0, 0.62, 0.3)
	_flame_light.omni_range = 2.2
	_flame_light.light_energy = 0.0
	_flame_light.position = Vector3(0.0, 0.0, -FLAME_LENGTH * 0.4)
	flame_origin.add_child(_flame_light)


func _set_flame(amount: float) -> void:
	var on := amount > 0.001
	for mi in _flame_nodes:
		mi.visible = on
		if on:
			(mi.material_override as ShaderMaterial).set_shader_parameter("strength", amount)
	_flame_light.visible = on
	_flame_light.light_energy = amount * (1.1 + 0.25 * sin(_t * 38.0) + 0.15 * sin(_t * 61.0))
	if _hiss != null:
		_hiss.volume_db = lerpf(-50.0, -8.0, amount)


# A teardrop of revolution along -Z from the nozzle: wide at the burner, tapering to a point.
static func _make_flame_mesh(length: float, radius: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings := 14
	var sides := 12
	var points: Array[Vector3] = []     # (radius, z, normal angle) per ring
	for i in rings + 1:
		var t := float(i) / rings
		var r := radius * pow(1.0 - t, 0.75) * (1.0 + 0.25 * sin(t * 3.1))
		points.append(Vector3(r, -t * length, 0.0))
	for i in rings:
		for k in sides:
			var a0 := TAU * k / sides
			var a1 := TAU * (k + 1) / sides
			var p00 := Vector3(cos(a0) * points[i].x, sin(a0) * points[i].x, points[i].y)
			var p10 := Vector3(cos(a1) * points[i].x, sin(a1) * points[i].x, points[i].y)
			var p01 := Vector3(cos(a0) * points[i + 1].x, sin(a0) * points[i + 1].x, points[i + 1].y)
			var p11 := Vector3(cos(a1) * points[i + 1].x, sin(a1) * points[i + 1].x, points[i + 1].y)
			var n0 := Vector3(cos(a0), sin(a0), 0.2).normalized()
			var n1 := Vector3(cos(a1), sin(a1), 0.2).normalized()
			for v in [[p00, n0], [p11, n1], [p10, n1], [p00, n0], [p01, n0], [p11, n1]]:
				st.set_normal(v[1])
				st.add_vertex(v[0])
	return st.commit()


# ---- sound, made in code ---------------------------------------------------------------------------------------------------------------

# A steady gas roar: low rumble and a bright hiss, built to loop without a click.
static func _make_hiss() -> AudioStreamWAV:
	var rate := 22050
	var length := int(rate * 1.4)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var raw := PackedFloat32Array()
	raw.resize(length)
	var low := 0.0
	var mid := 0.0
	for i in length:
		var n := rng.randf_range(-1.0, 1.0)
		low += (n - low) * 0.05
		mid += (n - mid) * 0.35
		var hiss := n - mid
		raw[i] = low * 3.2 + (mid - low) * 0.9 + hiss * 0.55
	# fade the end into the start so the loop point cannot be heard
	var fade := int(rate * 0.12)
	for i in fade:
		var w := float(i) / fade
		raw[i] = raw[i] * w + raw[length - fade + i] * (1.0 - w)
	var data := PackedByteArray()
	data.resize((length - fade) * 2)
	for i in length - fade:
		data.encode_s16(i * 2, int(clampf(raw[i] * 0.35, -1.0, 1.0) * 32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.data = data
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = length - fade
	return stream


# The soft "whump" of the gas catching.
static func _make_ignite() -> AudioStreamWAV:
	var rate := 22050
	var length := int(rate * 0.35)
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var data := PackedByteArray()
	data.resize(length * 2)
	var low := 0.0
	var phase := 0.0
	for i in length:
		var t := float(i) / rate
		var n := rng.randf_range(-1.0, 1.0)
		low += (n - low) * 0.12
		phase += TAU * (95.0 - 45.0 * minf(t / 0.25, 1.0)) / rate
		var body := sin(phase) * exp(-t * 11.0)
		var puff := low * exp(-t * 9.0) * 2.2 * minf(t * 120.0, 1.0)
		data.encode_s16(i * 2, int(clampf((body * 0.8 + puff) * 0.7, -1.0, 1.0) * 32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.data = data
	return stream
