# The woman: the rigged human in assets/woman/woman.glb (rigged by tools/rig_woman.py). She stands where she is put, faces +Z, and
#   * watches whoever `target` is: the head and neck turn towards it within human limits, and each eye aims at it on its own
#   * plays baked mocap clips for her base motion (idle, walk; tools/bake_clips.gd retargets them from a CC0 library onto her skeleton)
#   * walks: she turns her body to face the player when they move round her, can walk to a point (walk_to) or wander about her spot
#   * can be knocked down: every punch adds damage (by its strength squared, fading over a few seconds); enough of it and she falls the
#     way the punch was travelling, lies there for longer the harder she was hit, and gets back up (the fall clip played backwards)
#   * takes a punch: hit() turns the fist's speed and where it landed into a spin on her head, which a spring carries through
#     the spine, neck and head and then settles; she loses track of the player for a moment and then finds them again.
#
# Every bone is posed by writing its rotation directly (nothing is left to an AnimationPlayer). A bone is turned by a rotation in
# model space about its own joint; a child inherits its parents' turns, so the offsets just stack from the hips up. The clip sets each
# bone's offset first and the looking and the punch reaction are stacked on top of it.
class_name Woman
extends Node3D

signal hit_taken(point: Vector3, strength: float)

const MODEL := "res://assets/woman/woman.glb"
const HEAD_CENTER_REST := Vector3(0.0, 1.52, 0.055)   # the middle of the skull when she stands at rest, in model space
const HEAD_RADIUS := 0.12                             # round her face, jaw and the back of her skull

# Looking
const LOOK_SHARE := {"Neck": 0.35, "Head": 0.65}      # how the turn towards the target is split
const MAX_YAW := deg_to_rad(66.0)                     # the most the head can turn either way
const MAX_PITCH_UP := deg_to_rad(30.0)
const MAX_PITCH_DOWN := deg_to_rad(35.0)
const MAX_EYE_ANGLE := deg_to_rad(38.0)               # the most an eye can turn away from where the head points
const HEAD_RATE := 5.0                                # how briskly the head follows (per second)
const EYE_RATE := 16.0                                # eyes move much faster than heads

# Taking a punch
const REACTION_SHARE := {"Spine": 0.04, "Chest": 0.06, "UpperChest": 0.10, "Neck": 0.30, "Head": 0.50}
const SPIN_GAIN := 34.0                               # radians per second of head spin per (metre * metre-per-second) of torque
const MAX_SPIN := 11.0
const NECK_FREEDOM := Vector3(1.0, 1.4, 0.5)          # pitch, yaw, roll: a neck turns far more easily than it tips sideways
const MAX_REACTION := deg_to_rad(42.0)                # the head never swings further than this
const SPRING_HZ := 1.6
const SPRING_DAMPING := 0.30                          # < 1: it overshoots a little before it settles
const ATTENTION_RETURN := 2.5                         # per second, once she has recovered

# Clips and walking
const CLIPS := "res://assets/woman/clips.json"
const FADE_TIME := 0.25                               # seconds to blend from one clip to the next
const TURN_STEP_RATE := 0.8                           # playback rate of the walk when she is only turning on the spot
const TURN_RATE := deg_to_rad(130.0)                  # the fastest she turns her body
const TURN_ACCEL := deg_to_rad(500.0)
const WALK_ACCEL := 1.2
const FACE_AFTER := deg_to_rad(50.0)                  # she turns her body once the player is further than this off her front...
const FACE_DONE := deg_to_rad(8.0)                    # ...and stops when they are this close to it
const FALL_CLIP := "Death01"
const DAMAGE_PER_PUNCH := 1.2                         # times the punch's strength squared
const DAMAGE_FADE := 0.35                             # per second
const KNOCKDOWN_AT := 1.0                             # one full-strength punch, or two or three decent ones close together
const GET_UP_RATE := 0.8                              # the fall clip played backwards, a bit slower
const FALL_START := 0.3                               # the clip eases in slowly: start it already part way into the collapse
const FALL_RATE_MIN := 1.4                            # and play it faster than recorded, faster still for a harder punch
const FALL_RATE_MAX := 1.8
const WANDER_RADIUS := 1.2
const KEEP_AWAY := 0.9                                # wandering never takes her this close to the player

var target: Node3D                 # who she watches (the player's camera)
var skeleton: Skeleton3D
var model: Node3D
var hits := 0
var look_weight := 1.0             # 1 = fully watching the target, 0 = staring straight ahead
var hit_angle := Vector3.ZERO      # the head's reaction, as a rotation vector in model space
var hit_velocity := Vector3.ZERO
var stun := 0.0                    # seconds left before she starts watching again
var look_yaw := 0.0                # where the head is turned now (radians; + is her left)
var look_pitch := 0.0              # + is up
var time := 0.0

var bone := {}                     # name -> bone index
var rest_q: Array[Quaternion] = []     # each bone's rest rotation relative to its parent
var rest_gq: Array[Quaternion] = []    # ... and in model space
var rest_origin: Array[Vector3] = []   # each bone's rest position in model space
var parents: Array[int] = []
var head_center_local := Vector3.ZERO  # HEAD_CENTER_REST in the head bone's own frame
var eye_q := {"LeftEye": Quaternion.IDENTITY, "RightEye": Quaternion.IDENTITY}
var saccade := Vector2.ZERO        # a small random flick of the eyes (yaw, pitch)
var saccade_timer := 1.0
var rng := RandomNumberGenerator.new()

var clips := {}                    # clip name -> baked frames (see _load_clips)
var clip_bones: Array[int] = []    # the bones the clips animate, in the order the baked frames list them
var clip_name := "Idle_Loop"
var clip_time := 0.0
var clip_rate := 1.0
var fade_name := ""                # the clip we are blending away from
var fade_time := 0.0
var fade_rate := 1.0
var fade := 1.0                    # 1 = all on the current clip
var walk_speed := 0.8              # m/s her feet cover the ground at in the walk clip, at normal playback

