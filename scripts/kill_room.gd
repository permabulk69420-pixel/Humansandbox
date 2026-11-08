# The room: a grimy tiled basement with a steel table under a swinging lamp, built from scratch out of boxes and tubes with CC0 Poly
# Haven PBR textures and a handful of Poly Haven props. Everything solid has collision (layer 1), so props you add later just need to be
# children of `props` (or made with add_prop()).
#
# The geometry is batched by material, so the whole shell is about ten draw calls. Lighting is deliberately sparse: one swinging lamp over
# the table (the only light with shadows), a flickering fluorescent, a red emergency lamp by the door and a red glow behind it. There is no
# baked lighting, and no post-processing, because the Quest's Compatibility renderer pays for both.
class_name KillRoom
extends Node3D

# ---- the room, in metres ---------------------------------------------------------------------------------------------------------------
const X0 := -4.0
const X1 := 4.0
const Z0 := -8.0
const Z1 := 3.0
const H := 3.2
const TILE_TOP := 1.6               # wall tiles reach this high, then a trim strip, then plaster
const TRIM := 0.06
const DOOR_X0 := -2.05
const DOOR_X1 := -0.95
const DOOR_H := 2.15
const WALL_T := 0.4                  # how thick the walls are (the collision slabs outside the room)
const HALL_W := 2.4                  # the hallway behind the door runs along the north wall, this wide...
const HALL_RUN := 15.0               # ...and this far each way from the door
const HALL_X0 := (DOOR_X0 + DOOR_X1) * 0.5 - HALL_RUN
const HALL_X1 := (DOOR_X0 + DOOR_X1) * 0.5 + HALL_RUN
const HALL_ZS := Z0 - WALL_T         # its south wall: the back of the room's north wall
const HALL_ZN := Z0 - WALL_T - HALL_W   # its north wall
const BEAM_Z: Array[float] = [-7.0, -4.9, -0.7, 1.4]    # steel beams under the ceiling, wall to wall
const BEAM_DROP := 0.26

const TEX := "res://assets/room/textures/%s/%s_%s.jpg"
const MODEL := "res://assets/room/models/%s/%s.gltf"

# ---- lights ----------------------------------------------------------------------------------------------------------------------------
const LAMP_POS := Vector3(0.2, H, -2.6)
const TABLE_POS := Vector3(0.2, 0.0, -3.5)
const TABLE_TOP := 0.957             # the table's top surface, for collision and for things set down on it
const KNIFE_SHELF_TOP := 0.64
const SHELF_BOARD := 1.145           # the board of the steel shelves the radio sits on (the boards are at 0.135, 0.64, 1.145, 1.65 m)
const LAMP_SCALE := 0.8             # the Poly Haven lamp comes with a 1.3 m chain: shortened so the shade hangs above head height
const LAMP_ENERGY := 3.2
const TUBE_POS := Vector3(-1.8, H, -6.1)
const RED_WALL_POS := Vector3(-2.7, 2.15, Z0)

# name -> [texture id, tile size in metres (the real-world size of the texture), tint]
const MATERIALS := {
	"floor": ["concrete_floor_damaged_01", 3.0, Color(0.72, 0.78, 0.8)],
	"tile": ["long_white_tiles", 1.27, Color(0.74, 0.78, 0.72)],
	"plaster": ["worn_plaster_wall", 1.8, Color(0.82, 0.8, 0.72)],
	"ceiling": ["concrete_layers_02", 2.0, Color(0.5, 0.5, 0.5)],
	"steel": ["rusty_metal_04", 2.0, Color(0.8, 0.8, 0.8)],
	"pipe": ["rust_coarse_01", 2.2, Color(0.8, 0.8, 0.8)],
	"door": ["green_metal_rust", 1.0, Color(0.85, 0.85, 0.85)],
	"tabletop": ["rusty_metal_sheet", 2.0, Color(0.62, 0.62, 0.58)],
	"leather": ["brown_leather", 0.4, Color(0.8, 0.8, 0.8)],
}

class Batch:
	var st := SurfaceTool.new()
	var material: Material
	func _init(m: Material) -> void:
		material = m
		st.begin(Mesh.PRIMITIVE_TRIANGLES)

var props: Node3D
var collision_root: Node3D
var radio: Radio
var torch: Blowtorch
var knife: KitchenKnife
var door: HingedDoor
var _materials := {}
var _batches := {}
var _noise := FastNoiseLite.new()

# animated things
var _swing: Node3D
var _lamp_light: SpotLight3D
var _lamp_emissive: Array[BaseMaterial3D] = []
var _tube_light: OmniLight3D
var _tube_emissive: Array[BaseMaterial3D] = []
var _red_lights: Array[OmniLight3D] = []
var _t := 0.0
var _lamp_next := 4.0
var _lamp_dim_until := 0.0
var _tube_next := 6.0
var _tube_burst_until := 0.0
var _tube_step := 0.0
var _tube_level := 1.0


func _ready() -> void:
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 0.45
	_noise.fractal_octaves = 3
	_noise.seed = 7
	collision_root = Node3D.new()
	collision_root.name = "Collision"
	add_child(collision_root)
	props = Node3D.new()
	props.name = "Props"
	add_child(props)
	_make_materials()
	_build_shell()
	_build_beams()
	_build_pipes()
	_build_table()
	_build_table(Vector3(X0 + 0.5, 0.0, -5.2), "TableWest")      # a second one along the west wall
	_build_rail()
	_build_rail(X1 - 1.3, -3.4, 1.6)      # a second rail down the east side
	_build_door()
	_build_hallway()
	_flush_batches()
	_build_environment()
	_build_lights()
	_build_props()
	_build_stains()


func _process(delta: float) -> void:
	_t += delta
	if _swing == null:
		return
	# the lamp sways a little, as if there were a draught
	_swing.rotation = Vector3(sin(_t * 1.9) * 0.03 + sin(_t * 0.7) * 0.02, 0.0, sin(_t * 1.6 + 1.3) * 0.035 + sin(_t * 0.5) * 0.015)
	var f := 0.94 + 0.06 * sin(_t * 23.0 + sin(_t * 3.1) * 4.0)
	if _t > _lamp_next:
		_lamp_dim_until = _t + randf_range(0.12, 0.4)
		_lamp_next = _t + randf_range(4.0, 11.0)
	if _t < _lamp_dim_until:
		f *= 0.2 + 0.25 * randf()
	_lamp_light.light_energy = LAMP_ENERGY * f
	for m in _lamp_emissive:
		m.emission_energy_multiplier = 1.5 * f
	# the fluorescent holds steady, then stutters for a moment
	if _t > _tube_next:
		_tube_burst_until = _t + randf_range(0.5, 0.9)
		_tube_next = _t + randf_range(6.0, 16.0)
	if _t < _tube_burst_until:
		if _t > _tube_step:
			_tube_level = 1.0 if randf() > 0.5 else 0.06
			_tube_step = _t + randf_range(0.04, 0.11)
	else:
		_tube_level = 1.0
	var tube := _tube_level * (0.96 + 0.04 * sin(_t * 90.0))
	_tube_light.light_energy = 1.1 * tube
	for m in _tube_emissive:
		m.emission_energy_multiplier = 1.0 * tube
	for r in _red_lights:
		r.light_energy = 0.55 + 0.3 * sin(_t * 1.3)


