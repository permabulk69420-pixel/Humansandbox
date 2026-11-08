# Grip picks up the nearest free handle; trigger lights the blowtorch; fingers can flick the radio's switch.
# It works on any hand state VrHands has, so it needs nothing but a controller that can answer get_float("grip") and get_float("trigger").
class_name HandInteractions
extends RefCounted

const GRAB_ON := 0.65                  # squeeze this far to pick something up...
const GRAB_OFF := 0.35                 # ...and let go below this
const GRAB_RADIUS := 0.14              # metres from the torch's handle a hand can be and still take it

var hands: VrHands
var radio: Radio
var torch: Blowtorch
var knife: KitchenKnife
var _last_squeeze := {}


func _init(p_hands: VrHands, p_radio: Radio, p_torch: Blowtorch, p_knife: KitchenKnife = null) -> void:
	hands = p_hands
	radio = p_radio
	torch = p_torch
	knife = p_knife


# Call once a frame, before VrHands.update() so the poses it chooses are used straight away.
func update(dt: float) -> void:
	for s in hands.states:
		var hand: String = s.handedness
		var held_prop = null
		for prop in [torch, knife]:
			if prop != null and prop.held_by == hand:
				held_prop = prop
		if not s.tracked():
			if held_prop != null:
				held_prop.release()
				s.hold = null
			_last_squeeze.erase(hand)
			continue
		var squeeze: float = s.squeeze()
		var trigger: float = s.trigger()
		var was: float = _last_squeeze.get(hand, 0.0)
		_last_squeeze[hand] = squeeze
		var holding := held_prop != null
		if holding:
			if held_prop == torch:
				torch.set_trigger(trigger)
			if squeeze < GRAB_OFF:
				held_prop.release()
				s.hold = null
				holding = false
		elif squeeze > GRAB_ON and was <= GRAB_ON:
			var nearest = null
			var distance := GRAB_RADIUS
			for prop in [torch, knife]:
				if prop == null or prop.held_by != "":
					continue
				var candidate: float = prop.grab_distance(s.controller.global_position)
				if candidate < distance:
					nearest = prop
					distance = candidate
			if nearest != null:
				nearest.grab(hand, s.controller)
				if nearest.held_by == hand:
					s.hold = nearest.finger_amounts(hand)
					s.hold_blend = 0.0
					holding = true
		if holding:
			continue
		if radio != null:
			radio.poke(hand, s.model.index_tip(), dt)