var body_turns := true              # turn the whole body to face the player when they move round to her side
enum Fall { STANDING, FALLING, LYING, GETTING_UP }
var fall_state := Fall.STANDING
var damage := 0.0
var lie_timer := 0.0
var fall_yaw := 0.0                # the way she is turned as she falls so that she goes down the way she was hit
var knockdowns := 0
var fall_rate := 1.5
var fade_length := FADE_TIME
var wander := false                # stroll about `home` when nothing else is going on
var home := Vector3.ZERO           # the spot she wanders round
var move_target = null             # a world point she is walking to (Vector3), or null
var speed := 0.0                   # m/s along her facing
var turn_velocity := 0.0           # rad/s of the body turning
var turning_to_face := false
var pause_timer := 3.0             # seconds before she sets off somewhere
var rest_local_origin: Array[Vector3] = []

# Strapped to a table, on her back, struggling (strap_down()).
const LIE_HIPS_HEIGHT := 0.115          # how high her hips sit above the table
const STRUGGLE_BASE := 0.18             # she is never quite still
const STRUGGLE_GAIN := 1.0              # how hard she pulls (times the degrees in _add_struggle)
const STRUGGLE_GAIN_HEAD := 1.0
const STRUGGLE_MAX := 1.3               # and the most energy a hit can add on top
const LEGS_TOGETHER := deg_to_rad(-5.6)  # how far each leg is turned in from the rest pose's slightly open stance
var strapped := false
var struggle := 0.0                     # extra struggling after being hit, easing off
var _wriggle_scale := 1.0
var _straps: Node3D
var body: RagdollBody