# ---- materials -------------------------------------------------------------------------------------------------------------------------

func _make_materials() -> void:
	for key in MATERIALS:
		var d: Array = MATERIALS[key]
		var id: String = d[0]
		var m := ORMMaterial3D.new()
		m.albedo_texture = load(TEX % [id, id, "diff"])
		m.albedo_color = d[2]
		m.normal_enabled = true
		m.normal_texture = load(TEX % [id, id, "nor"])
		m.orm_texture = load(TEX % [id, id, "arm"])
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		m.vertex_color_use_as_albedo = true
		_materials[key] = m


func _batch(key: String) -> Batch:
	if not _batches.has(key):
		_batches[key] = Batch.new(_materials[key])
	return _batches[key]


func _tile(key: String) -> float:
	return MATERIALS[key][1]


# ---- geometry helpers ------------------------------------------------------------------------------------------------------------------

static func _bil(tl: Vector3, tr: Vector3, bl: Vector3, br: Vector3, u: float, v: float) -> Vector3:
	return tl.lerp(tr, u).lerp(bl.lerp(br, u), v)


func _grime(p: Vector3, kind: String) -> Color:
	var n := _noise.get_noise_3dv(p * 1.3) * 0.5 + 0.5
	var k := 1.0
	match kind:
		"wall":
			k = lerpf(0.5, 1.0, smoothstep(0.0, 1.5, p.y)) * lerpf(1.0, 0.7, smoothstep(2.3, H, p.y)) * lerpf(0.72, 1.08, n)
		"floor":
			var d := minf(minf(p.x - X0, X1 - p.x), minf(p.z - Z0, Z1 - p.z))
			k = lerpf(0.58, 1.0, smoothstep(0.0, 1.0, d)) * lerpf(0.7, 1.08, n)
		"ceiling":
			var d := minf(minf(p.x - X0, X1 - p.x), minf(p.z - Z0, Z1 - p.z))
			k = lerpf(0.5, 1.0, smoothstep(0.0, 0.9, d)) * lerpf(0.6, 1.05, n)
	return Color(k, k, k)


func _v(b: Batch, p: Vector3, n: Vector3, uv: Vector2, c: Color) -> void:
	b.st.set_color(c)
	b.st.set_normal(n)
	b.st.set_uv(uv)
	b.st.add_vertex(p)


# A rectangle given as top-left, top-right, bottom-right, bottom-left as seen from its front (so the corners run clockwise when you look at
# the side that is drawn). Cut into cells so the vertex colours can carry grime.
func _quad(b: Batch, tl: Vector3, tr: Vector3, br: Vector3, bl: Vector3, tile: float, uv_origin := Vector2.ZERO, cell := 0.0, kind := "") -> void:
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
			var pa := _bil(tl, tr, bl, br, fu0, fv0)
			var pb := _bil(tl, tr, bl, br, fu1, fv0)
			var pc := _bil(tl, tr, bl, br, fu1, fv1)
			var pd := _bil(tl, tr, bl, br, fu0, fv1)
			var ua := uv_origin + Vector2(fu0 * w, fv0 * h) / tile
			var ub := uv_origin + Vector2(fu1 * w, fv0 * h) / tile
			var uc := uv_origin + Vector2(fu1 * w, fv1 * h) / tile
			var ud := uv_origin + Vector2(fu0 * w, fv1 * h) / tile
			var ca := _grime(pa, kind)
			var cb := _grime(pb, kind)
			var cc := _grime(pc, kind)
			var cd := _grime(pd, kind)
			_v(b, pa, n, ua, ca)
			_v(b, pb, n, ub, cb)
			_v(b, pc, n, uc, cc)
			_v(b, pa, n, ua, ca)
			_v(b, pc, n, uc, cc)
			_v(b, pd, n, ud, cd)


# An axis-aligned box (optionally turned and moved by `xf`) with outward faces.
func _box(b: Batch, center: Vector3, size: Vector3, tile: float, xf := Transform3D.IDENTITY) -> void:
	var h := size * 0.5
	var lo := center - h
	var hi := center + h
	var c := func(x: float, y: float, z: float) -> Vector3: return xf * Vector3(x, y, z)
	# +x, -x, +z, -z, top, bottom (each as seen from outside)
	_quad(b, c.call(hi.x, hi.y, hi.z), c.call(hi.x, hi.y, lo.z), c.call(hi.x, lo.y, lo.z), c.call(hi.x, lo.y, hi.z), tile)
	_quad(b, c.call(lo.x, hi.y, lo.z), c.call(lo.x, hi.y, hi.z), c.call(lo.x, lo.y, hi.z), c.call(lo.x, lo.y, lo.z), tile)
	_quad(b, c.call(lo.x, hi.y, hi.z), c.call(hi.x, hi.y, hi.z), c.call(hi.x, lo.y, hi.z), c.call(lo.x, lo.y, hi.z), tile)
	_quad(b, c.call(hi.x, hi.y, lo.z), c.call(lo.x, hi.y, lo.z), c.call(lo.x, lo.y, lo.z), c.call(hi.x, lo.y, lo.z), tile)
	_quad(b, c.call(lo.x, hi.y, lo.z), c.call(hi.x, hi.y, lo.z), c.call(hi.x, hi.y, hi.z), c.call(lo.x, hi.y, hi.z), tile)
	_quad(b, c.call(hi.x, lo.y, lo.z), c.call(lo.x, lo.y, lo.z), c.call(lo.x, lo.y, hi.z), c.call(hi.x, lo.y, hi.z), tile)


