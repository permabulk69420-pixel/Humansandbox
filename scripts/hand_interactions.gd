# What the hands do with the things in the room: pick up the blowtorch (grip button), light it (trigger), flick the radio's switch.
# It works on any hand state VrHands has, so it needs nothing but a controller that can answer get_float("grip") and get_float("trigger").
class_name HandInteractions
extends RefCounted

const GRAB_ON := 0.65                  # squeeze this far to pick something up...
const GRAB_OFF := 0.35                 # ...and let go below this
const GRAB_RADIUS := 0.14              # metres from the torch's handle a hand can be and still take it

var hands: VrHands
var radio: Radio
var torch: Blowtorch
var _last_squeeze := {}


func _init(p_hands: VrHands, p_radio: Radio, p_torch: Blowtorch) -> void:
	hands = p_hands
	radio = p_radio
	torch = p_torch


# Call once a frame, before VrHands.update() so the poses it chooses are used straight away.
func update(dt: float) -> void:
	for s in hands.states:
		if not s.tracked():
			continue
		var hand: String = s.handedness
		var squeeze: float = s.squeeze()
		var trigger: float = s.trigger()
		var was: float = _last_squeeze.get(hand, 0.0)
		_last_squeeze[hand] = squeeze
		var holding := torch != null and torch.held_by == hand
		if holding:
			torch.set_trigger(trigger)
			if squeeze < GRAB_OFF:
				torch.release()
				s.hold = null
				holding = false
		elif torch != null and torch.held_by == "" and squeeze > GRAB_ON and was <= GRAB_ON:
			if torch.grab_distance(s.controller.global_position) < GRAB_RADIUS:
				torch.grab(hand, s.controller)
				if torch.held_by == hand:
					s.hold = torch.finger_amounts(hand)
					s.hold_blend = 0.0
					holding = true
		if holding:
			continue
		if radio != null:
			radio.poke(hand, s.model.index_tip(), dt)