func _ready() -> void:
	rng.seed = 7
	var packed := load(MODEL) as PackedScene
	assert(packed != null, "woman.glb is missing")
	model = packed.instantiate()
	add_child(model)
	skeleton = model.find_child("Skeleton3D", true, false)
	var count := skeleton.get_bone_count()
	for i in count:
		bone[skeleton.get_bone_name(i)] = i
		var g := skeleton.get_bone_global_rest(i)
		rest_q.append(skeleton.get_bone_rest(i).basis.get_rotation_quaternion())
		rest_gq.append(g.basis.get_rotation_quaternion())
		rest_origin.append(g.origin)
		rest_local_origin.append(skeleton.get_bone_rest(i).origin)
		parents.append(skeleton.get_bone_parent(i))
		assert(parents[i] < i, "bones must be listed parent first")
	head_center_local = skeleton.get_bone_global_rest(bone["Head"]).affine_inverse() * HEAD_CENTER_REST
	home = global_position
	_load_clips()
	# The hair, brows and lashes stay put when she turns her head only because they are skinned; keep them from being culled.
	for m: MeshInstance3D in skeleton.find_children("*", "MeshInstance3D", false, false):
		m.extra_cull_margin = 1.0
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Brows and lashes are hair-thin: cut out with a hard alpha threshold they break up into jagged black dashes (the Compatibility
	# renderer has no alpha antialiasing), so they are blended softly instead.
	for part in ["Eyebrows", "Eyelashes"]:
		var m := skeleton.get_node_or_null(part) as MeshInstance3D
		var source := m.get_active_material(0) as BaseMaterial3D if m != null else null
		if source != null:
			var soft := source.duplicate() as BaseMaterial3D
			soft.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			soft.cull_mode = BaseMaterial3D.CULL_DISABLED
			m.set_surface_override_material(0, soft)
	update(0.0)


func _process(delta: float) -> void:
	update(delta)


# ---- strapped to a table ------------------------------------------------------------------------------------------------------------------

# Lays her on her back on a table, face up, head towards `yaw`'s back, and straps her down: across the waist, both forearms, the thighs and
# the shins, and over her mouth. `table_top` is the middle of the table's top surface; `yaw` is the way her feet point (her head goes the other way).
func strap_down(table_top: Vector3, yaw: float) -> void:
	strapped = true
	fall_state = Fall.LYING
	wander = false
	move_target = null
	rotation.y = yaw
	# her hips sit a little towards her head from the middle, so that her whole body is centred on the table
	global_position = table_top + Vector3(sin(yaw), 0.0, cos(yaw)) * -0.175
	global_position.y = table_top.y
	home = global_position
	_wriggle_scale = 0.0
	update(0.0)
	_wriggle_scale = 1.0
	_build_straps()


# The body turned onto its back about the hips, and the hips lowered onto the table.
func _lie_on_back(offsets: Array[Quaternion], hips: Vector3) -> Vector3:
	# the idle clip's weight-shifted stance would leave her lopsided: keep only its relaxed arms, and lie the rest of her straight, legs together
	for part in ["Hips", "Spine", "Chest", "UpperChest", "Neck", "Head", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "LeftToes", "RightUpperLeg", "RightLowerLeg", "RightFoot", "RightToes"]:
		offsets[bone[part]] = Quaternion.IDENTITY
	# arms straight, angled a little away from her body, resting on the table (the rest pose tips them forward, which would lift them off it)
	for side in ["Left", "Right"]:
		offsets[bone[side + "Shoulder"]] = Quaternion.IDENTITY
		offsets[bone[side + "UpperArm"]] = Quaternion(Vector3.RIGHT, deg_to_rad(17.0))
		offsets[bone[side + "LowerArm"]] = Quaternion(Vector3.RIGHT, deg_to_rad(30.5))
		offsets[bone[side + "Hand"]] = Quaternion.IDENTITY
	offsets[bone["LeftUpperLeg"]] = Quaternion(Vector3.BACK, LEGS_TOGETHER) * Quaternion(Vector3.RIGHT, deg_to_rad(5.0))
	offsets[bone["RightUpperLeg"]] = Quaternion(Vector3.BACK, -LEGS_TOGETHER) * Quaternion(Vector3.RIGHT, deg_to_rad(5.0))
	var h: int = bone["Hips"]
	offsets[h] = Quaternion(Vector3.RIGHT, -PI * 0.5)
	return Vector3(0.0, LIE_HIPS_HEIGHT - rest_origin[h].y, 0.0)


# Straining against the straps in bursts: arms and legs pull, the hips twist, the back arches and the head turns from side to side.
func _add_struggle(offsets: Array[Quaternion]) -> void:
	var burst := 0.5 + 0.5 * sin(time * 0.85 + 1.6 * sin(time * 0.31))
	var energy := minf(STRUGGLE_BASE + (1.0 - STRUGGLE_BASE) * smoothstep(0.3, 0.75, burst) + struggle, STRUGGLE_MAX) * _wriggle_scale
	# bone, axis, degrees, rate, phase. Strapped limbs barely move (the straps hold them); the head, hands, feet and hips are what is free
	var moves := [
		["Hips", Vector3.UP, 4.0, 4.1, 0.0], ["Hips", Vector3.RIGHT, 1.5, 5.3, 1.1],
		["Spine", Vector3.RIGHT, 2.0, 4.6, 0.4], ["Spine", Vector3.UP, 3.0, 3.7, 2.0],
		["Chest", Vector3.UP, 3.0, 5.9, 0.7], ["Chest", Vector3.BACK, 2.0, 4.3, 1.9],
		["Head", Vector3.UP, 18.0, 3.1, 0.2], ["Head", Vector3.RIGHT, 8.0, 4.4, 1.3], ["Head", Vector3.BACK, 7.0, 2.7, 0.9],
		["LeftUpperArm", Vector3.BACK, 1.5, 6.2, 0.3], ["LeftUpperArm", Vector3.RIGHT, 1.0, 5.1, 2.2], ["LeftLowerArm", Vector3.BACK, 1.0, 7.3, 1.0],
		["RightUpperArm", Vector3.BACK, 1.5, 5.7, 2.6], ["RightUpperArm", Vector3.RIGHT, 1.0, 6.6, 0.5], ["RightLowerArm", Vector3.BACK, 1.0, 6.9, 3.1],
		["LeftHand", Vector3.RIGHT, 16.0, 8.1, 0.0], ["LeftHand", Vector3.BACK, 10.0, 7.2, 1.2], ["RightHand", Vector3.RIGHT, 16.0, 7.7, 1.7], ["RightHand", Vector3.BACK, 10.0, 8.4, 2.9],
		["LeftUpperLeg", Vector3.RIGHT, 1.5, 5.7, 0.8], ["LeftUpperLeg", Vector3.BACK, 2.5, 4.9, 2.4], ["LeftLowerLeg", Vector3.RIGHT, 1.5, 6.6, 1.5],
		["RightUpperLeg", Vector3.RIGHT, 1.5, 5.2, 2.9], ["RightUpperLeg", Vector3.BACK, 2.5, 5.6, 0.1], ["RightLowerLeg", Vector3.RIGHT, 1.5, 7.1, 3.4],
		["LeftFoot", Vector3.RIGHT, 18.0, 7.7, 0.6], ["LeftFoot", Vector3.BACK, 8.0, 6.3, 2.2], ["RightFoot", Vector3.RIGHT, 18.0, 8.3, 2.1], ["RightFoot", Vector3.BACK, 8.0, 7.0, 0.4],
	]
	for m in moves:
		var wave: float = sin(time * m[3] + m[4]) + 0.35 * sin(time * m[3] * 2.3 + m[4] * 1.7)
		var gain := STRUGGLE_GAIN_HEAD if m[0] == "Head" else STRUGGLE_GAIN
		_stack(offsets, m[0], Quaternion(m[1], deg_to_rad(m[2]) * gain * energy * wave))


# Leather straps across her, fixed to the table (with solid colliders so she cannot pull through them), and one over her mouth that stays
# on her head. Then the physical body that keeps her in them.
func _build_straps() -> void:
	var leather := StandardMaterial3D.new()
	leather.albedo_texture = load(KillRoom.TEX % ["brown_leather", "brown_leather", "diff"])
	leather.albedo_color = Color(1.5, 1.2, 0.95)
	leather.roughness = 0.7
	leather.cull_mode = BaseMaterial3D.CULL_DISABLED
	leather.uv1_scale = Vector3(1.0, 1.0, 1.0)
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.55, 0.55, 0.57)
	metal.metallic = 0.9
	metal.roughness = 0.35
	_straps = Node3D.new()
	_straps.name = "Straps"
	get_parent().add_child(_straps)
	var world := skeleton.global_transform
	var at := func(n: String) -> Vector3: return world * skeleton.get_bone_global_pose(bone[n]).origin
	var table_y := global_position.y
	var table_x := home.x
	# (centre, how high her body stands there (the strap clears it by ~1.5 cm), half width of the body, strap width, how far the ends run each
	# side past the body, turn): the forearm straps are turned to cross each forearm square-on, as her arms lie angled away from her body
	var left_forearm: Vector3 = at.call("LeftHand") - at.call("LeftLowerArm")
	var right_forearm: Vector3 = at.call("RightHand") - at.call("RightLowerArm")
	var bands := [
		[at.call("Spine"), 0.265, 0.215, 0.08, 0.205, 0.0],
		[(at.call("LeftLowerArm") + at.call("LeftHand")) * 0.5, 0.128, 0.058, 0.06, 0.09, atan2(left_forearm.x, left_forearm.z)],
		[(at.call("RightLowerArm") + at.call("RightHand")) * 0.5, 0.128, 0.058, 0.06, 0.09, atan2(right_forearm.x, right_forearm.z)],
		[(at.call("LeftUpperLeg") + at.call("LeftLowerLeg") + at.call("RightUpperLeg") + at.call("RightLowerLeg")) * 0.25, 0.246, 0.205, 0.09, 0.21, 0.0],
		[(at.call("LeftLowerLeg") + at.call("LeftFoot") + at.call("RightLowerLeg") + at.call("RightFoot")) * 0.25, 0.188, 0.19, 0.07, 0.225, 0.0],
	]
	for i in bands.size():
		var b: Array = bands[i]
		var centre: Vector3 = b[0]
		var x := table_x if i == 0 or i >= 3 else centre.x          # along her middle, except the arms, which lie out to the sides
		_add_strap(leather, metal, Vector3(x, table_y, centre.z), b[1], b[2], b[3], b[4], b[5])
	# over the mouth: a band round the head at the level of her mouth, riding on the head bone
	var attach := BoneAttachment3D.new()
	attach.name = "MouthStrap"
	attach.bone_name = "Head"
	skeleton.add_child(attach)
	var ring := MeshInstance3D.new()
	ring.mesh = _ring_mesh(0.072, 0.088, 0.04)
	ring.material_override = leather
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var head_rest := skeleton.get_bone_global_rest(bone["Head"])
	ring.transform = head_rest.affine_inverse() * Transform3D(Basis.IDENTITY, HEAD_CENTER_REST + MOUTH_RING_OFFSET)
	attach.add_child(ring)
	_start_body()