# A tapered cylinder from p0 to p1.
func _cyl(b: Batch, p0: Vector3, p1: Vector3, r0: float, tile: float, sides := 12, caps := true, r1 := -1.0) -> void:
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
		var bl := p0 + n0 * r0
		var br := p0 + n1 * r0
		var tr := p1 + n1 * r1
		var tl := p1 + n0 * r1
		var ua := a0 / TAU * (TAU * r0) / tile
		var ub := a1 / TAU * (TAU * r0) / tile
		var vl := length / tile
		_v(b, tl, n0, Vector2(ua, 0.0), Color.WHITE)
		_v(b, tr, n1, Vector2(ub, 0.0), Color.WHITE)
		_v(b, br, n1, Vector2(ub, vl), Color.WHITE)
		_v(b, tl, n0, Vector2(ua, 0.0), Color.WHITE)
		_v(b, br, n1, Vector2(ub, vl), Color.WHITE)
		_v(b, bl, n0, Vector2(ua, vl), Color.WHITE)
		if caps:
			for end in 2:
				var cen := p0 if end == 0 else p1
				var rr := r0 if end == 0 else r1
				var nn := -dir if end == 0 else dir
				var q0 := cen + n0 * rr
				var q1 := cen + n1 * rr
				var uv0 := Vector2(0.5, 0.5) + Vector2(cos(a0), sin(a0)) * rr / tile
				var uv1 := Vector2(0.5, 0.5) + Vector2(cos(a1), sin(a1)) * rr / tile
				if end == 0:
					_v(b, cen, nn, Vector2(0.5, 0.5), Color.WHITE)
					_v(b, q0, nn, uv0, Color.WHITE)
					_v(b, q1, nn, uv1, Color.WHITE)
				else:
					_v(b, cen, nn, Vector2(0.5, 0.5), Color.WHITE)
					_v(b, q1, nn, uv1, Color.WHITE)
					_v(b, q0, nn, uv0, Color.WHITE)


