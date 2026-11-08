# Offline input to solve_knife_grip.py: posed skin samples in the same grip frame used by VrHands.
extends SceneTree

func _init() -> void:
	run.call_deferred()

func run() -> void:
	var out_dir: String = OS.get_cmdline_user_args()[0]
	for side in ["left", "right"]:
		var hand := HandModel.create(side)
		var anchor := Node3D.new()
		anchor.basis = Basis(Vector3.BACK, VrHands.GRIP_ROTATION[side])
		anchor.position = -(anchor.basis * hand.skeleton.get_bone_global_rest(hand.grip_bone).origin)
		root.add_child(anchor)
		anchor.add_child(hand.root)
		hand.prepare_skinning()
		var bone_part := {}
		var joints := {}
		for finger in HandModel.FINGERS:
			joints[finger] = []
			for bone: int in hand.finger_bones[finger]:
				bone_part[bone] = finger
				joints[finger].append([bone, hand.end_rotation("Open", bone), hand.end_rotation("Grip", bone), hand.end_rotation("Fist", bone)])
		var parts := {"palm": [], "thumb": [], "index": [], "middle": [], "ring": [], "pinky": []}
		var labels := []
		for i in hand.verts.size():
			var weight := -1.0
			var chosen := -1
			for ch in 4:
				var w := hand.vert_weights[i * 4 + ch]
				if w > weight:
					weight = w
					chosen = hand.skin_bone[hand.vert_bones[i * 4 + ch]]
			labels.append(bone_part.get(chosen, "palm"))
		# Vertex, edge-midpoint and face-centre samples prevent a thin blade slipping between vertices.
		for i in hand.verts.size():
			parts[labels[i]].append([i])
		for t in range(0, hand.triangles.size(), 3):
			var tri := [hand.triangles[t], hand.triangles[t + 1], hand.triangles[t + 2]]
			var touched := {}
			for v in tri:
				touched[labels[v]] = true
			for part in touched:
				parts[part].append(tri)
				for e in 3:
					parts[part].append([tri[e], tri[(e + 1) % 3]])
		var metadata := {"steps": 41, "parts": {}}
		var f := FileAccess.open(out_dir + "/" + side + ".bin", FileAccess.WRITE)
		for part in parts:
			metadata.parts[part] = {"count": parts[part].size(), "offset": f.get_position()}
			for step in 41:
				var amount := float(step) / 40.0
				for finger in joints:
					for j in joints[finger]:
						hand.set_joint(j[0], amount, j[1], j[2], j[3])
				var matrices := hand.skin_matrices()
				var pts := PackedVector3Array()
				for i in hand.verts.size():
					pts.append(hand.skeleton.global_transform * hand.skinned_vertex(i, matrices))
				for sample in parts[part]:
					var p := Vector3.ZERO
					for v in sample:
						p += pts[v]
					p /= sample.size()
					f.store_float(p.x)
					f.store_float(p.y)
					f.store_float(p.z)
		f.close()
		var meta := FileAccess.open(out_dir + "/" + side + ".json", FileAccess.WRITE)
		meta.store_string(JSON.stringify(metadata))
		anchor.free()
		print("Sampled ", side)
	quit()