const MOUTH_RING_OFFSET := Vector3(0.0, -0.078, 0.007)      # from the middle of her skull to the middle of her mouth (measured on the mesh)


# One strap over her: it comes up from the table on one side, follows the curve of her body over the top and goes back down the other
# side, with a buckle on one end. Solid colliders (invisible) hold the same shape, so her body cannot pull up through it.
func _add_strap(leather: Material, metal: Material, at_table: Vector3, height: float, half: float, width: float, run: float, turn: float = 0.0) -> void:
	var pivot := Node3D.new()
	pivot.position = at_table
	pivot.rotation.y = turn
	_straps.add_child(pivot)
	var points: Array[Vector2] = []
	points.append(Vector2(-(half + run), 0.004))
	points.append(Vector2(-(half + 0.02), 0.004))
	var steps := 18
	for k in steps + 1:
		var theta := PI - PI * float(k) / steps
		points.append(Vector2((half + 0.004) * cos(theta), height * pow(sin(theta), 0.55) + 0.004))
	points.append(Vector2(half + 0.02, 0.004))
	points.append(Vector2(half + run, 0.004))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var along := 0.0
	for k in points.size() - 1:
		var p0 := points[k]
		var p1 := points[k + 1]
		var tangent := (p1 - p0).normalized()
		var normal := Vector3(-tangent.y, tangent.x, 0.0)
		var u0 := along / 0.2
		along += p0.distance_to(p1)
		var u1 := along / 0.2
		var corners := [
			[Vector3(p0.x, p0.y, -width * 0.5), Vector2(u0, 0.0)], [Vector3(p1.x, p1.y, -width * 0.5), Vector2(u1, 0.0)],
			[Vector3(p1.x, p1.y, width * 0.5), Vector2(u1, 1.0)], [Vector3(p0.x, p0.y, width * 0.5), Vector2(u0, 1.0)],
		]
		for i in [0, 1, 2, 0, 2, 3]:
			st.set_normal(normal)
			st.set_uv(corners[i][1])
			st.add_vertex(corners[i][0])
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = leather
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pivot.add_child(mi)
	# the buckle: a small steel plate on the right-hand end
	var buckle := MeshInstance3D.new()
	var plate := BoxMesh.new()
	plate.size = Vector3(0.04, 0.012, width + 0.012)
	buckle.mesh = plate
	buckle.material_override = metal
	buckle.position = Vector3(half + run * 0.55, 0.01, 0.0)
	pivot.add_child(buckle)
	# the colliders: across the top, and down each side
	var solid := StaticBody3D.new()
	solid.name = "StrapSolid"
	var top := CollisionShape3D.new()
	var top_box := BoxShape3D.new()
	top_box.size = Vector3(half * 2.0 + 0.02, 0.008, width)
	top.shape = top_box
	top.position = Vector3(0.0, height + 0.004, 0.0)
	solid.add_child(top)
	for side in [-1.0, 1.0]:
		var wall := CollisionShape3D.new()
		var wall_box := BoxShape3D.new()
		wall_box.size = Vector3(0.008, height, width)
		wall.shape = wall_box
		wall.position = Vector3(side * (half + 0.012), height * 0.5, 0.0)
		solid.add_child(wall)
	pivot.add_child(solid)