# A round bar swept along a polyline (hooks, cables).
func _tube(b: Batch, pts: PackedVector3Array, r: float, tile: float, sides := 8) -> void:
	var count := pts.size()
	var tangents: Array[Vector3] = []
	for i in count:
		var t: Vector3
		if i == 0:
			t = pts[1] - pts[0]
		elif i == count - 1:
			t = pts[i] - pts[i - 1]
		else:
			t = pts[i + 1] - pts[i - 1]
		tangents.append(t.normalized())
	var ref := Vector3.UP if absf(tangents[0].dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var u := tangents[0].cross(ref).normalized()
	var ring_p: Array = []
	var ring_n: Array = []
	var dist: Array[float] = []
	var run := 0.0
	for i in count:
		if i > 0:
			run += pts[i].distance_to(pts[i - 1])
			u = (u - tangents[i] * u.dot(tangents[i])).normalized()
		var v := tangents[i].cross(u)
		var rp := PackedVector3Array()
		var rn := PackedVector3Array()
		for k in sides:
			var a := TAU * k / sides
			var nrm := u * cos(a) + v * sin(a)
			rp.append(pts[i] + nrm * r)
			rn.append(nrm)
		ring_p.append(rp)
		ring_n.append(rn)
		dist.append(run)
	for i in count - 1:
		for k in sides:
			var k2 := (k + 1) % sides
			var ua := float(k) / sides * TAU * r / tile
			var ub := float(k + 1) / sides * TAU * r / tile
			var tl: Vector3 = ring_p[i + 1][k]
			var tr: Vector3 = ring_p[i + 1][k2]
			var br: Vector3 = ring_p[i][k2]
			var bl: Vector3 = ring_p[i][k]
			var nl: Vector3 = ring_n[i + 1][k]
			var nr: Vector3 = ring_n[i + 1][k2]
			var nbl: Vector3 = ring_n[i][k]
			var nbr: Vector3 = ring_n[i][k2]
			var v0 := dist[i] / tile
			var v1 := dist[i + 1] / tile
			_v(b, tl, nl, Vector2(ua, v1), Color.WHITE)
			_v(b, tr, nr, Vector2(ub, v1), Color.WHITE)
			_v(b, br, nbr, Vector2(ub, v0), Color.WHITE)
			_v(b, tl, nl, Vector2(ua, v1), Color.WHITE)
			_v(b, br, nbr, Vector2(ub, v0), Color.WHITE)
			_v(b, bl, nbl, Vector2(ua, v0), Color.WHITE)


func _commit(b: Batch) -> ArrayMesh:
	b.st.generate_tangents()
	b.st.set_material(b.material)
	return b.st.commit()


func _flush_batches() -> void:
	for key in _batches:
		var mi := MeshInstance3D.new()
		mi.name = "Room_" + key
		mi.mesh = _commit(_batches[key])
		add_child(mi)
	_batches.clear()


func _static_box(box_name: String, center: Vector3, size: Vector3, parent: Node = null) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = box_name
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = center
	(parent if parent != null else collision_root).add_child(body)
	return body


# ---- the shell -------------------------------------------------------------------------------------------------------------------------

# A wall piece between two points on the floor plan, as seen from inside the room: `left` is on your left. Tile below, a trim strip,
# plaster above.
func _wall(left: Vector2, right: Vector2, ya: float, yb: float, store = null) -> void:
	var spans := [["tile", 0.0, TILE_TOP], ["steel", TILE_TOP, TILE_TOP + TRIM], ["plaster", TILE_TOP + TRIM, H]]
	for s in spans:
		var lo := maxf(ya, s[1])
		var hi := minf(yb, s[2])
		if hi - lo < 0.001:
			continue
		var key: String = s[0]
		var tl := Vector3(left.x, hi, left.y)
		var tr := Vector3(right.x, hi, right.y)
		var br := Vector3(right.x, lo, right.y)
		var bl := Vector3(left.x, lo, left.y)
		var tile := _tile(key)
		var target: Batch = _batch(key)
		if store != null:
			if not store.has(key):
				store[key] = Batch.new(_materials[key])
			target = store[key]
		_quad(target, tl, tr, br, bl, tile, Vector2(left.x + left.y, s[2] - hi) / tile, 0.5, "wall" if key != "steel" else "")


func _build_shell() -> void:
	# floor and ceiling
	_quad(_batch("floor"), Vector3(X0, 0, Z0), Vector3(X1, 0, Z0), Vector3(X1, 0, Z1), Vector3(X0, 0, Z1), _tile("floor"), Vector2.ZERO, 0.5, "floor")
	_quad(_batch("ceiling"), Vector3(X0, H, Z1), Vector3(X1, H, Z1), Vector3(X1, H, Z0), Vector3(X0, H, Z0), _tile("ceiling"), Vector2.ZERO, 0.5, "ceiling")
	# walls, each as seen from inside
	_wall(Vector2(X0, Z0), Vector2(DOOR_X0, Z0), 0.0, H)          # north, left of the door
	_wall(Vector2(DOOR_X1, Z0), Vector2(X1, Z0), 0.0, H)          # north, right of the door
	_wall(Vector2(DOOR_X0, Z0), Vector2(DOOR_X1, Z0), DOOR_H, H)  # north, over the door
	_wall(Vector2(X1, Z1), Vector2(X0, Z1), 0.0, H)               # south
	_wall(Vector2(X0, Z1), Vector2(X0, Z0), 0.0, H)               # west
	_wall(Vector2(X1, Z0), Vector2(X1, Z1), 0.0, H)               # east
	# collision: thick slabs outside the room, so nothing gets through a corner
	var t := WALL_T
	var w := X1 - X0
	var l := Z1 - Z0
	_static_box("Floor", Vector3(0, -t * 0.5, (Z0 + Z1) * 0.5), Vector3(w + 2 * t, t, l + 2 * t))
	_static_box("Ceiling", Vector3(0, H + t * 0.5, (Z0 + Z1) * 0.5), Vector3(w + 2 * t, t, l + 2 * t))
	_static_box("WallSouth", Vector3(0, H * 0.5, Z1 + t * 0.5), Vector3(w + 2 * t, H, t))
	_static_box("WallWest", Vector3(X0 - t * 0.5, H * 0.5, (Z0 + Z1) * 0.5), Vector3(t, H, l))
	_static_box("WallEast", Vector3(X1 + t * 0.5, H * 0.5, (Z0 + Z1) * 0.5), Vector3(t, H, l))
	_static_box("WallNorthLeft", Vector3((X0 + DOOR_X0) * 0.5 - t * 0.5, H * 0.5, Z0 - t * 0.5), Vector3(DOOR_X0 - X0 + t, H, t))
	_static_box("WallNorthRight", Vector3((DOOR_X1 + X1) * 0.5 + t * 0.5, H * 0.5, Z0 - t * 0.5), Vector3(X1 - DOOR_X1 + t, H, t))
	_static_box("WallNorthLintel", Vector3((DOOR_X0 + DOOR_X1) * 0.5, (DOOR_H + H) * 0.5, Z0 - t * 0.5), Vector3(DOOR_X1 - DOOR_X0, H - DOOR_H, t))


func _build_beams() -> void:
	var steel := _batch("steel")
	var tile := _tile("steel")
	for z in BEAM_Z:
		var len := X1 - X0 + 0.2          # runs a little into both walls
		_box(steel, Vector3(0, H - 0.0125, z), Vector3(len, 0.025, 0.17), tile)                     # top flange
		_box(steel, Vector3(0, H - BEAM_DROP * 0.5, z), Vector3(len, BEAM_DROP - 0.05, 0.014), tile)   # web
		_box(steel, Vector3(0, H - BEAM_DROP + 0.0125, z), Vector3(len, 0.025, 0.17), tile)         # bottom flange
		_static_box("Beam", Vector3(0, H - BEAM_DROP * 0.5, z), Vector3(X1 - X0, BEAM_DROP, 0.17))


func _build_pipes() -> void:
	var pipe := _batch("pipe")
	var tile := _tile("pipe")
	# two pipes along the west wall, with brackets, running into the walls at each end
	var runs := [[2.78, 0.05, 0.14], [2.5, 0.032, 0.11]]
	for r in runs:
		var y: float = r[0]
		var rad: float = r[1]
		var off: float = r[2]
		_cyl(pipe, Vector3(X0 + off, y, Z0 - 0.1), Vector3(X0 + off, y, Z1 + 0.1), rad, tile, 12, false)
		var z := Z0 + 0.8
		while z < Z1:
			_box(_batch("steel"), Vector3(X0 + off * 0.5, y, z), Vector3(off, rad * 2.2, 0.05), _tile("steel"))
			z += 1.6
		# flanged joints
		var jz := Z0 + 2.4
		while jz < Z1:
			_cyl(pipe, Vector3(X0 + off, y, jz - 0.03), Vector3(X0 + off, y, jz + 0.03), rad * 1.45, tile, 12, true)
			jz += 3.8
	_static_box("PipesWest", Vector3(X0 + 0.15, 2.64, (Z0 + Z1) * 0.5), Vector3(0.3, 0.42, Z1 - Z0))
	# one pipe along the east wall and one along the south wall, the same kind, above the shelves
	_cyl(pipe, Vector3(X1 - 0.12, 2.55, Z0 - 0.1), Vector3(X1 - 0.12, 2.55, Z1 + 0.1), 0.04, tile, 12, false)
	_cyl(pipe, Vector3(X0 - 0.1, 2.65, Z1 - 0.12), Vector3(X1 + 0.1, 2.65, Z1 - 0.12), 0.045, tile, 12, false)
	var bz := Z0 + 1.2
	while bz < Z1:
		_box(_batch("steel"), Vector3(X1 - 0.06, 2.55, bz), Vector3(0.12, 0.09, 0.05), _tile("steel"))
		_cyl(pipe, Vector3(X1 - 0.12, 2.55, bz - 0.03), Vector3(X1 - 0.12, 2.55, bz + 0.03), 0.058, tile, 12, true)
		bz += 1.8
	var bx := X0 + 1.4
	while bx < X1:
		_box(_batch("steel"), Vector3(bx, 2.65, Z1 - 0.06), Vector3(0.05, 0.1, 0.12), _tile("steel"))
		bx += 1.7
	_static_box("PipesEast", Vector3(X1 - 0.15, 2.55, (Z0 + Z1) * 0.5), Vector3(0.3, 0.3, Z1 - Z0))
	_static_box("PipesSouth", Vector3((X0 + X1) * 0.5, 2.65, Z1 - 0.15), Vector3(X1 - X0, 0.3, 0.3))


func _build_table(c := TABLE_POS, label := "Table") -> void:
	var steel := _batch("steel")
	var top := _batch("tabletop")
	var leather := _batch("leather")
	var len := 2.1
	var wid := 0.9
	var h := 0.92
	_box(top, c + Vector3(0, h, 0), Vector3(wid, 0.07, len), _tile("tabletop"))
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			_box(steel, c + Vector3(sx * (wid * 0.5 - 0.06), h * 0.5 - 0.02, sz * (len * 0.5 - 0.08)), Vector3(0.07, h - 0.05, 0.07), _tile("steel"))
	_box(steel, c + Vector3(0, 0.3, 0), Vector3(wid - 0.1, 0.03, len - 0.14), _tile("steel"))        # lower shelf
	_box(steel, c + Vector3(0, h - 0.07, 0), Vector3(wid - 0.08, 0.06, len - 0.08), _tile("steel"))  # frame under the top
	# a raised lip round the edge
	_box(steel, c + Vector3(0, h + 0.045, len * 0.5 - 0.015), Vector3(wid, 0.03, 0.03), _tile("steel"))
	_box(steel, c + Vector3(0, h + 0.045, -len * 0.5 + 0.015), Vector3(wid, 0.03, 0.03), _tile("steel"))
	_box(steel, c + Vector3(wid * 0.5 - 0.015, h + 0.045, 0), Vector3(0.03, 0.03, len), _tile("steel"))
	_box(steel, c + Vector3(-wid * 0.5 + 0.015, h + 0.045, 0), Vector3(0.03, 0.03, len), _tile("steel"))
	# leather straps across the table
	for sz in [-0.62, -0.05, 0.55]:
		_box(leather, c + Vector3(0, h + 0.043, sz), Vector3(wid + 0.06, 0.012, 0.07), _tile("leather"))
	_static_box(label, c + Vector3(0, TABLE_TOP * 0.5, 0), Vector3(wid, TABLE_TOP, len))     # solid up to the top surface, so things sit on it


# An overhead rail with hooks hanging from it on chains.
func _build_rail(rx := X0 + 1.3, z0 := Z0 + 0.8, z1 := Z1 - 0.8) -> void:
	var steel := _batch("steel")
	var tile := _tile("steel")
	var ry := H - 0.38
	_box(steel, Vector3(rx, ry, (z0 + z1) * 0.5), Vector3(0.07, 0.1, z1 - z0), tile)
	var z := z0 + 0.3
	while z < z1:
		_cyl(steel, Vector3(rx, ry + 0.05, z), Vector3(rx, H, z), 0.012, tile, 6, false)    # hanger rods up to the ceiling
		z += 1.9
	var drops := [0.55, 0.8, 0.45, 0.7, 0.6, 0.9]
	var hz := z0 + 0.5
	var i := 0
	while hz < z1 - 0.2:
		var d: float = drops[i % drops.size()]
		_cyl(steel, Vector3(rx, ry - 0.05, hz), Vector3(rx, ry - 0.05 - d, hz), 0.008, tile, 6, false)   # chain
		# the hook: a J swept below the chain
		var y := ry - 0.05 - d
		var pts := PackedVector3Array()
		pts.append(Vector3(rx, y + 0.02, hz))
		pts.append(Vector3(rx, y - 0.1, hz))
		for a in range(0, 181, 30):
			var ang := deg_to_rad(float(a))
			pts.append(Vector3(rx, y - 0.1 - 0.07 * sin(ang), hz + 0.07 - 0.07 * cos(ang)))
		pts.append(Vector3(rx, y - 0.04, hz + 0.14 + 0.01))
		_tube(steel, pts, 0.011, tile, 8)
		hz += 1.05
		i += 1
	_static_box("Rail", Vector3(rx, ry, (z0 + z1) * 0.5), Vector3(0.12, 0.14, z1 - z0))


func _build_door() -> void:
	var steel := _batch("steel")
	var tile := _tile("steel")
	var dw := DOOR_X1 - DOOR_X0
	var cx := (DOOR_X0 + DOOR_X1) * 0.5
	# frame
	_box(steel, Vector3(DOOR_X0 - 0.05, DOOR_H * 0.5, Z0 + 0.04), Vector3(0.1, DOOR_H, 0.12), tile)
	_box(steel, Vector3(DOOR_X1 + 0.05, DOOR_H * 0.5, Z0 + 0.04), Vector3(0.1, DOOR_H, 0.12), tile)
	_box(steel, Vector3(cx, DOOR_H + 0.05, Z0 + 0.04), Vector3(dw + 0.2, 0.1, 0.12), tile)
	# the door itself, hinged on the right
	var db := Batch.new(_materials["door"])
	var dt := _tile("door")
	_box(db, Vector3(-dw * 0.5 + 0.0, DOOR_H * 0.5 - 0.02, 0.0), Vector3(dw - 0.02, DOOR_H - 0.05, 0.06), dt)
	# a steel lever handle on each face, at the latch edge, pointing back along the door towards the hinge
	var hb := Batch.new(_materials["steel"])
	var ht := _tile("steel")
	var hx := -dw + 0.09
	for side in [1.0, -1.0]:
		_cyl(hb, Vector3(hx, 1.05, side * 0.03), Vector3(hx, 1.05, side * 0.046), 0.032, ht, 16, true)          # rose
		_cyl(hb, Vector3(hx, 1.05, side * 0.046), Vector3(hx, 1.05, side * 0.092), 0.012, ht, 10, true)       # stem
		_cyl(hb, Vector3(hx, 1.05, side * 0.092), Vector3(hx + 0.14, 1.05, side * 0.092), 0.0105, ht, 10, true) # lever
		_cyl(hb, Vector3(hx + 0.14, 1.05, side * 0.092), Vector3(hx + 0.15, 1.05, side * 0.092), 0.0105, ht, 10, true, 0.007)
	door = HingedDoor.new()
	door.name = "Door"
	door.position = Vector3(DOOR_X1 - 0.01, 0.02, Z0 + 0.03)
	door.handles.append(Vector3(hx + 0.07, 1.05, 0.092))      # the middle of each lever
	door.handles.append(Vector3(hx + 0.07, 1.05, -0.092))
	var dmi := MeshInstance3D.new()
	dmi.mesh = _commit(db)
	door.add_child(dmi)
	var hmi := MeshInstance3D.new()
	hmi.name = "DoorHandles"
	hmi.mesh = _commit(hb)
	door.add_child(hmi)
	add_child(door)
	_static_box("DoorSlab", Vector3(-dw * 0.5, DOOR_H * 0.5, 0.0), Vector3(dw - 0.02, DOOR_H - 0.05, 0.1), door)


# ---- the hallway ----------------------------------------------------------------------------------------------------------------------

# The hallway behind the door: it runs along the north wall, both ways, in short pieces. Each piece is its own mesh so that it only catches
# the few lights near it (a lit mesh can take 8 lights at a time in this renderer, and the room's big meshes already take several).
func _build_hallway() -> void:
	var c := (DOOR_X0 + DOOR_X1) * 0.5
	var edges: Array[float] = [c - HALL_RUN]
	var step := (HALL_RUN - 2.5) / 3.0
	for i in 3:
		edges.append(edges[-1] + step)
	edges.append(c + 2.5)                  # the piece the door is in is 5 m wide, centred on it
	for i in 3:
		edges.append(edges[-1] + step)
	var ft := _tile("floor")
	var ct := _tile("ceiling")
	for i in edges.size() - 1:
		var xa := edges[i]
		var xb := edges[i + 1]
		var has_door := xa < DOOR_X0 and xb > DOOR_X1
		var zs := Z0 if has_door else HALL_ZS        # floor and ceiling run on through the doorway
		var floor_b := Batch.new(_materials["floor"])
		var ceil_b := Batch.new(_materials["ceiling"])
		var walls := {}                              # the room's own tile, trim and plaster, in this piece's own meshes
		_quad(floor_b, Vector3(xa, 0, HALL_ZN), Vector3(xb, 0, HALL_ZN), Vector3(xb, 0, zs), Vector3(xa, 0, zs), ft, Vector2(xa, HALL_ZN) / ft, 0.5, "floor")
		_quad(ceil_b, Vector3(xa, H, zs), Vector3(xb, H, zs), Vector3(xb, H, HALL_ZN), Vector3(xa, H, HALL_ZN), ct, Vector2(xa, HALL_ZN) / ct, 0.5, "ceiling")
		_wall(Vector2(xa, HALL_ZN), Vector2(xb, HALL_ZN), 0.0, H, walls)            # north wall, as seen from inside the hallway
		if has_door:
			# the back of the room's wall, with the doorway cut out of it
			_wall(Vector2(DOOR_X0, HALL_ZS), Vector2(xa, HALL_ZS), 0.0, H, walls)
			_wall(Vector2(xb, HALL_ZS), Vector2(DOOR_X1, HALL_ZS), 0.0, H, walls)
			_wall(Vector2(DOOR_X1, HALL_ZS), Vector2(DOOR_X0, HALL_ZS), DOOR_H, H, walls)
			# the thickness of the wall round the doorway
			_quad(ceil_b, Vector3(DOOR_X0, DOOR_H, Z0), Vector3(DOOR_X0, DOOR_H, HALL_ZS), Vector3(DOOR_X0, 0, HALL_ZS), Vector3(DOOR_X0, 0, Z0), 2.0)
			_quad(ceil_b, Vector3(DOOR_X1, DOOR_H, HALL_ZS), Vector3(DOOR_X1, DOOR_H, Z0), Vector3(DOOR_X1, 0, Z0), Vector3(DOOR_X1, 0, HALL_ZS), 2.0)
			_quad(ceil_b, Vector3(DOOR_X0, DOOR_H, Z0), Vector3(DOOR_X1, DOOR_H, Z0), Vector3(DOOR_X1, DOOR_H, HALL_ZS), Vector3(DOOR_X0, DOOR_H, HALL_ZS), 2.0)
		else:
			_wall(Vector2(xb, HALL_ZS), Vector2(xa, HALL_ZS), 0.0, H, walls)
		if i == 0:                                   # the west end
			_wall(Vector2(xa, HALL_ZS), Vector2(xa, HALL_ZN), 0.0, H, walls)
		if i == edges.size() - 2:                    # the east end
			_wall(Vector2(xb, HALL_ZN), Vector2(xb, HALL_ZS), 0.0, H, walls)
		var batches: Array = [floor_b, ceil_b]
		batches.append_array(walls.values())
		for b in batches:
			var mi := MeshInstance3D.new()
			mi.name = "Hallway%d" % i
			mi.mesh = _commit(b)
			add_child(mi)
	# solid walls, floor and ceiling, so nothing goes through them
	var mid_z := (HALL_ZN + HALL_ZS) * 0.5
	var span_x := HALL_X1 - HALL_X0
	_static_box("HallNorth", Vector3((HALL_X0 + HALL_X1) * 0.5, H * 0.5, HALL_ZN - 0.3), Vector3(span_x + 1.2, H, 0.6))
	_static_box("HallWest", Vector3(HALL_X0 - 0.3, H * 0.5, (HALL_ZN - 0.6 + Z0) * 0.5), Vector3(0.6, H, Z0 - HALL_ZN + 0.6))
	_static_box("HallEast", Vector3(HALL_X1 + 0.3, H * 0.5, (HALL_ZN - 0.6 + Z0) * 0.5), Vector3(0.6, H, Z0 - HALL_ZN + 0.6))
	var west_len := (X0 - WALL_T) - (HALL_X0 - 0.6)
	var east_len := (HALL_X1 + 0.6) - (X1 + WALL_T)
	_static_box("HallSouthWest", Vector3(HALL_X0 - 0.6 + west_len * 0.5, H * 0.5, HALL_ZS + 0.3), Vector3(west_len, H, 0.6))
	_static_box("HallSouthEast", Vector3(X1 + WALL_T + east_len * 0.5, H * 0.5, HALL_ZS + 0.3), Vector3(east_len, H, 0.6))
	_static_box("HallFloor", Vector3((HALL_X0 + HALL_X1) * 0.5, -0.2, (HALL_ZN + Z0) * 0.5), Vector3(span_x + 1.2, 0.4, Z0 - HALL_ZN + 0.6))
	_static_box("HallCeiling", Vector3((HALL_X0 + HALL_X1) * 0.5, H + 0.2, (HALL_ZN + Z0) * 0.5), Vector3(span_x + 1.2, 0.4, Z0 - HALL_ZN + 0.6))
	# a caged light every 5 m down the middle, the same cold green as the one by the door; the ends are left dark
	for k in range(-2, 3):
		var x := c + 5.0 * k
		var fixture := _load_model("caged_hanging_light")
		if fixture != null:
			fixture.position = Vector3(x, H, mid_z)
			add_child(fixture)
			_set_shadows(fixture, false)
		var lamp := OmniLight3D.new()
		lamp.name = "HallLight%d" % (k + 2)
		lamp.position = Vector3(x, H - 0.7, mid_z)
		lamp.light_color = Color(0.7, 1.0, 0.82)
		lamp.light_energy = 0.85
		lamp.omni_range = 5.5
		add_child(lamp)


# ---- environment and lights ------------------------------------------------------------------------------------------------------------

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.0, 0.0, 0.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.32, 0.4, 0.42)
	env.ambient_light_energy = 0.15
	env.fog_enabled = true
	env.fog_light_color = Color(0.05, 0.065, 0.06)
	env.fog_density = 0.03
	var we := WorldEnvironment.new()
	we.name = "Environment"
	we.environment = env
	add_child(we)


