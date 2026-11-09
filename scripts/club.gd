# The club above the basement, up the stairs and through the second heavy door: a dark neon strip club laid out in rooms. A foyer with a
# cashier's counter; the main hall, with a stage and three poles at its north end and a lit dance floor under a truss of moving lights and a
# strobe at its south end; a bar off the hall; a lounge of booths and sofas; and a VIP corridor with three private rooms.
#
# Made for the Quest at 36 fps (SpaceWarp to 72):
# - Every room is a zone: its own node, with its own meshes and lights. Only the zones that can be seen from the one you are in are shown,
#   worked out once from the doorways (a zone is seen if a straight line reaches it through every doorway on the way). A hidden zone costs
#   nothing, its lights included, and in this renderer every light that reaches a mesh is another pass over it.
# - Each zone's geometry is batched by material, so a room is a handful of draw calls.
# - Few real lights, none casting shadows, each kept short so it only reaches its own room. The colour comes from the neon, which is
#   unshaded and costs no lighting at all.
# - It is built off the main thread while you are on the stairs (main.gd), so building it never holds up a frame.
class_name Club
extends Node3D

const PINK := Color(1.0, 0.1, 0.6)
const CYAN := Color(0.1, 0.85, 1.0)
const PURPLE := Color(0.6, 0.2, 1.0)
const RED := Color(1.0, 0.06, 0.12)
const ROSE := Color(1.0, 0.25, 0.45)
const AMBER := Color(1.0, 0.55, 0.15)

# ---- the floor plan, in metres (x and z as in the basement below; heights from the club floor) ------------------------------------------
# The plan below is in "plan metres". The club is built SCALE times as big on the floor: the plan's points are moved out from the stairwell's
# door (wx, wz), so the stairs still come out at the foyer, and the things that stretch (rooms, the long openings, the stage, the bar, the truss)
# are drawn between the moved points. Nothing else is scaled: a door, a ceiling, a step, a counter's height and depth, a stool, a table, a sofa, a
# neon tube, a pole and a sign are the size they are in real life (it is a person's club), they are only put further apart.
const SCALE := 1.3
const PIVOT_X := KillRoom.HALL_X1         # the wall the stairs' door is in...
const PIVOT_Z := (KillRoom.STAIR_DOOR_Z0 + KillRoom.STAIR_DOOR_Z1) * 0.5      # ...and the middle of that door
const FLOOR_Y := KillRoom.STAIR_RISE      # the club floor: the top of the stairs
const WEST := KillRoom.HALL_X0
const EAST := KillRoom.HALL_X1            # the wall the door from the stairs is in
const NORTH := KillRoom.HALL_ZN
const SOUTH := KillRoom.Z1
const SPLIT_Z := -3.0                     # the main hall is two zones with nothing between: the stage end and the dance floor end
const HALL_H := 5.5
const DOOR_H := 2.4
const WALL_SOLID_H := 3.0                 # how high the walls are solid to you
const STAGE_H := 0.6
const ENTRY_Z1 := SOUTH + 4.0             # the entrance foyer sticks out of the hall's south wall this far
# the furthest the club reaches in the world (west and north, and south), for the limits on where you can walk
const WORLD_MIN := Vector2(PIVOT_X + (WEST - PIVOT_X) * SCALE, PIVOT_Z + (NORTH - PIVOT_Z) * SCALE)
const WORLD_MAX_Z := PIVOT_Z + (ENTRY_Z1 - PIVOT_Z) * SCALE

# name -> [x0, z0, x1, z1, ceiling height, floor material, wall material]
const ZONES := {
	"foyer": [8.0, NORTH, EAST, -5.6, 3.0, "rubber", "brick"],
	"bar": [8.0, -5.6, EAST, SOUTH, 3.2, "rubber", "brick"],
	"stage": [-5.0, NORTH, 8.0, SPLIT_Z, HALL_H, "rubber", "brick"],
	"dance": [-5.0, SPLIT_Z, 8.0, SOUTH, HALL_H, "rubber", "brick"],
	"entry": [5.0, SOUTH, 9.2, ENTRY_Z1, 3.0, "rubber", "brick"],
	"vip": [WEST, -5.2, -5.0, -3.6, 2.8, "carpet", "velvet"],
	"room1": [WEST, NORTH, -12.7, -5.2, 2.8, "carpet", "panel"],
	"room2": [-12.7, NORTH, -8.85, -5.2, 2.8, "carpet", "panel"],
	"room3": [-8.85, NORTH, -5.0, -5.2, 2.8, "carpet", "panel"],
	"lounge": [WEST, -3.6, -5.0, SOUTH, 3.2, "carpet", "panel"],
	# the top of the stairwell: built by the basement, not here, but you look into the club from it (the only zone that is not moved by SCALE)
	"stairs": [EAST, KillRoom.HALL_ZN, KillRoom.STAIR_X1, KillRoom.HALL_ZS, 0.0, "", ""],
}
# the gaps in the walls: [zone, zone, x0, z0, x1, z1, height, neon round it (or null)]
const DOORWAYS := [
	# the doorway from the stairs is the stairwell's heavy door (not moved by SCALE)
	["stairs", "foyer", EAST, KillRoom.STAIR_DOOR_Z0, EAST, KillRoom.STAIR_DOOR_Z1, KillRoom.STAIR_DOOR_H, null],
	["foyer", "stage", 8.0, -7.4, 8.0, -6.0, DOOR_H, PINK],
	["bar", "stage", 8.0, -4.2, 8.0, SPLIT_Z, 2.8, null],      # the bar is open to the hall along most of its side
	["bar", "dance", 8.0, SPLIT_Z, 8.0, 1.6, 2.8, null],
	["vip", "stage", -5.0, -5.2, -5.0, -3.6, DOOR_H, RED],
	["lounge", "dance", -5.0, -0.6, -5.0, 1.4, DOOR_H, PURPLE],
	["vip", "room1", -15.2, -5.2, -14.0, -5.2, DOOR_H, ROSE],
	["vip", "room2", -11.4, -5.2, -10.2, -5.2, DOOR_H, ROSE],
	["vip", "room3", -7.6, -5.2, -6.4, -5.2, DOOR_H, ROSE],
	["stage", "dance", -5.0, SPLIT_Z, 8.0, SPLIT_Z, HALL_H, null],
	["dance", "entry", 5.3, SOUTH, 6.7, SOUTH, DOOR_H, CYAN],
]
# A point of the plan, in the world.
static func wx(x: float) -> float:
	return PIVOT_X + (x - PIVOT_X) * SCALE


static func wz(z: float) -> float:
	return PIVOT_Z + (z - PIVOT_Z) * SCALE


static func wv(x: float, z: float) -> Vector2:
	return Vector2(wx(x), wz(z))


static func w3(x: float, y: float, z: float) -> Vector3:
	return Vector3(wx(x), y, wz(z))


# The zones as they are in the world (the rooms are bigger than the plan; the stairs are as they are).
static func world_zones() -> Dictionary:
	var out := {}
	for zone in ZONES:
		var z: Array = (ZONES[zone] as Array).duplicate()
		if zone != "stairs":
			z[0] = wx(z[0])
			z[1] = wz(z[1])
			z[2] = wx(z[2])
			z[3] = wz(z[3])
		out[zone] = z
	return out


# The doorways as they are in the world: a real door (DOOR_H high) is as wide as it was, wherever it has moved to; the long openings between
# rooms stretch with the rooms.
static func world_doorways() -> Array:
	var out := []
	for d in DOORWAYS:
		var e: Array = (d as Array).duplicate()
		if d[0] != "stairs":
			var a := wv(d[2], d[3])
			var c := wv(d[4], d[5])
			if is_equal_approx(d[6], DOOR_H):
				var mid := (a + c) * 0.5
				var half := Vector2(d[4] - d[2], d[5] - d[3]) * 0.5
				a = mid - half
				c = mid + half
			e[2] = a.x
			e[3] = a.y
			e[4] = c.x
			e[5] = c.y
		out.append(e)
	return out


# Each zone's meshes are on a render layer of their own (2, 4, 8... in the order above), and each light only lights its own zone (and layer
# 1: your hands, and whatever you carry). A light that reached into the next room would draw that room's meshes all over again.
const LAYERS := 0x7FE                     # all the club's layers (one for each of the 11 zones): the stairwell's lamps leave them alone
const VIS_DEPTH := 4                      # how many doorways in a row a zone can be seen through
const VIS_SAMPLES := 11                   # points tried along each doorway when looking for a line through them

# ---- the strobe (it fires in bursts, one frame lit per flash) --------------------------------------------------------------------------
const STROBE_HZ := 8.0
const STROBE_BURST := 2.4                 # seconds
const STROBE_GAP := Vector2(9.0, 18.0)    # seconds between bursts, at random