# An elliptical band standing on its edge, one sheet drawn from both sides: half widths `rx` (across) and `rz` (front to back), `height` tall.
static func _ring_mesh(rx: float, rz: float, height: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sides := 40
	for k in sides:
		var a0 := TAU * k / sides
		var a1 := TAU * (k + 1) / sides
		var p0 := Vector3(cos(a0) * rx, 0.0, sin(a0) * rz)
		var p1 := Vector3(cos(a1) * rx, 0.0, sin(a1) * rz)
		var n0 := -Vector3(cos(a0) / rx, 0.0, sin(a0) / rz).normalized()
		var n1 := -Vector3(cos(a1) / rx, 0.0, sin(a1) / rz).normalized()
		var up := Vector3(0.0, height * 0.5, 0.0)
		var quad := [p0 + up, p1 + up, p1 - up, p0 - up]
		var normals := [n0, n1, n1, n0]
		var uvs := [Vector2(float(k) / sides * 3.0, 0.0), Vector2(float(k + 1) / sides * 3.0, 0.0), Vector2(float(k + 1) / sides * 3.0, 1.0), Vector2(float(k) / sides * 3.0, 1.0)]
		for i in [0, 1, 2, 0, 2, 3]:
			st.set_normal(normals[i])
			st.set_uv(uvs[i])
			st.add_vertex(quad[i])
	return st.commit()


# ---- the physical body ---------------------------------------------------------------------------------------------------------------------

func _start_body() -> void:
	var rest := func(n: String) -> Vector3: return rest_origin[bone[n]]
	var specs := []
	var add := func(from_bone: String, end_point: Vector3, radius: float, lift := 0.0) -> void:
		var i: int = bone[from_bone]
		var inverse := skeleton.get_bone_global_rest(i).affine_inverse()
		specs.append([i, inverse * end_point, radius, inverse.basis * Vector3(0.0, 0.0, lift)])
	# radii and lifts are fitted to her measured body, so each capsule sits just under the strap that crosses it
	add.call("Hips", rest.call("Spine"), 0.10)
	add.call("Spine", rest.call("Chest"), 0.115, 0.05)
	add.call("Chest", rest.call("Neck"), 0.11, 0.05)
	add.call("Head", rest.call("Head") + Vector3(0.0, 0.17, 0.02), 0.085)
	for side in ["Left", "Right"]:
		add.call(side + "UpperArm", rest.call(side + "LowerArm"), 0.04)
		add.call(side + "LowerArm", rest.call(side + "Hand"), 0.024)
		var forearm: Vector3 = (rest.call(side + "Hand") - rest.call(side + "LowerArm")).normalized()
		add.call(side + "Hand", rest.call(side + "Hand") + forearm * 0.09, 0.03)
		add.call(side + "UpperLeg", rest.call(side + "LowerLeg"), 0.085, -0.01)
		add.call(side + "LowerLeg", rest.call(side + "Foot"), 0.058, -0.01)
		add.call(side + "Foot", rest.call(side + "Toes"), 0.04)
	body = RagdollBody.new()
	body.name = "StrappedBody"
	get_parent().add_child(body)
	body.setup(skeleton, specs)
	body.floor_y = global_position.y + 0.002
	body.read_targets()
	body.snap()


# ---- what the rest of the game asks of her -----------------------------------------------------------------------------------------

# A fist landed at `point` moving at `velocity` (both in world space).
func hit(point: Vector3, velocity: Vector3, strength: float = 1.0) -> void:
	hits += 1
	hit_taken.emit(point, strength)
	if strapped:
		var in_model := skeleton.global_transform.affine_inverse()
		var arm: Vector3 = in_model * point - in_model * _head_pivot_world()
		var spin := arm.cross(in_model.basis * velocity) * SPIN_GAIN * NECK_FREEDOM
		if spin.length() > MAX_SPIN:
			spin = spin.normalized() * MAX_SPIN
		hit_velocity += spin                         # her head snaps round, and she strains harder for a moment
		struggle = minf(2.0, struggle + 0.7 + strength)
		if body != null:
			body.push(point, velocity, strength)
		return
	if fall_state != Fall.STANDING:
		return                                       # already down: it counts, but there is nothing left to knock
	var to_model := skeleton.global_transform.affine_inverse()
	var r: Vector3 = to_model * point - to_model * _head_pivot_world()
	var v: Vector3 = to_model.basis * velocity
	var spin := r.cross(v) * SPIN_GAIN * NECK_FREEDOM   # a push off the neck's axis is a torque on the head
	if spin.length() > MAX_SPIN:
		spin = spin.normalized() * MAX_SPIN
	hit_velocity += spin
	stun = 0.55 + 0.45 * clampf(strength, 0.0, 1.0)
	move_target = null                              # a punch stops her in her tracks
	pause_timer = maxf(pause_timer, 1.5 + strength)
	damage += DAMAGE_PER_PUNCH * strength * strength
	if damage >= KNOCKDOWN_AT and clips.has(FALL_CLIP):
		_knock_down(velocity, strength)


# She goes over, backwards, in the direction the punch was travelling, and stays down for longer the harder it was.
func _knock_down(velocity: Vector3, strength: float) -> void:
	fall_state = Fall.FALLING
	knockdowns += 1
	lie_timer = 1.5 + 3.5 * clampf(strength, 0.0, 1.0)
	fall_rate = lerpf(FALL_RATE_MIN, FALL_RATE_MAX, clampf(strength, 0.0, 1.0))
	var push := Vector3(velocity.x, 0.0, velocity.z)
	if push.length() < 0.2 and _has_target():
		push = global_position - target.global_position
		push.y = 0.0
	if push.length() > 0.001:
		fall_yaw = atan2(-push.x, -push.z)          # the fall clip goes over backwards: her back must face the way she is pushed
	else:
		fall_yaw = rotation.y


# Walk to a point (world space). She turns to it first, then sets off.
func walk_to(point: Vector3) -> void:
	move_target = point
	pause_timer = 0.0


func head_center() -> Vector3:
	return skeleton.global_transform * skeleton.get_bone_global_pose(bone["Head"]) * head_center_local


# The direction her head points (world space).
func head_forward() -> Vector3:
	return (skeleton.global_transform.basis * skeleton.get_bone_global_pose(bone["Head"]).basis * Basis(rest_gq[bone["Head"]].inverse()) * Vector3.BACK).normalized()


# The direction an eye points (world space). side: "Left" or "Right".
func eye_forward(side: String) -> Vector3:
	var b: int = bone[side + "Eye"]
	return (skeleton.global_transform.basis * skeleton.get_bone_global_pose(b).basis * Basis(rest_gq[b].inverse()) * Vector3.BACK).normalized()


func eye_position(side: String) -> Vector3:
	return skeleton.global_transform * skeleton.get_bone_global_pose(bone[side + "Eye"]).origin


func _head_pivot_world() -> Vector3:
	return skeleton.global_transform * skeleton.get_bone_global_pose(bone["Head"]).origin   # where the skull sits on the neck


# ---- the frame ------------------------------------------------------------------------------------------------------------------------

func update(dt: float) -> void:
	if skeleton == null:
		return
	dt = clampf(dt, 0.0, 0.05)
	time += dt
	_update_attention(dt)
	_update_reaction(dt)
	_update_movement(dt)
	_update_clip(dt)

	var offsets: Array[Quaternion] = []
	offsets.resize(skeleton.get_bone_count())
	offsets.fill(Quaternion.IDENTITY)
	var hips_move := _add_clip(offsets)
	if strapped:
		struggle = maxf(0.0, struggle - dt * 0.9)
		hips_move = _lie_on_back(offsets, hips_move)
		_add_struggle(offsets)
	_add_look(offsets, dt)
	_add_reaction(offsets)

	for i in offsets.size():
		if body != null:
			# the physical body poses bones by their global pose, which also moves their local position: start each frame from the rest ones
			skeleton.set_bone_pose_position(i, rest_local_origin[i])
			skeleton.set_bone_pose_scale(i, Vector3.ONE)
		_pose_bone(i, offsets[i])
	skeleton.set_bone_pose_position(bone["Hips"], rest_local_origin[bone["Hips"]] + hips_move)
	_aim_eyes(offsets, dt)
	if body != null:
		body.read_targets()
		body.pose_skeleton()


func _pose_bone(i: int, q: Quaternion) -> void:
	# A rotation q about model-space axes, in this bone's own frame: its rest orientation conjugated by q.
	skeleton.set_bone_pose_rotation(i, rest_q[i] * (rest_gq[i].inverse() * q * rest_gq[i]))


static func rotation_from_vector(v: Vector3) -> Quaternion:
	var a := v.length()
	if a < 1e-6:
		return Quaternion.IDENTITY
	return Quaternion(v / a, a)


func _stack(offsets: Array[Quaternion], bone_name: String, q: Quaternion) -> void:
	var i: int = bone[bone_name]
	offsets[i] = offsets[i] * q


func _update_attention(dt: float) -> void:
	if stun > 0.0:
		stun = maxf(0.0, stun - dt)
		look_weight = maxf(0.0, look_weight - dt * 10.0)
	else:
		look_weight = minf(1.0, look_weight + dt * ATTENTION_RETURN)
	saccade_timer -= dt
	if saccade_timer <= 0.0:
		saccade_timer = rng.randf_range(0.7, 2.4)
		saccade = Vector2(rng.randf_range(-0.045, 0.045), rng.randf_range(-0.03, 0.03))


func _update_reaction(dt: float) -> void:
	if fall_state == Fall.STANDING:
		damage = maxf(0.0, damage - DAMAGE_FADE * dt)
	var k := pow(TAU * SPRING_HZ, 2.0)
	var c := 2.0 * SPRING_DAMPING * TAU * SPRING_HZ
	hit_velocity += (-k * hit_angle - c * hit_velocity) * dt
	hit_angle += hit_velocity * dt
	if hit_angle.length() > MAX_REACTION:
		hit_angle = hit_angle.normalized() * MAX_REACTION
		hit_velocity *= 0.5
	if hit_angle.length() < 1e-5 and hit_velocity.length() < 1e-4:
		hit_angle = Vector3.ZERO
		hit_velocity = Vector3.ZERO


func _add_look(offsets: Array[Quaternion], dt: float) -> void:
	var yaw := 0.0
	var pitch := 0.0
	if target != null and is_instance_valid(target) and target.is_inside_tree():
		var to_target: Vector3 = skeleton.global_transform.affine_inverse() * target.global_position - _eyes_rest_middle()
		yaw = clampf(atan2(to_target.x, to_target.z), -MAX_YAW, MAX_YAW)
		pitch = clampf(atan2(to_target.y, Vector2(to_target.x, to_target.z).length()), -MAX_PITCH_DOWN, MAX_PITCH_UP)
	# a little idle drift so the head is never perfectly still
	yaw += 0.02 * sin(time * 0.53)
	pitch += 0.015 * sin(time * 0.71 + 2.0)
	var follow := 1.0 - exp(-HEAD_RATE * dt)
	look_yaw += (yaw - look_yaw) * follow
	look_pitch += (pitch - look_pitch) * follow
	# pitch first about the model's own X axis (looking up is a negative turn about it), then yaw about the vertical
	var aim := Quaternion(Vector3.UP, look_yaw) * Quaternion(Vector3.RIGHT, -look_pitch)
	# The clip already holds her spine, neck and head in some pose (and swings the pelvis and spine as she walks). Ask the neck and head
	# only for what is still needed to point the head exactly where `aim` says, however the clip has them: the neck takes its share
	# and the head takes whatever is left, so the gaze neither bobs with her stride nor drifts with her idle posture.
	var below := offsets[bone["Hips"]] * offsets[bone["Spine"]] * offsets[bone["Chest"]] * offsets[bone["UpperChest"]]
	var clip_neck := offsets[bone["Neck"]]
	var clip_head := offsets[bone["Head"]]
	var needed := (below * clip_neck * clip_head).inverse() * aim
	if needed.w < 0.0:
		needed = -needed
	var neck_turn := Quaternion.IDENTITY.slerp(needed, LOOK_SHARE["Neck"])
	var head_turn := clip_head.inverse() * neck_turn.inverse() * (below * clip_neck).inverse() * aim
	# look_weight blends from "however the clip holds the head" (0: not watching, or lying on the floor) to "exactly at the target" (1)
	_stack(offsets, "Neck", Quaternion.IDENTITY.slerp(neck_turn, look_weight))
	_stack(offsets, "Head", Quaternion.IDENTITY.slerp(head_turn, look_weight))


func _add_reaction(offsets: Array[Quaternion]) -> void:
	for part in REACTION_SHARE:
		_stack(offsets, part, rotation_from_vector(hit_angle * REACTION_SHARE[part]))


# ---- clips ------------------------------------------------------------------------------------------------------------------------------

# assets/woman/clips.json is written by tools/bake_clips.gd: for each clip, per frame, how far each animated bone is turned from its
# parent's pose (as a quaternion), and how far the hips travel.
func _load_clips() -> void:
	if not FileAccess.file_exists(CLIPS):
		push_warning("no baked clips at " + CLIPS)
		return
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CLIPS))
	for bone_name in data.bones:
		clip_bones.append(bone[bone_name])
	for name_in_file in data.clips:
		var c: Dictionary = data.clips[name_in_file]
		var frames := int(c.frames)
		var rot: Array = []
		for f in frames:
			var row: Array = c.rot[f]
			var qs: Array[Quaternion] = []
			for k in clip_bones.size():
				qs.append(Quaternion(row[k * 4], row[k * 4 + 1], row[k * 4 + 2], row[k * 4 + 3]).normalized())
			rot.append(qs)
		var hips: Array[Vector3] = []
		for h in c.hips:
			hips.append(Vector3(h[0], h[1], h[2]))
		clips[name_in_file] = {"frames": frames, "length": float(c.length), "loop": bool(c.loop), "speed": float(c.speed),
			"fps": float(data.fps), "rot": rot, "hips": hips}
	if clips.has("Walk_Loop") and clips["Walk_Loop"].speed > 0.1:
		walk_speed = clips["Walk_Loop"].speed