func _build_lights() -> void:
	# the lamp over the table: the Poly Haven lamp on a pivot at the ceiling, with a spotlight in its shade
	_swing = Node3D.new()
	_swing.name = "LampSwing"
	_swing.position = LAMP_POS
	add_child(_swing)
	var lamp := _load_model("hanging_industrial_lamp")
	if lamp != null:
		lamp.scale = Vector3.ONE * LAMP_SCALE
		_swing.add_child(lamp)
		_set_shadows(lamp, false)
		_lamp_emissive = _emissive_materials(lamp)
	_lamp_light = SpotLight3D.new()
	_lamp_light.name = "LampLight"
	_lamp_light.position = Vector3(0, -1.34 * LAMP_SCALE + 0.2, 0)
	_lamp_light.rotation_degrees = Vector3(-90, 0, 0)
	_lamp_light.light_color = Color(1.0, 0.78, 0.55)
	_lamp_light.light_energy = LAMP_ENERGY
	_lamp_light.spot_range = 9.0
	_lamp_light.spot_angle = 62.0
	_lamp_light.spot_attenuation = 0.8
	_lamp_light.shadow_enabled = true
	_lamp_light.shadow_bias = 0.04
	_lamp_light.shadow_normal_bias = 1.5
	_swing.add_child(_lamp_light)
	# the fluorescent by the door, cold and sick-green
	var tube := _load_model("caged_hanging_light")
	if tube != null:
		tube.position = TUBE_POS
		tube.rotation_degrees.y = 90.0
		add_child(tube)
		_set_shadows(tube, false)
		_tube_emissive = _emissive_materials(tube)
	_tube_light = OmniLight3D.new()
	_tube_light.name = "TubeLight"
	_tube_light.position = TUBE_POS + Vector3(0, -0.7, 0)
	_tube_light.light_color = Color(0.7, 1.0, 0.82)
	_tube_light.light_energy = 1.1
	_tube_light.omni_range = 7.0
	add_child(_tube_light)
	# a red caged lamp on the wall beside the door, and a red glow from inside the corridor
	var wall_lamp := _load_model("industrial_wall_lamp")
	if wall_lamp != null:
		wall_lamp.position = RED_WALL_POS
		wall_lamp.rotation_degrees.y = 0.0
		add_child(wall_lamp)
		_set_shadows(wall_lamp, false)
	var red := OmniLight3D.new()
	red.name = "RedWallLight"
	red.position = RED_WALL_POS + Vector3(0, 0, 0.35)
	red.light_color = Color(1.0, 0.12, 0.08)
	red.light_energy = 0.55
	red.omni_range = 4.0
	add_child(red)
	_red_lights.append(red)
	var glow := OmniLight3D.new()
	glow.name = "CorridorGlow"
	glow.position = Vector3((DOOR_X0 + DOOR_X1) * 0.5, 1.7, Z0 - 0.9)
	glow.light_color = Color(1.0, 0.1, 0.06)
	glow.light_energy = 0.7
	glow.omni_range = 3.2
	add_child(glow)
	_red_lights.append(glow)