const TEX := "res://assets/%s/textures/%s/%s_%s.jpg"
const MODEL := "res://assets/club/models/%s/%s.gltf"
const SEATING := "res://assets/club/models/club_seating/%s.glb"      # the stool and the booth, modelled in Blender (tools/make_club_seating.py)
# name -> [folder, texture id, tile size in metres, tint]
const MATERIALS := {
	"brick": ["club", "dark_brick_wall", 2.2, Color(0.7, 0.66, 0.72)],
	"rubber": ["club", "rubber_tiles", 2.0, Color(0.85, 0.85, 0.9)],
	"carpet": ["club", "dirty_carpet", 1.6, Color(0.42, 0.2, 0.48)],
	"panel": ["club", "dark_paneled_wood", 1.2, Color(0.62, 0.4, 0.58)],
	"velvet": ["club", "velour_velvet", 1.2, Color(0.7, 0.25, 0.45)],
	"seating": ["club", "seating_atlas", 1.0, Color.WHITE],     # the stools and booths: leather, chrome and lacquer in one texture set (tools/make_club_atlas.py)
	"veneer": ["club", "flamed_black_veneer", 1.5, Color(0.75, 0.75, 0.75)],
	"planks": ["club", "black_painted_planks", 2.0, Color(0.8, 0.8, 0.8)],
	"ceiling": ["room", "concrete_layers_02", 2.0, Color(0.13, 0.12, 0.15)],
}