func _sample(name_of_clip: String, t: float) -> Dictionary:
	var c: Dictionary = clips[name_of_clip]
	var f: float = t * c.fps
	var i0 := int(floor(f))
	var u := f - float(i0)
	var n: int = c.frames
	var i1 := i0 + 1
	if c.loop:
		i0 = posmod(i0, n)
		i1 = posmod(i1, n)
	else:
		i0 = clampi(i0, 0, n - 1)
		i1 = clampi(i1, 0, n - 1)
	var a: Array = c.rot[i0]
	var b: Array = c.rot[i1]
	var out: Array[Quaternion] = []
	for k in a.size():
		out.append(a[k].slerp(b[k], u))
	return {"rot": out, "hips": c.hips[i0].lerp(c.hips[i1], u)}


func _advance(name_of_clip: String, t: float, by: float) -> float:
	var c: Dictionary = clips[name_of_clip]
	t += by
	return fposmod(t, c.length) if c.loop else minf(t, c.length)


func _update_clip(dt: float) -> void:
	if clips.is_empty():
		return
	if strapped:
		if clip_name != "Idle_Loop":
			clip_name = "Idle_Loop"
			clip_time = 0.0
			fade = 1.0
		clip_time = _advance(clip_name, clip_time, dt)
		return
	if fall_state != Fall.STANDING and clips.has(FALL_CLIP):
		_update_fall_clip(dt)
		return
	var moving := speed > 0.05
	var stepping := absf(turn_velocity) > deg_to_rad(14.0)
	var wanted := "Walk_Loop" if ((moving or stepping) and clips.has("Walk_Loop")) else "Idle_Loop"
	if wanted != clip_name:
		fade_name = clip_name
		fade_time = clip_time
		fade_rate = clip_rate
		fade = 0.0
		fade_length = FADE_TIME
		clip_name = wanted
		clip_time = 0.0
	if moving:
		clip_rate = clampf(speed / walk_speed, 0.5, 1.4)     # her feet keep up with the ground whatever her speed
	else:
		clip_rate = TURN_STEP_RATE if stepping else 1.0
	clip_time = _advance(clip_name, clip_time, dt * clip_rate)
	if fade < 1.0:
		fade_time = _advance(fade_name, fade_time, dt * fade_rate)
		fade = minf(1.0, fade + dt / fade_length)


