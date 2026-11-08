# The vintage tabletop radio (assets/props/radio/creepy_tabletop_radio.glb). Move a hand up to the power switch and it plays the song;
# flick it again and it stops (and picks up where it left off the next time). The switch is the model's own PowerSwitch pivot, moved by
# its Power_On / Power_Off clips.
#
# The printed labels put ON above the switch and OFF below it, but the model's Power_On clip swings the lever DOWN, so the clips are used
# the way round that matches the labels: the lever goes up for on, down for off.
class_name Radio
extends Node3D

signal switched(is_on: bool)

const MODEL := "res://assets/props/radio/creepy_tabletop_radio.glb"
const SONG := "res://assets/audio/creepysong.mp3"
const CLIP_LEVER_UP := "Power_Off"      # starts down, ends up: the lever's swing to ON
const CLIP_LEVER_DOWN := "Power_On"     # starts up, ends down: the lever's swing to OFF
const LEVER_TIP := Vector3(0.0, 0.0, 0.010)      # the end of the lever mesh, in the lever's own space
const FLICK_REACH := 0.045              # a fingertip that comes this close to the lever flicks it
const COOLDOWN := 0.5                   # seconds before the lever can be flipped again

var model_scale := 1.0                   # set before adding to the scene: how big the set is, relative to the model
var is_on := false
var model: Node3D
var lever: Node3D
var player: AnimationPlayer
var song: AudioStreamPlayer3D
var click: AudioStreamPlayer3D
var _song_started := false
var _cooldown := 0.0
var _near := {}                          # hand -> whether its fingertip was at the lever last frame


func _ready() -> void:
	model = (load(MODEL) as PackedScene).instantiate()
	model.scale = Vector3.ONE * model_scale
	add_child(model)
	KillRoom.apply_anisotropic(model)
	lever = model.find_child("PowerSwitch", true, false)
	player = model.find_child("AnimationPlayer", true, false)
	# it starts off, with the lever down
	player.play(CLIP_LEVER_DOWN)
	player.seek(player.current_animation_length, true)
	player.pause()

	song = AudioStreamPlayer3D.new()
	song.name = "Song"
	var stream := load(SONG) as AudioStreamMP3
	stream.loop = true
	song.stream = stream
	song.position = Vector3(-0.07, 0.1, 0.03) * model_scale       # the speaker, behind the grille
	song.unit_size = 14.0
	song.max_distance = 30.0
	song.volume_db = -3.0
	song.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	add_child(song)
	click = AudioStreamPlayer3D.new()
	click.name = "Click"
	click.stream = _make_click()
	click.position = lever.position * model_scale
	click.unit_size = 2.0
	click.volume_db = 2.0
	add_child(click)

	# a solid box round the set, so things you drop or throw cannot go through it
	var body := StaticBody3D.new()
	body.name = "Collision"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.32, 0.2, 0.15) * model_scale
	shape.shape = box
	shape.position = Vector3(0.0, 0.1, 0.01) * model_scale
	body.add_child(shape)
	add_child(body)


func _process(delta: float) -> void:
	_cooldown = maxf(0.0, _cooldown - delta)


# Where the end of the lever is in the world right now.
func lever_tip() -> Vector3:
	return lever.get_child(0).global_transform * LEVER_TIP if lever.get_child_count() > 0 else lever.global_position


func power(on: bool) -> void:
	if on == is_on:
		return
	is_on = on
	_cooldown = COOLDOWN
	player.play(CLIP_LEVER_UP if on else CLIP_LEVER_DOWN)
	click.play()
	if on:
		if _song_started:
			song.stream_paused = false
		else:
			song.play()
			_song_started = true
	else:
		song.stream_paused = true
	switched.emit(on)


func toggle() -> void:
	power(not is_on)


# One hand's fingertip this frame (a world position). Returns true when it flipped the switch: a fingertip coming up to the lever flicks it.
func poke(hand: String, tip: Vector3, _dt: float) -> bool:
	var was_near: bool = _near.get(hand, true)
	var near := tip.distance_to(lever_tip()) < FLICK_REACH
	_near[hand] = near
	if near and not was_near and _cooldown <= 0.0:
		toggle()
		return true
	return false


# A short mechanical "clack", made in code.
static func _make_click() -> AudioStreamWAV:
	var rate := 22050
	var length := int(rate * 0.09)
	var data := PackedByteArray()
	data.resize(length * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in length:
		var t := float(i) / rate
		var thump := sin(TAU * 170.0 * t) * exp(-t * 60.0)
		var snap := rng.randf_range(-1.0, 1.0) * exp(-t * 220.0) * 0.8
		data.encode_s16(i * 2, int(clampf(thump * 0.6 + snap, -1.0, 1.0) * 32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.data = data
	return stream