const LED_SHADER := """
shader_type spatial;
render_mode unshaded;
uniform float flash = 0.0;
uniform vec3 color_a : source_color = vec3(1.0, 0.1, 0.6);
uniform vec3 color_b : source_color = vec3(0.1, 0.85, 1.0);
uniform float speed = 1.6;
void fragment() {
	vec2 cell = floor(UV);
	vec2 f = fract(UV);
	float h = fract(sin(cell.x * 12.9898 + cell.y * 78.233) * 43.5453);
	float wave = sin(TIME * speed - (cell.x * 0.7 + cell.y * 0.45) + h * 2.0);
	float lit = smoothstep(0.45, 1.0, wave);
	vec3 col = mix(color_a, color_b, step(0.5, h)) * (0.035 + 0.55 * lit);
	vec2 w = fwidth(UV);
	vec2 inside = smoothstep(vec2(0.05) - w, vec2(0.05) + w, f) * smoothstep(vec2(0.05) - w, vec2(0.05) + w, 1.0 - f);
	ALBEDO = col * inside.x * inside.y + vec3(flash);
}
"""
const BEAM_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;
uniform vec3 color : source_color = vec3(1.0);
uniform float strength = 0.2;
void fragment() {
	float fade = 1.0 - UV.y;
	float face = abs(dot(NORMAL, VIEW));
	ALBEDO = color * strength * fade * fade * face * face;
}
"""

class Batch:
	var st := SurfaceTool.new()
	var material: Material
	func _init(m: Material) -> void:
		material = m
		st.begin(Mesh.PRIMITIVE_TRIANGLES)

var collision_root: Node3D
var environment: Environment             # the club's fog and ambient light (main.gd swaps it in when you are up here)
var pvs := {}                            # zone -> the zones that can be seen from it
var zones_w := {}                        # ZONES in the world
var doorways_w: Array = []               # DOORWAYS in the world
var current_zone := ""
var built := false
var _zones := {}                         # zone -> its node
var _batches := {}                       # "zone/material" -> Batch
var _seats := {}                         # "zone/model" -> the transforms of every stool (or booth) of that model in that zone
var _seat_meshes := {}                   # model -> its mesh
var _materials := {}
var _noise := FastNoiseLite.new()

# animated things
var _t := 0.0
var _movers: Array = []                  # [pivot (turns), head (tilts), phase, base yaw]
var _stage_spots: Array[SpotLight3D] = []
var _strobe: OmniLight3D
var _strobe_glow: StandardMaterial3D
var _led_floor: ShaderMaterial
var _burst_at := 6.0
var _flash := -1
var _flash_on := false


# Builds the whole club. Safe to run on a worker thread: nothing here touches the scene tree until main.gd adds the finished club to it.
func build() -> void:
	name = "Club"
	position.y = FLOOR_Y
	zones_w = world_zones()
	doorways_w = world_doorways()
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 0.45
	_noise.fractal_octaves = 3
	_noise.seed = 21
	collision_root = Node3D.new()
	collision_root.name = "Collision"
	add_child(collision_root)
	_make_materials()
	for zone in ZONES:
		if ZONES[zone][5] == "":
			continue
		var node := Node3D.new()
		node.name = String(zone).capitalize()
		add_child(node)
		_zones[zone] = node
		_build_shell(zone)
	_build_doorway_trim()
	_build_foyer()
	_build_entry()
	_build_stage()
	_build_dance_floor()
	_build_bar()
	_build_vip()
	_build_lounge()
	_flush()
	_flush_seating()
	for zone in _zones:
		for gi in (_zones[zone] as Node3D).find_children("*", "GeometryInstance3D", true, false):
			(gi as GeometryInstance3D).layers = zone_layer(zone)
	_build_environment()
	pvs = visibility(zones_w, doorways_w)
	built = true


func _process(delta: float) -> void:
	_t += delta
	if not visible:
		return
	if (_zones["dance"] as Node3D).visible:
		for m in _movers:
			var pivot: Node3D = m[0]
			var head: Node3D = m[1]
			var ph: float = m[2]
			pivot.rotation.y = m[3] + 0.6 * sin(_t * 0.45 + ph)
			head.rotation.x = deg_to_rad(-58.0) + 0.24 * sin(_t * 0.7 + ph * 1.3)
		_update_strobe()
	if (_zones["stage"] as Node3D).visible:
		for i in _stage_spots.size():
			_stage_spots[i].light_energy = 5.0 + 1.0 * sin(_t * 0.9 + i * 2.0)


# Bursts of flashes every so often, each flash lit for one rendered frame.
func _update_strobe() -> void:
	var on := false
	var since := _t - _burst_at
	if since >= 0.0:
		if since > STROBE_BURST:
			_burst_at = _t + randf_range(STROBE_GAP.x, STROBE_GAP.y)
			_flash = -1
		else:
			var n := int(since * STROBE_HZ)
			if n != _flash:
				_flash = n
				on = true
	if on == _flash_on:
		return
	_flash_on = on
	_strobe.visible = on
	_led_floor.set_shader_parameter("flash", 0.8 if on else 0.0)
	_strobe_glow.albedo_color = Color.WHITE if on else Color(0.06, 0.06, 0.07)


# ---- what can be seen from where ------------------------------------------------------------------------------------------------------

# The zone a point in the world (your head) is in, or "" if it is in none of them.
func zone_at(world_point: Vector3) -> String:
	var p := to_local(world_point)
	for zone in zones_w:
		var z: Array = zones_w[zone]
		if p.x >= z[0] and p.x <= z[2] and p.z >= z[1] and p.z <= z[3]:
			return zone
	return ""


# Shows the zones that can be seen from `zone` and hides the rest.
func view_from(zone: String) -> void:
	if zone == current_zone or not pvs.has(zone):
		return
	current_zone = zone
	var seen: Array = pvs[zone]
	for z in _zones:
		(_zones[z] as Node3D).visible = seen.has(z)


func zone_node(zone: String) -> Node3D:
	return _zones.get(zone)


static func zone_layer(zone: String) -> int:
	return 1 << (1 + ZONES.keys().find(zone))


# Which zones can be seen from each zone: itself, its neighbours through the doorways, and the zones beyond those wherever one straight line
# passes through every doorway on the way (on the floor plan; the zones are rectangles, so between two of its doorways the line stays in it).
static func visibility(zones: Dictionary, doorways: Array, depth := VIS_DEPTH) -> Dictionary:
	var out := {}
	for zone in zones:
		var seen := {zone: true}
		_look_through(zones, doorways, [], [zone], seen, depth)
		out[zone] = seen.keys()
	# a line of sight runs both ways (the lines tried from either end are not quite the same ones)
	for a in out:
		for b in out[a]:
			if not (out[b] as Array).has(a):
				(out[b] as Array).append(a)
	return out


static func _look_through(zones: Dictionary, doorways: Array, path: Array, chain: Array, seen: Dictionary, depth: int) -> void:
	if path.size() >= depth:
		return
	var here: String = chain[-1]
	for d in doorways:
		var next := ""
		if d[0] == here:
			next = d[1]
		elif d[1] == here:
			next = d[0]
		if next == "" or chain.has(next):
			continue
		var p2: Array = path.duplicate()
		p2.append(d)
		var c2: Array = chain.duplicate()
		c2.append(next)
		if p2.size() > 1 and not _line_through(zones, p2, c2):
			continue
		seen[next] = true
		_look_through(zones, doorways, p2, c2, seen, depth)


# Is there a straight line through all of these doorways, in order? Tries lines between points along the first and the last.
static func _line_through(zones: Dictionary, path: Array, chain: Array) -> bool:
	for i in VIS_SAMPLES:
		var a := _along(path[0], (i + 0.5) / VIS_SAMPLES)
		for j in VIS_SAMPLES:
			if _passes(zones, path, chain, a, _along(path[-1], (j + 0.5) / VIS_SAMPLES)):
				return true
	return false


static func _along(d: Array, f: float) -> Vector2:
	return Vector2(d[2], d[3]).lerp(Vector2(d[4], d[5]), f)


static func _passes(zones: Dictionary, path: Array, chain: Array, a: Vector2, c: Vector2) -> bool:
	var length := a.distance_to(c)
	if length < 0.001:
		return false
	var ts: Array[float] = [0.0]
	for k in range(1, path.size() - 1):
		var d: Array = path[k]
		var hit = Geometry2D.segment_intersects_segment(a, c, Vector2(d[2], d[3]), Vector2(d[4], d[5]))
		if hit == null:
			return false
		ts.append(a.distance_to(hit) / length)
	ts.append(1.0)
	# between doorway k and doorway k + 1 the line must run through the zone between them
	for k in path.size() - 1:
		if ts[k + 1] <= ts[k]:
			return false
		if not _inside(zones[chain[k + 1]], a.lerp(c, (ts[k] + ts[k + 1]) * 0.5)):
			return false
	return true


static func _inside(z: Array, p: Vector2) -> bool:
	return p.x > z[0] + 0.01 and p.x < z[2] - 0.01 and p.y > z[1] + 0.01 and p.y < z[3] - 0.01


# ---- materials -------------------------------------------------------------------------------------------------------------------------

func _make_materials() -> void:
	for key in MATERIALS:
		var d: Array = MATERIALS[key]
		var m := ORMMaterial3D.new()
		m.albedo_texture = load(TEX % [d[0], d[1], d[1], "diff"])
		m.albedo_color = d[3]
		m.normal_enabled = true
		m.normal_texture = load(TEX % [d[0], d[1], d[1], "nor"])
		m.orm_texture = load(TEX % [d[0], d[1], d[1], "arm"])
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		m.vertex_color_use_as_albedo = true
		_materials[key] = m
	var chrome := StandardMaterial3D.new()
	chrome.albedo_color = Color(0.78, 0.78, 0.82)
	chrome.metallic = 0.8               # not fully: with nothing round it to reflect, pure chrome renders black
	chrome.roughness = 0.22
	_materials["chrome"] = chrome
	var gear := StandardMaterial3D.new()          # speakers, the truss, lighting rigs: black metal
	gear.albedo_color = Color(0.04, 0.04, 0.05)
	gear.metallic = 0.6
	gear.roughness = 0.45
	_materials["gear"] = gear
	var neon := StandardMaterial3D.new()          # every glowing strip, in one material: the colour is in the vertices
	neon.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	neon.vertex_color_use_as_albedo = true
	neon.vertex_color_is_srgb = true
	_materials["neon"] = neon
	var led := Shader.new()
	led.code = LED_SHADER
	_led_floor = ShaderMaterial.new()
	_led_floor.shader = led
	_materials["led"] = _led_floor
	var wall := ShaderMaterial.new()               # the LED wall behind the DJ: the same, slower, in purple and pink
	wall.shader = led
	wall.set_shader_parameter("color_a", PURPLE)
	wall.set_shader_parameter("color_b", PINK)
	wall.set_shader_parameter("speed", 0.9)
	_materials["ledwall"] = wall


func _b(zone: String, key: String) -> Batch:
	var k := zone + "/" + key
	if not _batches.has(k):
		_batches[k] = Batch.new(_materials[key])
	return _batches[k]


func _tile(key: String) -> float:
	return MATERIALS[key][2] if MATERIALS.has(key) else 1.0


func _flush() -> void:
	for k in _batches:
		var parts: PackedStringArray = String(k).split("/")
		var mi := MeshInstance3D.new()
		mi.name = parts[1].capitalize()
		mi.mesh = _commit(_batches[k])
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		(_zones[parts[0]] as Node3D).add_child(mi)
	_batches.clear()


# Every stool (or booth) of a model in a zone is one MultiMesh: one draw call a zone for the lot, whatever their number. They all share the
# seating material, so a model is one surface too.
func _flush_seating() -> void:
	for k in _seats:
		var parts: PackedStringArray = String(k).split("/")
		var transforms: Array = _seats[k]
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.mesh = _seat_mesh(parts[1])
		multi.instance_count = transforms.size()
		for i in transforms.size():
			multi.set_instance_transform(i, transforms[i])
		var mi := MultiMeshInstance3D.new()
		mi.name = parts[1]
		mi.multimesh = multi
		mi.material_override = _materials["seating"]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		(_zones[parts[0]] as Node3D).add_child(mi)
	_seats.clear()


func _seat(zone: String, model: String, xf: Transform3D) -> void:
	var k := zone + "/" + model
	if not _seats.has(k):
		_seats[k] = []
	_seats[k].append(xf)


func _seat_mesh(model: String) -> Mesh:
	if not _seat_meshes.has(model):
		var node := (load(SEATING % model) as PackedScene).instantiate()
		_seat_meshes[model] = (node.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D).mesh
		node.free()
	return _seat_meshes[model]


static func _commit(b: Batch) -> ArrayMesh:
	b.st.generate_tangents()
	b.st.set_material(b.material)
	return b.st.commit()


# ---- geometry --------------------------------------------------------------------------------------------------------------------------

# Darker where the floor meets the walls, at the foot and the top of the walls, and in patches: a little depth without baked light.
func _shade(p: Vector3, kind: String, zone: String) -> Color:
	var z: Array = zones_w[zone]
	var x0: float = z[0]
	var z0: float = z[1]
	var x1: float = z[2]
	var z1: float = z[3]
	var h: float = z[4]
	var n := _noise.get_noise_3dv(p * 1.1) * 0.5 + 0.5
	var k := 1.0
	if kind == "wall":
		k = lerpf(0.55, 1.0, smoothstep(0.0, 1.4, p.y)) * lerpf(1.0, 0.6, smoothstep(h - 1.2, h, p.y))
	else:
		var d := minf(minf(p.x - x0, x1 - p.x), minf(p.z - z0, z1 - p.z))
		k = lerpf(0.5, 1.0, smoothstep(0.0, 1.2, d))
	k *= lerpf(0.75, 1.08, n)
	return Color(k, k, k)


func _v(b: Batch, p: Vector3, n: Vector3, uv: Vector2, c: Color) -> void:
	b.st.set_color(c)
	b.st.set_normal(n)
	b.st.set_uv(uv)
	b.st.add_vertex(p)


# A rectangle given as top-left, top-right, bottom-right, bottom-left as seen from the side that is drawn. Cut into cells of `cell` metres
# when `kind` asks for shading (so the vertex colours can carry it); otherwise flat `color`.
func _quad(b: Batch, tl: Vector3, tr: Vector3, br: Vector3, bl: Vector3, tile: float, uv_origin := Vector2.ZERO, cell := 0.0,
		kind := "", zone := "", color := Color.WHITE) -> void:
	var n := (bl - tl).cross(tr - tl).normalized()
	var w := tl.distance_to(tr)
	var h := tl.distance_to(bl)
	var nu := 1
	var nv := 1
	if cell > 0.0:
		nu = maxi(1, int(ceil(w / cell)))
		nv = maxi(1, int(ceil(h / cell)))
	for j in nv:
		for i in nu:
			var fu0 := float(i) / nu
			var fu1 := float(i + 1) / nu
			var fv0 := float(j) / nv
			var fv1 := float(j + 1) / nv
			var pa := tl.lerp(tr, fu0).lerp(bl.lerp(br, fu0), fv0)
			var pb := tl.lerp(tr, fu1).lerp(bl.lerp(br, fu1), fv0)
			var pc := tl.lerp(tr, fu1).lerp(bl.lerp(br, fu1), fv1)
			var pd := tl.lerp(tr, fu0).lerp(bl.lerp(br, fu0), fv1)
			var ua := uv_origin + Vector2(fu0 * w, fv0 * h) / tile
			var ub := uv_origin + Vector2(fu1 * w, fv0 * h) / tile
			var uc := uv_origin + Vector2(fu1 * w, fv1 * h) / tile
			var ud := uv_origin + Vector2(fu0 * w, fv1 * h) / tile
			var ca := _shade(pa, kind, zone) if kind != "" else color
			var cb := _shade(pb, kind, zone) if kind != "" else color
			var cc := _shade(pc, kind, zone) if kind != "" else color
			var cd := _shade(pd, kind, zone) if kind != "" else color
			_v(b, pa, n, ua, ca)
			_v(b, pb, n, ub, cb)
			_v(b, pc, n, uc, cc)
			_v(b, pa, n, ua, ca)
			_v(b, pc, n, uc, cc)
			_v(b, pd, n, ud, cd)


# An axis-aligned box with outward faces.
func _box(b: Batch, center: Vector3, size: Vector3, tile: float, color := Color.WHITE) -> void:
	var lo := center - size * 0.5
	var hi := center + size * 0.5
	_quad(b, Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), tile, Vector2.ZERO, 0.0, "", "", color)
	_quad(b, Vector3(lo.x, hi.y, lo.z), Vector3(lo.x, hi.y, hi.z), Vector3(lo.x, lo.y, hi.z), Vector3(lo.x, lo.y, lo.z), tile, Vector2.ZERO, 0.0, "", "", color)
	_quad(b, Vector3(lo.x, hi.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z), tile, Vector2.ZERO, 0.0, "", "", color)
	_quad(b, Vector3(hi.x, hi.y, lo.z), Vector3(lo.x, hi.y, lo.z), Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), tile, Vector2.ZERO, 0.0, "", "", color)
	_quad(b, Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z), tile, Vector2.ZERO, 0.0, "", "", color)
	_quad(b, Vector3(hi.x, lo.y, lo.z), Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z), tile, Vector2.ZERO, 0.0, "", "", color)


# A (tapered) cylinder from p0 to p1.
func _cyl(b: Batch, p0: Vector3, p1: Vector3, r0: float, tile: float, sides := 12, caps := true, r1 := -1.0, color := Color.WHITE) -> void:
	if r1 < 0.0:
		r1 = r0
	var dir := (p1 - p0).normalized()
	var length := p0.distance_to(p1)
	var ref := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var u := dir.cross(ref).normalized()
	var v := dir.cross(u).normalized()
	for k in sides:
		var a0 := TAU * k / sides
		var a1 := TAU * (k + 1) / sides
		var n0 := u * cos(a0) + v * sin(a0)
		var n1 := u * cos(a1) + v * sin(a1)
		var ua := a0 * r0 / tile
		var ub := a1 * r0 / tile
		var vl := length / tile
		_v(b, p1 + n0 * r1, n0, Vector2(ua, 0.0), color)
		_v(b, p1 + n1 * r1, n1, Vector2(ub, 0.0), color)
		_v(b, p0 + n1 * r0, n1, Vector2(ub, vl), color)
		_v(b, p1 + n0 * r1, n0, Vector2(ua, 0.0), color)
		_v(b, p0 + n1 * r0, n1, Vector2(ub, vl), color)
		_v(b, p0 + n0 * r0, n0, Vector2(ua, vl), color)
		if caps:
			for end in 2:
				var cen := p0 if end == 0 else p1
				var rr := r0 if end == 0 else r1
				var nn := -dir if end == 0 else dir
				var uv0 := Vector2(0.5, 0.5) + Vector2(cos(a0), sin(a0)) * rr / tile
				var uv1 := Vector2(0.5, 0.5) + Vector2(cos(a1), sin(a1)) * rr / tile
				_v(b, cen, nn, Vector2(0.5, 0.5), color)
				if end == 0:
					_v(b, cen + n0 * rr, nn, uv0, color)
					_v(b, cen + n1 * rr, nn, uv1, color)
				else:
					_v(b, cen + n1 * rr, nn, uv1, color)
					_v(b, cen + n0 * rr, nn, uv0, color)


# A curtain hanging in folds along a line on the floor plan, `inward` being the side it is seen from.
func _folds(b: Batch, from: Vector2, to: Vector2, inward: Vector2, y0: float, y1: float, depth: float, count: int, tile: float) -> void:
	var n := count * 2
	for i in n:
		var f0 := float(i) / n
		var f1 := float(i + 1) / n
		var d0 := depth * (i % 2)
		var d1 := depth * ((i + 1) % 2)
		var p0 := from.lerp(to, f0) + inward * d0
		var p1 := from.lerp(to, f1) + inward * d1
		var side := (p1 - p0).normalized()
		var nn := Vector2(-side.y, side.x)
		if nn.dot(inward) < 0.0:
			nn = -nn
		var u0 := from.distance_to(from.lerp(to, f0)) / tile
		var u1 := from.distance_to(from.lerp(to, f1)) / tile
		var normal := Vector3(nn.x, 0.0, nn.y)
		var tl := Vector3(p0.x, y1, p0.y)
		var tr := Vector3(p1.x, y1, p1.y)
		var br := Vector3(p1.x, y0, p1.y)
		var bl := Vector3(p0.x, y0, p0.y)
		var vh := (y1 - y0) / tile
		# wound so the drawn side faces `inward`
		if (bl - tl).cross(tr - tl).dot(normal) < 0.0:
			var swap := tl
			tl = tr
			tr = swap
			swap = bl
			bl = br
			br = swap
			var su := u0
			u0 = u1
			u1 = su
		_v(b, tl, normal, Vector2(u0, 0.0), Color.WHITE)
		_v(b, tr, normal, Vector2(u1, 0.0), Color.WHITE)
		_v(b, br, normal, Vector2(u1, vh), Color.WHITE)
		_v(b, tl, normal, Vector2(u0, 0.0), Color.WHITE)
		_v(b, br, normal, Vector2(u1, vh), Color.WHITE)
		_v(b, bl, normal, Vector2(u0, vh), Color.WHITE)


# A glowing strip between two points (axis-aligned).
func _glow(zone: String, a: Vector3, c: Vector3, color: Color, thick := 0.03) -> void:
	var size := (c - a).abs() + Vector3(thick, thick, thick)
	_box(_b(zone, "neon"), (a + c) * 0.5, size, 1.0, color)


# A solid box for you (and anything dropped) to bump into. `layer` 1 is solid; KillRoom.WALKABLE is what you stand on.
func _solid(center: Vector3, size: Vector3, layer := 1) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = layer
	body.collision_mask = 0
	body.position = center
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	collision_root.add_child(body)


func _solid_cyl(center: Vector3, radius: float, height: float, layer := 1) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = layer
	body.collision_mask = 0
	body.position = center
	var shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = radius
	cyl.height = height
	shape.shape = cyl
	body.add_child(shape)
	collision_root.add_child(body)


# ---- the rooms -------------------------------------------------------------------------------------------------------------------------

# A zone's floor, ceiling and walls (as seen from inside), with its doorways cut out and lintels over them; solid walls and a floor you
# stand on.
func _build_shell(zone: String) -> void:
	var z: Array = zones_w[zone]
	var x0: float = z[0]
	var z0: float = z[1]
	var x1: float = z[2]
	var z1: float = z[3]
	var h: float = z[4]
	var fk: String = z[5]
	var wk: String = z[6]
	var ft := _tile(fk)
	var ct := _tile("ceiling")
	_quad(_b(zone, fk), Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3(x1, 0, z1), Vector3(x0, 0, z1), ft, Vector2(x0, z0) / ft, 0.6, "floor", zone)
	_quad(_b(zone, "ceiling"), Vector3(x0, h, z1), Vector3(x1, h, z1), Vector3(x1, h, z0), Vector3(x0, h, z0), ct, Vector2(x0, z0) / ct, 1.0, "ceiling", zone)
	_solid(Vector3((x0 + x1) * 0.5, -0.1, (z0 + z1) * 0.5), Vector3(x1 - x0, 0.2, z1 - z0), 1 | KillRoom.WALKABLE)
	var wt := _tile(wk)
	for e in _edges(zone):
		var a: Vector2 = e[0]
		var dir: Vector2 = e[2]
		var t := 0.0
		for g in e[3]:
			var g0: float = g[0]
			var g1: float = g[1]
			var gh: float = g[2]
			if g0 > t + 0.001:
				_wall(zone, wk, a + dir * t, a + dir * g0, 0.0, h, wt)
			if gh < h - 0.001:
				_wall(zone, wk, a + dir * g0, a + dir * g1, gh, h, wt)
			t = maxf(t, g1)
		if e[1] > t + 0.001:
			_wall(zone, wk, a + dir * t, a + dir * e[1], 0.0, h, wt)


# The four edges of a zone, each as [start, length, direction, the doorways along it as [from, to, height, doorway] in order]. Each runs
# from your left to your right as you face it from inside the zone.
func _edges(zone: String) -> Array:
	var z: Array = zones_w[zone]
	var corners := [Vector2(z[0], z[1]), Vector2(z[2], z[1]), Vector2(z[2], z[3]), Vector2(z[0], z[3]), Vector2(z[0], z[1])]
	var out := []
	for i in 4:
		var a: Vector2 = corners[i]
		var c: Vector2 = corners[i + 1]
		var length := a.distance_to(c)
		var dir := (c - a) / length
		var gaps := []
		for d in doorways_w:
			if d[0] != zone and d[1] != zone:
				continue
			var p0 := Vector2(d[2], d[3])
			var p1 := Vector2(d[4], d[5])
			if not _on_edge(p0, a, dir, length) or not _on_edge(p1, a, dir, length):
				continue
			var t0 := (p0 - a).dot(dir)
			var t1 := (p1 - a).dot(dir)
			gaps.append([minf(t0, t1), maxf(t0, t1), float(d[6]), d])
		gaps.sort_custom(func(p: Array, q: Array) -> bool: return p[0] < q[0])
		out.append([a, length, dir, gaps])
	return out


static func _on_edge(p: Vector2, a: Vector2, dir: Vector2, length: float) -> bool:
	var t := (p - a).dot(dir)
	return absf((p - a).cross(dir)) < 0.01 and t > -0.01 and t < length + 0.01


# A piece of wall from `left` to `right` (as seen from inside the zone), from ya up to yb. Solid if it starts at the floor.
func _wall(zone: String, key: String, left: Vector2, right: Vector2, ya: float, yb: float, tile: float) -> void:
	_quad(_b(zone, key), Vector3(left.x, yb, left.y), Vector3(right.x, yb, right.y), Vector3(right.x, ya, right.y), Vector3(left.x, ya, left.y),
		tile, Vector2(left.x + left.y, -yb) / tile, 0.6, "wall", zone)
	if ya < 0.001:
		var mid := (left + right) * 0.5
		var span := (right - left).abs()
		_solid(Vector3(mid.x, WALL_SOLID_H * 0.5, mid.y), Vector3(maxf(span.x, 0.2), WALL_SOLID_H, maxf(span.y, 0.2)))


# Which way is into the zone from a point on its edge.
func _inward(zone: String, p: Vector2) -> Vector2:
	var z: Array = zones_w[zone]
	if absf(p.x - z[0]) < 0.01:
		return Vector2.RIGHT
	if absf(p.x - z[2]) < 0.01:
		return Vector2.LEFT
	if absf(p.y - z[1]) < 0.01:
		return Vector2(0, 1)
	return Vector2(0, -1)


# Neon round the doorways, on both sides; a neon line under the long opening into the bar; signs over the doorways off the hall.
func _build_doorway_trim() -> void:
	for d in doorways_w:
		if d[7] == null:
			continue
		var col: Color = d[7]
		var p0 := Vector2(d[2], d[3])
		var p1 := Vector2(d[4], d[5])
		var h: float = d[6]
		for zone in [d[0], d[1]]:
			if not _zones.has(zone):
				continue
			var off := _inward(zone, p0) * 0.04
			var a := Vector3(p0.x + off.x, 0.0, p0.y + off.y)
			var c := Vector3(p1.x + off.x, 0.0, p1.y + off.y)
			_glow(zone, a, a + Vector3(0, h, 0), col)
			_glow(zone, c, c + Vector3(0, h, 0), col)
			_glow(zone, a + Vector3(0, h, 0), c + Vector3(0, h, 0), col)
	for zone in ["bar", "stage", "dance"]:
		var off := 0.04 if zone == "bar" else -0.04
		var z0 := -4.2 if zone != "dance" else SPLIT_Z
		var z1 := 1.6 if zone != "stage" else SPLIT_Z
		_glow(zone, Vector3(wx(8.0) + off, 2.8, wz(z0)), Vector3(wx(8.0) + off, 2.8, wz(z1)), AMBER)
	_sign("dance", "BAR", w3(8.0, 3.25, -1.3) - Vector3(0.04, 0, 0), Vector3.LEFT, AMBER)
	_sign("stage", "VIP", w3(-5.0, 2.72, -4.4) + Vector3(0.04, 0, 0), Vector3.RIGHT, RED)
	_sign("dance", "LOUNGE", w3(-5.0, 2.72, 0.4) + Vector3(0.04, 0, 0), Vector3.RIGHT, PURPLE)


# A neon strip round a zone's walls at height y (broken where a doorway is taller than it).
func _perimeter(zone: String, y: float, col: Color, inset := 0.03) -> void:
	for e in _edges(zone):
		var a: Vector2 = e[0]
		var dir: Vector2 = e[2]
		var inward := _inward(zone, a + dir * e[1] * 0.5)
		var spans := []
		var t := 0.0
		for g in e[3]:
			if g[2] > y - 0.05:
				if g[0] > t:
					spans.append([t, g[0]])
				t = maxf(t, g[1])
		if e[1] > t:
			spans.append([t, e[1]])
		for s in spans:
			var p0: Vector2 = a + dir * s[0] + inward * inset
			var p1: Vector2 = a + dir * s[1] + inward * inset
			_glow(zone, Vector3(p0.x, y, p0.y), Vector3(p1.x, y, p1.y), col)


func _sign(zone: String, text: String, pos: Vector3, facing: Vector3, col: Color) -> void:
	var label := Label3D.new()
	label.text = text
	label.font_size = 80
	label.pixel_size = 0.004
	label.outline_size = 14
	label.modulate = col
	label.outline_modulate = Color(col.r * 0.35, col.g * 0.35, col.b * 0.35, 1.0)
	label.double_sided = false
	label.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	label.position = pos
	label.rotation.y = atan2(facing.x, facing.z)
	(_zones[zone] as Node3D).add_child(label)


func _omni(zone: String, pos: Vector3, col: Color, energy: float, reach: float) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.position = pos
	light.light_color = col
	light.light_energy = energy
	light.omni_range = reach * SCALE          # a light's range is not scaled by the node it is on
	light.omni_attenuation = 1.2
	light.light_cull_mask = 1 | zone_layer(zone)
	(_zones[zone] as Node3D).add_child(light)
	return light


func _spot(zone: String, pos: Vector3, target: Vector3, col: Color, energy: float, reach: float, angle: float) -> SpotLight3D:
	var light := SpotLight3D.new()
	light.transform = Transform3D(Basis.looking_at(target - pos), pos)
	light.light_color = col
	light.light_energy = energy
	light.spot_range = reach * SCALE
	light.spot_angle = angle
	light.spot_attenuation = 0.9
	light.light_cull_mask = 1 | zone_layer(zone)
	(_zones[zone] as Node3D).add_child(light)
	return light


# ---- furniture -------------------------------------------------------------------------------------------------------------------------

# A counter (the bar, the cashier's, the DJ's): a black planked body, a veneer top overhanging the side customers stand at (`front`), a neon
# strip under that lip and a chrome foot rail along it.
func _counter(zone: String, x0: float, z0: float, x1: float, z1: float, height: float, front: Vector2, col: Color) -> void:
	# x0..z1 is its place on the plan: it is as long as that makes it in the world, but as deep, and as high, as a counter is
	var body := height - 0.05
	var mid := wv((x0 + x1) * 0.5, (z0 + z1) * 0.5)
	var c := Vector3(mid.x, 0.0, mid.y)
	var f3 := Vector3(front.x, 0.0, front.y)
	var across := f3.abs()
	var along := Vector3(across.z, 0.0, across.x)
	var length := ((x1 - x0) if along.x > 0.5 else (z1 - z0)) * SCALE
	var depth := (z1 - z0) if along.x > 0.5 else (x1 - x0)
	var footprint := along * length + across * depth
	_box(_b(zone, "planks"), c + Vector3(0, body * 0.5, 0), footprint + Vector3(0, body, 0), _tile("planks"))
	_box(_b(zone, "veneer"), c + Vector3(0, height - 0.025, 0) + f3 * 0.04, along * (length + 0.04) + across * (depth + 0.08) + Vector3(0, 0.05, 0), _tile("veneer"))
	var face := c + f3 * depth * 0.5
	_glow(zone, face + f3 * 0.02 + Vector3(0, body - 0.03, 0) - along * length * 0.5, face + f3 * 0.02 + Vector3(0, body - 0.03, 0) + along * length * 0.5, col, 0.025)
	var rail := face + f3 * 0.2 + Vector3(0, 0.22, 0)
	_cyl(_b(zone, "chrome"), rail - along * length * 0.47, rail + along * length * 0.47, 0.024, 1.0, 10, true)
	_solid(c + Vector3(0, height * 0.5, 0), footprint + Vector3(0, height, 0))


# A bar stool (club_stool: a leather seat on a chrome post with a foot ring and a round foot, 0.76 m to the seat). Lower ones are the same
# stool made smaller. `at` is a place in the world (like all the furniture's, below: only _counter and _platform take the plan).
func _stool(zone: String, at: Vector2, seat := 0.76) -> void:
	_seat(zone, "club_stool", Transform3D(Basis.from_scale(Vector3.ONE * (seat / 0.76)), Vector3(at.x, 0.0, at.y)))
	_solid(Vector3(at.x, seat * 0.5, at.y), Vector3(0.36, seat, 0.36))


# A round table on a chrome post: high (to stand at), or low (by a sofa).
func _table(zone: String, at: Vector2, radius: float, height: float) -> void:
	var p := Vector3(at.x, 0.0, at.y)
	_cyl(_b(zone, "chrome"), p, p + Vector3(0, 0.02, 0), 0.24, 1.0, 16, true)
	_cyl(_b(zone, "chrome"), p, p + Vector3(0, height - 0.04, 0), 0.035, 1.0, 10, false)
	_cyl(_b(zone, "veneer"), p + Vector3(0, height - 0.04, 0), p + Vector3(0, height, 0), radius, _tile("veneer"), 20, true)
	_solid(p + Vector3(0, height * 0.5, 0), Vector3(radius * 1.6, height, radius * 1.6))


# A raised platform (the stage, the runway): blocks you at its edge, and is walked on once you are up the steps. Glowing along `edges`
# ([from, to] pairs of points on its top, at the outside of the edge).
func _platform(zone: String, px0: float, pz0: float, px1: float, pz1: float, edges: Array) -> void:
	var x0 := wx(px0)         # the plan's place for it, in the world (it is no higher than a stage is)
	var z0 := wz(pz0)
	var x1 := wx(px1)
	var z1 := wz(pz1)
	var c := Vector3((x0 + x1) * 0.5, 0.0, (z0 + z1) * 0.5)
	_box(_b(zone, "planks"), c + Vector3(0, (STAGE_H - 0.04) * 0.5, 0), Vector3(x1 - x0, STAGE_H - 0.04, z1 - z0), _tile("planks"))
	_box(_b(zone, "veneer"), c + Vector3(0, STAGE_H - 0.02, 0), Vector3(x1 - x0, 0.04, z1 - z0), _tile("veneer"))
	_solid(c + Vector3(0, 0.175, 0), Vector3(x1 - x0, 0.35, z1 - z0))
	_solid(c + Vector3(0, STAGE_H - 0.05, 0), Vector3(x1 - x0, 0.1, z1 - z0), KillRoom.WALKABLE)
	for e in edges:
		var a := wv(e[0].x, e[0].y)
		var b := wv(e[1].x, e[1].y)
		_glow(zone, Vector3(a.x, STAGE_H - 0.03, a.y), Vector3(b.x, STAGE_H - 0.03, b.y), PINK)


# A dance pole, from a platform top to the ceiling.
func _pole(zone: String, at: Vector2, base: float, top: float) -> void:
	var chrome := _b(zone, "chrome")
	var p := Vector3(at.x, base, at.y)
	_cyl(chrome, p, Vector3(at.x, top, at.y), 0.024, 1.0, 14, false)
	_cyl(chrome, p, p + Vector3(0, 0.035, 0), 0.055, 1.0, 14, true)
	_cyl(chrome, Vector3(at.x, top - 0.035, at.y), Vector3(at.x, top, at.y), 0.055, 1.0, 14, true)
	_solid(Vector3(at.x, base + 1.0, at.y), Vector3(0.06, 2.0, 0.06))


# A booth against a wall (club_booth, 3.0 m wide and 1.8 m deep: a U of leather benches with high backs round a black table), centred on
# (cx, cz), with a purple glow along the foot of the seats.
func _booth(zone: String, cx: float, cz: float) -> void:
	var x0 := cx - 1.5
	var x1 := cx + 1.5
	var z0 := cz - 0.9
	var z1 := cz + 0.9
	_seat(zone, "club_booth", Transform3D(Basis.IDENTITY, Vector3(cx, 0.0, cz)))
	var seat_d := 0.55
	var back_h := 1.15
	_solid(Vector3((x0 + x1) * 0.5, back_h * 0.5, z1 - seat_d * 0.5), Vector3(x1 - x0, back_h, seat_d))
	for side in [[x0, 1.0], [x1, -1.0]]:
		var sx: float = side[0]
		var inward: float = side[1]
		var run := (z1 - seat_d) - z0
		_solid(Vector3(sx + inward * seat_d * 0.5, back_h * 0.5, (z0 + z1 - seat_d) * 0.5), Vector3(seat_d, back_h, run))
		_glow(zone, Vector3(sx + inward * (seat_d + 0.01), 0.04, z0), Vector3(sx + inward * (seat_d + 0.01), 0.04, z1 - seat_d), PURPLE, 0.02)
	_glow(zone, Vector3(x0 + seat_d, 0.04, z1 - seat_d - 0.01), Vector3(x1 - seat_d, 0.04, z1 - seat_d - 0.01), PURPLE, 0.02)
	_solid(Vector3((x0 + x1) * 0.5, 0.37, (z0 + z1 - seat_d) * 0.5 + 0.1), Vector3((x1 - x0) - 2.0 * seat_d - 0.5, 0.74, 0.75))


# A Poly Haven model, placed by its base and turned `yaw` degrees (they face +z), solid to you.
func _prop(zone: String, id: String, at: Vector2, yaw := 0.0) -> Node3D:
	var scene := load(MODEL % [id, id]) as PackedScene
	if scene == null:
		push_warning("missing model " + id)
		return null
	var model := scene.instantiate() as Node3D
	KillRoom.apply_anisotropic(model)
	for gi in model.find_children("*", "GeometryInstance3D", true, false):
		(gi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	model.position = Vector3(at.x, 0.0, at.y)
	model.rotation_degrees.y = yaw
	(_zones[zone] as Node3D).add_child(model)
	var bounds := _bounds(model)
	if bounds.size != Vector3.ZERO:
		var body := StaticBody3D.new()
		body.collision_mask = 0
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = bounds.size
		shape.shape = box
		shape.position = bounds.get_center()
		body.add_child(shape)
		model.add_child(body)
	return model


# The bounds of everything in a model, in the model's own space.
static func _bounds(model: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var node := mi as MeshInstance3D
		var rel := Transform3D.IDENTITY
		var walker: Node = node
		while walker != model and walker != null:
			rel = (walker as Node3D).transform * rel
			walker = walker.get_parent()
		var box := rel * node.get_aabb()
		out = box if first else out.merge(box)
		first = false
	return out


# ---- the foyer -------------------------------------------------------------------------------------------------------------------------

# In through the heavy door from the stairs: a bare room, for now, and the way on into the hall at the far corner, out of line with the
# door, so the stairwell sees little of the club and the club none of the stairwell.
func _build_foyer() -> void:
	_perimeter("foyer", 2.85, PINK)
	_omni("foyer", w3(10.4, 2.6, -8.0), PINK, 1.6, 4.8)


# ---- the entrance -----------------------------------------------------------------------------------------------------------------------

# The way in from the street: a small foyer off the south wall of the hall, east of the DJ's booth. A closed steel double door in its far wall
# (there is no street yet) straight across from the doorway into the hall, and the admission counter to the side, out from the east wall with
# the cashier's room behind it (a metre or more, open at the hall end).
func _build_entry() -> void:
	var zone := "entry"
	_counter(zone, 7.5, 3.9, 8.1, 5.9, 1.1, Vector2(-1, 0), CYAN)
	_sign(zone, "ADMISSION", w3(9.2, 2.3, 4.9) - Vector3(0.04, 0, 0), Vector3.LEFT, CYAN)
	# the door to the outside, in the south wall, between neon posts: two black steel leaves with a chrome push bar on each
	var dz := wz(ENTRY_Z1) - 0.04
	var mid := wx(6.0)                    # straight across from the doorway from the hall (a door is a door's width whatever the room)
	var dx0 := mid - 0.7
	var dx1 := mid + 0.7
	var gear := _b(zone, "gear")
	for leaf in [[dx0, mid - 0.01], [mid + 0.01, dx1]]:
		_box(gear, Vector3((leaf[0] + leaf[1]) * 0.5, 1.15, dz), Vector3(leaf[1] - leaf[0], 2.3, 0.06), 1.0)
	for bx in [mid - 0.14, mid + 0.14]:
		_cyl(_b(zone, "chrome"), Vector3(bx, 0.95, dz - 0.07), Vector3(bx, 1.15, dz - 0.07), 0.018, 1.0, 8, true)
		for y in [0.97, 1.13]:
			_cyl(_b(zone, "chrome"), Vector3(bx, y, dz - 0.03), Vector3(bx, y, dz - 0.07), 0.008, 1.0, 6, true)
	_glow(zone, Vector3(dx0 - 0.03, 0.0, dz - 0.04), Vector3(dx0 - 0.03, 2.35, dz - 0.04), CYAN)
	_glow(zone, Vector3(dx1 + 0.03, 0.0, dz - 0.04), Vector3(dx1 + 0.03, 2.35, dz - 0.04), CYAN)
	_glow(zone, Vector3(dx0 - 0.03, 2.35, dz - 0.04), Vector3(dx1 + 0.03, 2.35, dz - 0.04), CYAN)
	_perimeter(zone, 2.85, CYAN)
	_omni(zone, w3(7.0, 2.6, 5.0), CYAN, 1.4, 4.5)


# ---- the main hall: the stage end --------------------------------------------------------------------------------------------------

# The stage across the north wall with a pole at each end, a runway out from its middle to a round end with the third pole, steps up at
# its west end; a curtain behind; seats round the round end; sofas along the west wall and high tables to the east.
func _build_stage() -> void:
	var zone := "stage"
	var h := STAGE_H
	# the main stage, x -1.5..4.5, from the north wall to z -8.2; the runway x 0.85..2.15 to z -5.6; the round end, centre (1.5, -4.6) (the plan)
	_platform(zone, -1.5, NORTH, 4.5, -8.2, [
		[Vector2(-1.52, NORTH), Vector2(-1.52, -8.22)], [Vector2(4.52, NORTH), Vector2(4.52, -8.22)],
		[Vector2(-1.52, -8.22), Vector2(0.85, -8.22)], [Vector2(2.15, -8.22), Vector2(4.52, -8.22)]])
	_platform(zone, 0.85, -8.2, 2.15, -5.6, [[Vector2(0.83, -8.2), Vector2(0.83, -5.67)], [Vector2(2.17, -8.2), Vector2(2.17, -5.67)]])
	var rc := wv(1.5, -4.6)
	var round_c := Vector3(rc.x, 0.0, rc.y)
	var r := 1.25 * SCALE
	_cyl(_b(zone, "planks"), round_c, round_c + Vector3(0, h - 0.04, 0), r, _tile("planks"), 32, false)
	_cyl(_b(zone, "veneer"), round_c + Vector3(0, h - 0.04, 0), round_c + Vector3(0, h, 0), r, _tile("veneer"), 32, true)
	_cyl(_b(zone, "neon"), round_c + Vector3(0, h - 0.045, 0), round_c + Vector3(0, h - 0.015, 0), r + 0.012, 1.0, 32, false, -1.0, PINK)
	_solid_cyl(round_c + Vector3(0, 0.175, 0), r, 0.35)
	_solid_cyl(round_c + Vector3(0, h - 0.05, 0), r, 0.1, KillRoom.WALKABLE)
	# steps up at the west end of the stage (a step is a step: 15 cm up, 28 cm along), with glowing nosings
	var stage_w := wx(-1.5)
	var step_z := wz(-9.3)
	for i in 3:
		var top := 0.15 * (i + 1)
		var sx := stage_w - 0.84 + 0.28 * i
		_box(_b(zone, "planks"), Vector3(sx + 0.14, top * 0.5, step_z), Vector3(0.28, top, 1.2), _tile("planks"))
		_glow(zone, Vector3(sx - 0.01, top - 0.015, step_z - 0.6), Vector3(sx - 0.01, top - 0.015, step_z + 0.6), PINK, 0.02)
		_solid(Vector3(sx + 0.14, top - 0.05, step_z), Vector3(0.28, 0.1, 1.2), KillRoom.WALKABLE)
	# the poles
	_pole(zone, wv(0.0, -9.5), h, HALL_H)
	_pole(zone, wv(3.0, -9.5), h, HALL_H)
	_pole(zone, Vector2(round_c.x, round_c.z), h, HALL_H)
	# the curtain behind the stage
	_folds(_b(zone, "velvet"), wv(-1.5, NORTH) + Vector2(0, 0.04), wv(4.5, NORTH) + Vector2(0, 0.04), Vector2(0, 1), h, 4.9, 0.12, roundi(30 * SCALE), _tile("velvet"))
	_glow(zone, Vector3(wx(-1.5), 4.95, wz(NORTH) + 0.2), Vector3(wx(4.5), 4.95, wz(NORTH) + 0.2), PINK, 0.04)
	# seats round the round end, half a metre out from it
	for i in 7:
		var a := deg_to_rad(-100.0 + 200.0 / 6.0 * i)
		_stool(zone, Vector2(round_c.x + sin(a) * (r + 0.5), round_c.z + cos(a) * (r + 0.5)), 0.66)
	# sofas facing the stage along the west wall, each with a low table; high tables to the east
	for sz in [-9.6, -7.2]:
		var sofa := wv(-5.0, sz) + Vector2(0.55, 0)
		_prop(zone, "sofa_02", sofa, 90.0)
		_table(zone, sofa + Vector2(1.05, 0), 0.32, 0.46)
	for plan_at in [Vector2(6.2, -9.4), Vector2(6.6, -4.4)]:
		var at := wv(plan_at.x, plan_at.y)
		_table(zone, at, 0.32, 1.05)
		_stool(zone, at + Vector2(-0.55, 0.15))
		_stool(zone, at + Vector2(0.5, 0.25))
	_perimeter(zone, 3.2, PINK)
	# light: one spot on the main stage, one on the round end
	_stage_spots.append(_spot(zone, w3(1.5, 5.2, -6.2), w3(1.5, h, -9.4), PINK, 5.0, 9.0, 42.0))
	_stage_spots.append(_spot(zone, Vector3(round_c.x, 5.2, wz(-3.2)), round_c + Vector3(0, h + 0.8, 0), PURPLE, 3.2, 7.5, 24.0))


# ---- the main hall: the dance floor end ----------------------------------------------------------------------------------------------

# A lit floor under a truss with two moving heads and a strobe; the DJ's booth at the south wall in front of an LED wall, a speaker stack
# either side; high tables by the bar.
func _build_dance_floor() -> void:
	var zone := "dance"
	var node: Node3D = _zones[zone]
	# the LED floor: 0.5 m panels, a centimetre proud of the floor
	_quad(_b(zone, "led"), Vector3(wx(-1.5), 0.012, wz(-2.4)), Vector3(wx(4.5), 0.012, wz(-2.4)), Vector3(wx(4.5), 0.012, wz(1.6)), Vector3(wx(-1.5), 0.012, wz(1.6)), 0.5)
	# the truss over it, hung from the ceiling, with a cross-member down the middle (as long as the floor, as thick as truss is)
	var gear := _b(zone, "gear")
	var ty := 4.6
	var tx := wx(1.5)
	var tz := wz(-0.4)
	for zz in [-2.4, 1.6]:
		_box(gear, Vector3(tx, ty, wz(zz)), Vector3(6.2 * SCALE, 0.22, 0.22), 1.0)
	for xx in [-1.5, 4.5]:
		_box(gear, Vector3(wx(xx), ty, tz), Vector3(0.22, 0.22, 4.0 * SCALE), 1.0)
	_box(gear, Vector3(tx, ty, tz), Vector3(6.0 * SCALE, 0.18, 0.18), 1.0)
	for xx in [-1.5, 4.5]:
		for zz in [-2.4, 1.6]:
			_cyl(_b(zone, "chrome"), Vector3(wx(xx), ty + 0.11, wz(zz)), Vector3(wx(xx), HALL_H, wz(zz)), 0.015, 1.0, 6, false)
	# the strobe in the middle of the truss, and its light (shown only for the frame of a flash)
	var strobe_b := Batch.new(_materials["gear"])
	_box(strobe_b, Vector3(tx, ty - 0.17, tz), Vector3(0.5, 0.16, 0.25), 1.0)
	var housing := MeshInstance3D.new()
	housing.mesh = _commit(strobe_b)
	housing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(housing)
	_strobe_glow = StandardMaterial3D.new()
	_strobe_glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_strobe_glow.albedo_color = Color(0.06, 0.06, 0.07)
	var panel_b := Batch.new(_strobe_glow)
	_box(panel_b, Vector3(tx, ty - 0.255, tz), Vector3(0.44, 0.012, 0.19), 1.0)
	var panel := MeshInstance3D.new()
	panel.mesh = _commit(panel_b)
	panel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(panel)
	_strobe = _omni(zone, Vector3(tx, ty - 0.6, tz), Color(0.95, 0.97, 1.0), 6.0, 10.0)
	_strobe.light_cull_mask |= zone_layer("stage")          # the flash lights the whole hall
	_strobe.visible = false
	# two moving heads on the truss, sweeping beams across the floor
	_mover(Vector3(wx(0.0), ty - 0.11, tz), -90.0, CYAN, 0.0)
	_mover(Vector3(wx(3.0), ty - 0.11, tz), 90.0, PINK, 2.1)
	# the DJ's booth, its gear, and the LED wall behind
	_counter(zone, 0.3, 1.9, 2.7, 2.45, 1.05, Vector2(0, -1), CYAN)
	var dj := wv(1.5, 2.175)
	for dx in [-0.65, 0.65]:
		_cyl(gear, Vector3(dj.x + dx, 1.05, dj.y), Vector3(dj.x + dx, 1.09, dj.y), 0.17, 1.0, 20, true)
		_cyl(_b(zone, "neon"), Vector3(dj.x + dx, 1.085, dj.y), Vector3(dj.x + dx, 1.095, dj.y), 0.172, 1.0, 20, false, -1.0, CYAN)
	_box(gear, Vector3(dj.x, 1.09, dj.y), Vector3(0.36, 0.08, 0.32), 1.0)
	for i in 4:
		_box(_b(zone, "neon"), Vector3(dj.x - 0.12 + 0.08 * i, 1.135, dj.y - 0.1), Vector3(0.03, 0.012, 0.03), 1.0, PINK if i % 2 == 0 else CYAN)
	var wall_z := wz(SOUTH) - 0.03
	_quad(_b(zone, "ledwall"), Vector3(wx(3.5), 4.1, wall_z), Vector3(wx(-0.5), 4.1, wall_z), Vector3(wx(-0.5), 1.3, wall_z), Vector3(wx(3.5), 1.3, wall_z), 0.25)
	# a speaker stack either side, against the south wall
	var spk_z := wz(SOUTH) - 0.4
	for sx in [wx(-1.1), wx(4.1)]:
		_box(gear, Vector3(sx, 0.8, spk_z), Vector3(0.7, 1.6, 0.6), 1.0)
		_cyl(_b(zone, "neon"), Vector3(sx, 0.55, spk_z - 0.3), Vector3(sx, 0.55, spk_z - 0.305), 0.24, 1.0, 20, true, -1.0, Color(0.04, 0.25, 0.3))
		_cyl(_b(zone, "neon"), Vector3(sx, 1.2, spk_z - 0.3), Vector3(sx, 1.2, spk_z - 0.305), 0.14, 1.0, 16, true, -1.0, Color(0.04, 0.25, 0.3))
		_solid(Vector3(sx, 0.8, spk_z), Vector3(0.7, 1.6, 0.6))
	# high tables between the floor and the bar
	for plan_at in [Vector2(6.4, -1.6), Vector2(6.4, -0.1)]:
		var at := wv(plan_at.x, plan_at.y)
		_table(zone, at, 0.32, 1.05)
		_stool(zone, at + Vector2(-0.5, 0.3))
		_stool(zone, at + Vector2(0.45, -0.35))
	_perimeter(zone, 3.2, CYAN)


# A moving head: a yoke that turns, a head in it that tilts, a spot light and a faint beam out of it.
func _mover(pos: Vector3, yaw: float, col: Color, phase: float) -> void:
	var pivot := Node3D.new()
	pivot.position = pos
	pivot.rotation_degrees.y = yaw
	(_zones["dance"] as Node3D).add_child(pivot)
	var yoke_b := Batch.new(_materials["gear"])
	_box(yoke_b, Vector3(0, -0.04, 0), Vector3(0.36, 0.08, 0.2), 1.0)
	for sx in [-0.17, 0.17]:
		_box(yoke_b, Vector3(sx, -0.16, 0), Vector3(0.03, 0.24, 0.12), 1.0)
	var yoke := MeshInstance3D.new()
	yoke.mesh = _commit(yoke_b)
	yoke.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pivot.add_child(yoke)
	var head := Node3D.new()
	head.position = Vector3(0, -0.22, 0)
	head.rotation_degrees.x = -58.0
	pivot.add_child(head)
	var head_b := Batch.new(_materials["gear"])
	_cyl(head_b, Vector3(0, 0, 0.12), Vector3(0, 0, -0.12), 0.11, 1.0, 14, true)
	var lens_b := Batch.new(_materials["neon"])
	_cyl(lens_b, Vector3(0, 0, -0.121), Vector3(0, 0, -0.123), 0.08, 1.0, 14, true, -1.0, col)
	for b in [head_b, lens_b]:
		var mi := MeshInstance3D.new()
		mi.mesh = _commit(b)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		head.add_child(mi)
	var light := SpotLight3D.new()
	light.position = Vector3(0, 0, -0.13)
	light.light_color = col
	light.light_energy = 6.0
	light.spot_range = 9.0 * SCALE
	light.spot_angle = 14.0
	light.spot_attenuation = 0.6
	light.light_cull_mask = 1 | zone_layer("dance")
	head.add_child(light)
	var beam_mat := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = BEAM_SHADER
	beam_mat.shader = shader
	beam_mat.set_shader_parameter("color", col)
	beam_mat.set_shader_parameter("strength", 0.35)
	var beam := MeshInstance3D.new()
	beam.mesh = _cone(7.0, 14.0, beam_mat)
	beam.position = Vector3(0, 0, -0.13)
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	head.add_child(beam)
	_movers.append([pivot, head, phase, deg_to_rad(yaw)])


# An open cone along -z (a light beam): UV.y runs 0 at the lamp to 1 at the far end.
static func _cone(length: float, angle: float, material: Material, sides := 16) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r0 := 0.07
	var r1 := length * tan(deg_to_rad(angle))
	for k in sides:
		var a0 := TAU * k / sides
		var a1 := TAU * (k + 1) / sides
		var n0 := Vector3(cos(a0), sin(a0), 0.0)
		var n1 := Vector3(cos(a1), sin(a1), 0.0)
		var quad := [[n0 * r0, n0, Vector2(0, 0)], [n1 * r0, n1, Vector2(1, 0)], [n1 * r1 + Vector3(0, 0, -length), n1, Vector2(1, 1)],
			[n0 * r1 + Vector3(0, 0, -length), n0, Vector2(0, 1)]]
		for idx in [0, 1, 2, 0, 2, 3]:
			st.set_normal(quad[idx][1])
			st.set_uv(quad[idx][2])
			st.add_vertex(quad[idx][0])
	st.set_material(material)
	return st.commit()


# ---- the bar ---------------------------------------------------------------------------------------------------------------------------

# A long counter down the room with stools along it, a way round its north end for the bartender, and a back bar of lit shelves.
func _build_bar() -> void:
	var zone := "bar"
	_counter(zone, 10.7, -4.4, 11.35, 2.3, 1.1, Vector2(-1, 0), AMBER)
	var counter_x := wx(11.025)             # the middle of the counter; it is 0.65 deep
	var stool_x := counter_x - 0.325 - 0.5
	var z := wz(-3.9)
	while z < wz(2.1):
		_stool(zone, Vector2(stool_x, z))
		z += 0.8
	# the back bar along the east wall: a low cupboard, then lit shelves of bottles up the wall
	var vt := _tile("veneer")
	var back_z := wz(-1.05)
	_box(_b(zone, "planks"), Vector3(13.25, 0.47, back_z), Vector3(0.5, 0.94, 6.3 * SCALE), _tile("planks"))
	_box(_b(zone, "veneer"), Vector3(13.22, 0.96, back_z), Vector3(0.56, 0.04, 6.3 * SCALE), vt)
	_solid(Vector3(13.25, 0.5, back_z), Vector3(0.5, 1.0, 6.3 * SCALE))
	_quad(_b(zone, "neon"), Vector3(EAST - 0.01, 2.55, wz(-4.1)), Vector3(EAST - 0.01, 2.55, wz(2.0)), Vector3(EAST - 0.01, 1.05, wz(2.0)), Vector3(EAST - 0.01, 1.05, wz(-4.1)),
		1.0, Vector2.ZERO, 0.0, "", "", Color(0.45, 0.2, 0.05))
	var bottle_cols := [Color(0.9, 0.55, 0.15), Color(0.25, 0.6, 0.2), Color(0.7, 0.75, 0.8), Color(0.55, 0.12, 0.1), Color(0.95, 0.8, 0.35)]
	var i := 0
	for y in [1.4, 1.9, 2.4]:
		_box(_b(zone, "veneer"), Vector3(13.33, y - 0.02, back_z), Vector3(0.32, 0.03, 6.1 * SCALE), vt)
		var bz := wz(-3.9)
		while bz < wz(1.85):
			var tall := 0.24 + 0.06 * ((i * 7) % 3)
			var col: Color = bottle_cols[(i * 3) % bottle_cols.size()]
			_cyl(_b(zone, "neon"), Vector3(13.33, y, bz), Vector3(13.33, y + tall * 0.7, bz), 0.035, 1.0, 8, false, -1.0, col * 0.6)
			_cyl(_b(zone, "neon"), Vector3(13.33, y + tall * 0.7, bz), Vector3(13.33, y + tall, bz), 0.035, 1.0, 8, true, 0.012, col * 0.6)
			bz += 0.16 + 0.05 * ((i * 5) % 3)
			i += 1
	# pendant lamps over the counter: two of them light
	for pz in [-3.1, -0.6, 1.9]:
		var p := Vector3(counter_x, 2.35, wz(pz))
		_cyl(_b(zone, "chrome"), p + Vector3(0, 0.12, 0), Vector3(p.x, 3.2, p.z), 0.006, 1.0, 6, false)
		_cyl(_b(zone, "gear"), p, p + Vector3(0, 0.14, 0), 0.16, 1.0, 16, false, 0.05)
		_cyl(_b(zone, "neon"), p + Vector3(0, 0.005, 0), p + Vector3(0, 0.006, 0), 0.15, 1.0, 16, true, -1.0, AMBER)
	_omni(zone, Vector3(counter_x, 2.1, wz(-2.4)), AMBER, 1.5, 4.5)
	_omni(zone, Vector3(counter_x, 2.1, wz(1.2)), AMBER, 1.5, 4.5)
	# high tables by the far walls
	var corner := wv(8.9, 2.3)
	_table(zone, corner, 0.32, 1.05)
	_stool(zone, corner + Vector2(0.55, 0.15))
	_perimeter(zone, 2.95, AMBER)


# ---- the VIP corridor and its private rooms ----------------------------------------------------------------------------------------

func _build_vip() -> void:
	# the corridor: velvet walls, a red glow along the foot of both walls, numbers over the doors
	_perimeter("vip", 0.05, RED, 0.02)
	_omni("vip", w3(-10.8, 2.5, -4.4), RED, 0.8, 6.5)
	var rooms := [["room1", -14.6], ["room2", -10.8], ["room3", -7.0]]
	var door_z := wz(-5.2)                  # the wall the doors are in
	for k in rooms.size():
		var zone: String = rooms[k][0]
		var dx := wx(rooms[k][1])           # the middle of the room's door
		var z: Array = zones_w[zone]
		var cx: float = (z[0] + z[2]) * 0.5
		var back := wz(NORTH)
		_sign("vip", str(k + 1), Vector3(dx, 2.6, door_z + 0.02), Vector3.BACK, ROSE)
		# a sofa against the back wall with a little table at its side, a glow behind it, a curtain drawn back from the door
		_prop(zone, "sofa_02", Vector2(cx, back + 0.52), 0.0)
		_table(zone, Vector2(cx + 1.35, back + 0.45), 0.24, 0.5)
		_glow(zone, Vector3(cx - 1.4, 1.25, back + 0.03), Vector3(cx + 1.4, 1.25, back + 0.03), PURPLE)
		_folds(_b(zone, "velvet"), Vector2(dx - 1.15, door_z - 0.07), Vector2(dx - 0.45, door_z - 0.07), Vector2(0, -1), 0.0, 2.35, 0.1, 6, _tile("velvet"))
		_cyl(_b(zone, "chrome"), Vector3(dx - 1.25, 2.38, door_z - 0.1), Vector3(dx + 0.7, 2.38, door_z - 0.1), 0.012, 1.0, 6, true)
		_omni(zone, Vector3(cx, 2.4, (back + door_z) * 0.5), ROSE, 1.5, 4.5)


# ---- the lounge ------------------------------------------------------------------------------------------------------------------------

# Booths along the south wall; two groups of sofas facing each other over a low table, a footstool at the end of each.
func _build_lounge() -> void:
	var zone := "lounge"
	for plan_x in [-14.7, -10.9, -7.1]:
		_booth(zone, wx(plan_x), wz(SOUTH) - 0.9)
	for plan_x in [-13.2, -8.4]:
		var c := wv(plan_x, -1.3)
		_prop(zone, "sofa_02", c + Vector2(0, -1.3), 0.0)
		_prop(zone, "sofa_02", c + Vector2(0, 1.3), 180.0)
		_prop(zone, "coffee_table_round_01", c, 0.0)
		_prop(zone, "Ottoman_01", c + Vector2(-1.55, 0), 90.0)
	_perimeter(zone, 2.95, PURPLE)
	_omni(zone, w3(-13.2, 2.8, -0.6), PURPLE, 1.6, 5.5)
	_omni(zone, w3(-8.4, 2.8, -0.6), Color(1.0, 0.35, 0.6), 1.6, 5.5)


# ---- environment -----------------------------------------------------------------------------------------------------------------------

func _build_environment() -> void:
	environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.45, 0.3, 0.7)
	environment.ambient_light_energy = 0.15
	environment.fog_enabled = true
	environment.fog_light_color = Color(0.07, 0.025, 0.1)
	environment.fog_density = 0.035