# Falling plays the fall clip forwards, lying holds its last frame, getting up plays it backwards and then goes back to idling.
func _update_fall_clip(dt: float) -> void:
	var length: float = clips[FALL_CLIP].length
	if clip_name != FALL_CLIP:
		fade_name = clip_name
		fade_time = clip_time
		fade_rate = clip_rate
		fade = 0.0
		fade_length = 0.06
		clip_name = FALL_CLIP
		clip_time = FALL_START
	clip_rate = 1.0
	match fall_state:
		Fall.FALLING:
			clip_time = minf(clip_time + dt * fall_rate, length)
			if clip_time >= length - 0.001:
				fall_state = Fall.LYING
		Fall.LYING:
			lie_timer -= dt
			if lie_timer <= 0.0:
				fall_state = Fall.GETTING_UP
		Fall.GETTING_UP:
			clip_time = maxf(clip_time - dt * GET_UP_RATE, FALL_START)
			if clip_time <= FALL_START + 0.001:
				fall_state = Fall.STANDING
				damage = 0.0
				pause_timer = maxf(pause_timer, 2.0)
				fade_name = FALL_CLIP
				fade_time = 0.0
				fade_rate = 0.0
				fade = 0.0
				fade_length = 0.3
				clip_name = "Idle_Loop"
				clip_time = 0.0
	if fade < 1.0:
		fade_time = _advance(fade_name, fade_time, dt * fade_rate)
		fade = minf(1.0, fade + dt / fade_length)


# Sets each animated bone's offset from the clip (blending from the previous one) and returns how far the hips travel.
func _add_clip(offsets: Array[Quaternion]) -> Vector3:
	if clips.is_empty():
		return Vector3.ZERO
	var now := _sample(clip_name, clip_time)
	var rot: Array = now.rot
	var hips: Vector3 = now.hips
	if fade < 1.0 and fade_name != "":
		var before := _sample(fade_name, fade_time)
		var w := smoothstep(0.0, 1.0, fade)
		for k in rot.size():
			rot[k] = before.rot[k].slerp(rot[k], w)
		hips = before.hips.lerp(hips, w)
	for k in clip_bones.size():
		offsets[clip_bones[k]] = rot[k]
	return hips