# ---- props -----------------------------------------------------------------------------------------------------------------------------

func _build_props() -> void:
	add_prop("steel_frame_shelves_01", Vector3(X1 - 0.3, 0, -5.4), -90.0, false, true, 2.14)
	# the shelves are solid boards you can stand things on (not one box): 0.5 m deep, 1.1 m wide
	for top in [0.135, KNIFE_SHELF_TOP, SHELF_BOARD, 1.65]:
		_static_box("ShelfBoard%d" % int(top * 1000.0), Vector3(X1 - 0.3, top - 0.015, -5.4), Vector3(0.5, 0.03, 1.1))
	add_prop("industrial_storage_cart", Vector3(X0 + 0.7, 0, -1.2), 90.0, true, true, 0.95)
	add_prop("BarberShopChair_01", Vector3(-2.6, 0, -3.6), 90.0)
	add_prop("wheelchair_01", Vector3(-2.9, 0, 1.7), 140.0)
	add_prop("metal_stool_01", Vector3(-0.95, 0, -4.1), 15.0)
	add_prop("wooden_bucket_01", Vector3(1.6, 0, -3.9), 0.0)
	# the south and east walls
	add_prop("metal_tool_chest", Vector3(X1 - 0.4, 0, 0.4), -90.0)
	add_prop("Barrel_01", Vector3(X1 - 0.5, 0, 2.3), 0.0)
	add_prop("Barrel_02", Vector3(X1 - 1.25, 0, 2.5), 40.0)
	add_prop("wooden_crate_01", Vector3(-1.4, 0, Z1 - 0.5), 10.0)
	add_prop("wooden_crate_01", Vector3(-0.6, 0, Z1 - 0.5), -15.0)
	add_prop("metal_jerrycan", Vector3(0.6, 0, Z1 - 0.3), 25.0)
	add_prop("wooden_crate_02", Vector3(X1 - 0.4, 0.01, -2.7), 0.0)
	add_prop("wooden_crate_02", Vector3(X1 - 0.42, 0.47, -2.7), 4.0, false)
	add_prop("trashbag", Vector3(X0 + 0.5, 0, Z1 - 0.4), 20.0)
	add_prop("trashbag", Vector3(X0 + 1.05, 0, Z1 - 0.3), 75.0)
	# a metal rack against the south wall
	add_prop("worn_metal_rack", Vector3(1.7, 0, Z1 - 0.35), 180.0)
	# a hammer and a hacksaw on the west table, between its straps (the flat tools are modelled standing up, so they are laid down)
	var hammer := add_prop("cross_pein_hammer", Vector3(X0 + 0.5, TABLE_TOP + 0.012, -4.95), 0.0, false)
	hammer.rotation_degrees = Vector3(-90.0, 25.0, 0.0)
	var saw := add_prop("rusted_hacksaw", Vector3(X0 + 0.5, TABLE_TOP + 0.02, -5.55), 0.0, false)
	saw.rotation_degrees = Vector3(-90.0, -15.0, 0.0)
	add_prop("rubber_boots", Vector3(-0.5, 0, -7.35), 20.0, false)
	add_prop("old_gas_mask", Vector3(X1 - 0.14, 1.8, -1.0), -90.0, false)       # hung on the east wall
	# the radio on the shelves, facing into the room, shrunk 5% so its antenna clears the board above
	radio = Radio.new()
	radio.name = "Radio"
	radio.model_scale = 0.95
	radio.position = Vector3(X1 - 0.38, SHELF_BOARD + 0.002, -5.25)
	radio.rotation_degrees.y = -90.0
	props.add_child(radio)
	# the blowtorch standing on the same shelf as the radio, nozzle out into the room
	torch = Blowtorch.new()
	torch.name = "Blowtorch"
	torch.position = Vector3(X1 - 0.38, SHELF_BOARD + 0.006, -5.7)
	torch.rotation_degrees.y = 90.0
	props.add_child(torch)
	# Rest flat on the clear lower shelf, below the radio and blowtorch.
	knife = KitchenKnife.new()
	knife.name = "KitchenKnife"
	knife.position = Vector3(X1 - 0.38, KNIFE_SHELF_TOP + 0.012, -5.55)
	knife.rotation = Vector3(0.0, 0.2, PI / 2.0)
	props.add_child(knife)


# ---- stains ----------------------------------------------------------------------------------------------------------------------------

# Dried blood so the room looks used: soft-edged blotches made from noise (no texture files), laid a hair above the floor, and spatter on
# the tiled walls.
func _stain_texture(seed_value: int, spatter: bool) -> ImageTexture:
	var size := 192
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 0.045 if not spatter else 0.16
	noise.fractal_octaves = 4
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var half := size * 0.5
	for y in size:
		for x in size:
			var d := Vector2(x - half, y - half).length() / half
			var n := noise.get_noise_2d(x, y) * 0.5 + 0.5
			var a: float
			if spatter:
				a = clampf((n - 0.62) * 9.0, 0.0, 1.0) * clampf((1.0 - d) * 2.5, 0.0, 1.0)
			else:
				a = clampf((1.0 - d * 1.05 + (n - 0.5) * 1.5) * 3.0, 0.0, 1.0)
			var shade := 0.5 + 0.5 * n
			img.set_pixel(x, y, Color(0.22 * shade, 0.012, 0.01, a * 0.85))
	return ImageTexture.create_from_image(img)


func _stain(tex: Texture2D, center: Vector3, size: Vector2, yaw_degrees: float, normal := Vector3.UP) -> void:
	var mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = size
	mi.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.3
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = center
	if normal == Vector3.UP:
		mi.rotation_degrees.y = yaw_degrees
	elif normal == Vector3.LEFT:      # on the east wall, facing into the room
		mi.rotation_degrees = Vector3(0.0, yaw_degrees, 90.0)
	else:                              # on the west wall, facing east
		mi.rotation_degrees = Vector3(0.0, yaw_degrees, -90.0)
	props.add_child(mi)