# ---- walking ----------------------------------------------------------------------------------------------------------------------------

func _has_target() -> bool:
	return target != null and is_instance_valid(target) and target.is_inside_tree()


# Decides where she is going and how she is turning, then moves her body (this node). Her parent is expected to be unrotated.
func _update_movement(dt: float) -> void:
	var player := Vector3.ZERO
	var watching := _has_target()
	if watching:
		player = Vector3(target.global_position.x, global_position.y, target.global_position.z)
	pause_timer = maxf(0.0, pause_timer - dt)
	var staggered := stun > 0.0
	if move_target == null and wander and pause_timer <= 0.0 and not staggered:
		move_target = _pick_wander_target(player if watching else null)
		if move_target == null:
			pause_timer = 1.0

	var desired_speed := 0.0
	var desired_turn := 0.0
	if fall_state != Fall.STANDING:
		stun = maxf(stun, 0.2)
		staggered = true
		move_target = null
		turning_to_face = false
		if fall_state == Fall.FALLING and clip_time < 0.9:
			desired_turn = clampf(wrapf(fall_yaw - rotation.y, -PI, PI) * 12.0, -deg_to_rad(720.0), deg_to_rad(720.0))
	elif move_target != null:
		var to_goal: Vector3 = move_target - global_position
		to_goal.y = 0.0
		var distance := to_goal.length()
		if distance < 0.08:
			move_target = null
			pause_timer = rng.randf_range(2.0, 5.0)
		else:
			var error := wrapf(atan2(to_goal.x, to_goal.z) - rotation.y, -PI, PI)
			desired_turn = clampf(error * 5.0, -TURN_RATE, TURN_RATE)
			if absf(error) < deg_to_rad(35.0):                       # turn on the spot first, walk once she is facing the way
				desired_speed = minf(walk_speed, 0.2 + distance * 1.5)
	elif watching:
		# standing: turn the body to face the player once they have moved well round to the side
		var to_player := player - global_position
		if to_player.length() > 0.05:
			var error := wrapf(atan2(to_player.x, to_player.z) - rotation.y, -PI, PI)
			if turning_to_face and absf(error) < FACE_DONE:
				turning_to_face = false
			elif not turning_to_face and absf(error) > FACE_AFTER:
				turning_to_face = true
			if turning_to_face and body_turns:
				desired_turn = clampf(error * 4.0, -TURN_RATE, TURN_RATE)
	if staggered:
		desired_speed = 0.0
	turn_velocity = move_toward(turn_velocity, desired_turn, TURN_ACCEL * dt)
	if fall_state == Fall.FALLING:
		turn_velocity = desired_turn                  # she is thrown round at once by the punch
	speed = move_toward(speed, desired_speed, WALK_ACCEL * (4.0 if staggered else 1.0) * dt)
	rotation.y += turn_velocity * dt
	global_position += Vector3(sin(rotation.y), 0.0, cos(rotation.y)) * speed * dt


func _pick_wander_target(player: Variant) -> Variant:
	for attempt in 10:
		var angle := rng.randf() * TAU
		var point := home + Vector3(cos(angle), 0.0, sin(angle)) * rng.randf_range(0.4, WANDER_RADIUS)
		if point.distance_to(global_position) < 0.4:
			continue
		if player != null:
			var here := Vector2(global_position.x, global_position.z)
			var there := Vector2(point.x, point.z)
			var at := Vector2(player.x, player.z)
			if at.distance_to(there) < KEEP_AWAY:
				continue
			if at.distance_to(Geometry2D.get_closest_point_to_segment(at, here, there)) < KEEP_AWAY * 0.8:
				continue        # and the walk there must not brush past them either
		return point
	return null


func _eyes_rest_middle() -> Vector3:
	return (rest_origin[bone["LeftEye"]] + rest_origin[bone["RightEye"]]) * 0.5


# Each eye turns on its own to look at the target from where it actually is, so they converge as a person's do up close.
func _aim_eyes(offsets: Array[Quaternion], dt: float) -> void:
	var head_total := Quaternion.IDENTITY
	for bone_name in ["Hips", "Spine", "Chest", "UpperChest", "Neck", "Head"]:
		head_total = head_total * offsets[bone[bone_name]]
	var follow := 1.0 - exp(-EYE_RATE * dt)
	var has_target := target != null and is_instance_valid(target) and target.is_inside_tree()
	var target_model := Vector3.ZERO
	if has_target:
		target_model = skeleton.global_transform.affine_inverse() * target.global_position
	for eye in ["LeftEye", "RightEye"]:
		var b: int = bone[eye]
		var wanted := Quaternion.IDENTITY
		if has_target and look_weight > 0.001:
			var from: Vector3 = skeleton.get_bone_global_pose(b).origin
			var direction := (target_model - from).normalized()
			var aim := Quaternion(Vector3.BACK, direction)                               # straight ahead -> at the target
			aim = rotation_from_vector(Vector3.UP * saccade.x * look_weight) * rotation_from_vector(Vector3.LEFT * saccade.y * look_weight) * aim
			var in_head := head_total.inverse() * aim                                    # relative to where the head points
			if in_head.w < 0.0:
				in_head = -in_head                                                        # same turn, the short way round
			if in_head.get_angle() > MAX_EYE_ANGLE:
				in_head = Quaternion(in_head.get_axis(), MAX_EYE_ANGLE)
			wanted = Quaternion.IDENTITY.slerp(in_head, look_weight)
		eye_q[eye] = eye_q[eye].slerp(wanted, follow)
		_pose_bone(b, eye_q[eye])