func _build_stains() -> void:
	var pool_a := _stain_texture(11, false)
	var pool_b := _stain_texture(29, false)
	var spatter := _stain_texture(53, true)
	# a big dried pool beside the table, and a smaller one by the chair
	_stain(pool_a, Vector3(0.55, 0.008, -3.2), Vector2(1.9, 1.9), 20.0)
	_stain(pool_b, Vector3(-2.15, 0.008, -3.1), Vector2(1.3, 1.3), 70.0)
	# a drag trail from the table to the door
	var from := Vector2(0.1, -4.5)
	var to := Vector2(-1.5, -7.2)
	for i in 7:
		var t := float(i) / 6.0
		var at := from.lerp(to, t)
		var w := 0.9 - 0.45 * t
		_stain(pool_a if i % 2 == 0 else pool_b, Vector3(at.x, 0.009, at.y), Vector2(w, w * 1.3), 25.0 + 30.0 * float(i))
	# spatter on the tiles: behind the bed (west wall) and above the crates (east wall)
	_stain(spatter, Vector3(X0 + 0.012, 1.0, -5.0), Vector2(1.5, 1.2), 0.0, Vector3.RIGHT)
	_stain(spatter, Vector3(X1 - 0.012, 1.15, -2.7), Vector2(1.3, 1.1), 0.0, Vector3.LEFT)


# Puts a Poly Haven model into the room. `pos` is where its base (or, for the lamp, its top) goes.
func add_prop(id: String, pos: Vector3, yaw_degrees := 0.0, collide := true, shadows := true, height := 0.0) -> Node3D:
	var model := _load_model(id)
	if model == null:
		return null
	if height > 0.0:
		# some Poly Haven models import at the wrong size: `height` is how tall the thing really is, in metres
		var size := _local_bounds(model).size
		if size.y > 0.001:
			model.scale = Vector3.ONE * (height / size.y)
	model.position = pos
	model.rotation_degrees.y = yaw_degrees
	props.add_child(model)
	if not shadows:
		_set_shadows(model, false)
	if collide:
		_collide_bounds(model)
	return model


func _load_model(id: String) -> Node3D:
	var scene := load(MODEL % [id, id]) as PackedScene
	if scene == null:
		push_warning("missing model " + id)
		return null
	var node := scene.instantiate() as Node3D
	apply_anisotropic(node)
	return node


# Imported materials use plain mipmapped filtering, which blurs anything seen at a slant (a floor stretching away from you): the project's
# anisotropic filtering setting only applies to materials that ask for it.
static func apply_anisotropic(root: Node) -> void:
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var node := mi as MeshInstance3D
		if node.mesh == null:
			continue
		for i in node.mesh.get_surface_count():
			var mat := node.get_active_material(i)
			if mat is BaseMaterial3D:
				(mat as BaseMaterial3D).texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC


static func _set_shadows(root: Node, on: bool) -> void:
	for gi in root.find_children("*", "GeometryInstance3D", true, false):
		(gi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


static func _emissive_materials(root: Node) -> Array[BaseMaterial3D]:
	var out: Array[BaseMaterial3D] = []
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var node := mi as MeshInstance3D
		for i in node.mesh.get_surface_count():
			var mat := node.get_active_material(i)
			if mat is BaseMaterial3D and (mat as BaseMaterial3D).emission_enabled and not out.has(mat):
				out.append(mat)
	return out


# The bounds of everything in a model, in the model's own space.
func _local_bounds(model: Node3D) -> AABB:
	var bounds := AABB()
	var first := true
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var node := mi as MeshInstance3D
		var rel := Transform3D.IDENTITY
		var walker: Node = node
		while walker != model and walker != null:
			rel = (walker as Node3D).transform * rel
			walker = walker.get_parent()
		var box := rel * node.get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
	return bounds


# One solid box around a model, so you cannot walk through it (and the punch code has something to hit later).
func _collide_bounds(model: Node3D) -> void:
	var bounds := _local_bounds(model)
	if bounds.size == Vector3.ZERO:
		return
	var body := StaticBody3D.new()
	body.name = "Collision"
	var shape := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = bounds.size
	shape.shape = bx
	shape.position = bounds.get_center()
	body.add_child(shape)
	model.add_child(body)
