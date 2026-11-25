class_name GSNetInterpTrack
extends RefCounted

## One entity's recent states for [GSNetInterpolator], ordered by tick.

## Samples kept per entity.
##
## Enough to cover the buffer plus a burst of out-of-order arrivals.
const CAPACITY := 32

var net_id: int
## Array of {tick, at_ms, values}
var samples: Array[Dictionary] = []
## What [method GSNetInterpolator.apply] writes: the behaviours it was built for, their
## declaration counts, and each one's interpolated properties in declaration order.
var plan_behaviours: Array = []
var plan_sizes := PackedInt32Array()
var plan_props: Array = []
## What [method GSNetInterpolator.apply] still adds to each position it draws: the
## part of a jump out of an extrapolation not yet eased away. property -> Vector3/2.
var offsets: Dictionary = {}
## The two samples the last drawn frame extrapolated from, or empty when it was
## between two samples. See [method GSNetInterpolator._ease_resume].
var ahead_from: Array[Dictionary] = []
## The settled skip's reference ([member GSNetConfig.skip_settled_interp]): the draw written in
## [member drawn_frame], emptied by [method push] (its snapshot hooks may have written over it).
var drawn: Dictionary = {}
var drawn_frame: int = -1

func _init(p_net_id: int) -> void:
	net_id = p_net_id

func push(tick: int, values: Dictionary) -> void:
	# Out-of-order arrivals are normal on an unreliable channel. Inserting in
	# tick order rather than appending means the bracket search stays a simple
	# scan, and a late packet still contributes rather than being discarded.
	drawn = {}
	var entry := {
		"tick": tick,
		"at_ms": Time.get_ticks_msec(),
		"values": values,
	}

	var index := samples.size()
	while index > 0 and int(samples[index - 1]["tick"]) > tick:
		index -= 1

	if index > 0 and int(samples[index - 1]["tick"]) == tick:
		# A duplicate tick, usually a retransmit. Merge rather than replace:
		# a delta only carries changed properties.
		var existing: Dictionary = samples[index - 1]["values"]
		for property in values:
			existing[property] = values[property]
		return

	samples.insert(index, entry)

	while samples.size() > CAPACITY:
		samples.pop_front()

## [method push] for an entity whose state did not change: a sample at [param tick] with the newest sample's values, copied. False, with nothing done, when there is no older sample to repeat (the caller pushes the values itself).
func push_repeat(tick: int, at_ms: int) -> bool:
	if samples.is_empty():
		return false
	var newest: Dictionary = samples[samples.size() - 1]
	if int(newest["tick"]) >= tick:
		return false
	drawn = {}
	samples.append({
		"tick": tick,
		"at_ms": at_ms,
		"values": (newest["values"] as Dictionary).duplicate(),
	})
	while samples.size() > CAPACITY:
		samples.pop_front()
	return true

func newest_tick() -> int:
	return int(samples[samples.size() - 1]["tick"]) if not samples.is_empty() else -1

func oldest_tick() -> int:
	return int(samples[0]["tick"]) if not samples.is_empty() else -1

func is_empty() -> bool:
	return samples.is_empty()

## [method GSNetInterpolator.value_at]'s answer from this track: [param property] at [param render_tick], the bracketing samples blended.
func value_at(property: StringName, render_tick: float, cut: float = 0.0) -> Variant:
	if samples.is_empty():
		return null
	var last := samples.size() - 1
	if render_tick >= float(samples[last]["tick"]):
		return (samples[last]["values"] as Dictionary).get(property)
	if render_tick < float(samples[0]["tick"]):
		return null
	for i in range(last):
		var newer_tick := float(samples[i + 1]["tick"])
		if render_tick > newer_tick:
			continue
		if cut > 0.0 and _jumps_after(samples, i, property, cut):
			return null
		var older_tick := float(samples[i]["tick"])
		var a: Variant = (samples[i]["values"] as Dictionary).get(property)
		var b: Variant = (samples[i + 1]["values"] as Dictionary).get(property)
		if a == null or b == null:
			return b if b != null else a
		var alpha := 0.0 if newer_tick <= older_tick else (render_tick - older_tick) / (newer_tick - older_tick)
		if (a is Vector3 and b is Vector3) or (a is Vector2 and b is Vector2) or (a is float and b is float):
			return lerp(a, b, alpha)
		return a if alpha < 0.5 else b
	return (samples[last]["values"] as Dictionary).get(property)

## [method GSNetInterpolator.value_between]'s answer from this track.
func value_between(property: StringName, older_tick: int, newer_tick: int, render_tick: float, cut: float = 0.0) -> Variant:
	if samples.is_empty():
		return null
	var i := -1
	var j := -1
	for k in range(samples.size()):
		var t := int(samples[k]["tick"])
		if t == older_tick:
			i = k
		if t == newer_tick:
			j = k
	if i < 0 or j < 0:
		return null
	# Only a jump inside the bracket cuts it: the server's rewind knows no teleport past the
	# newer tick it was asked about, so one the client has since received must not null this.
	if cut > 0.0 and _jumps_after(samples, i, property, cut, j):
		return null
	var a: Variant = (samples[i]["values"] as Dictionary).get(property)
	var b: Variant = (samples[j]["values"] as Dictionary).get(property)
	if a == null or b == null:
		return b if b != null else a
	var alpha := 0.0 if newer_tick <= older_tick else clampf((render_tick - float(older_tick)) / float(newer_tick - older_tick), 0.0, 1.0)
	if (a is Vector3 and b is Vector3) or (a is Vector2 and b is Vector2) or (a is float and b is float):
		return lerp(a, b, alpha)
	return a if alpha < 0.5 else b

## Whether [param property] moves further than [param cut] between any two neighbouring
## samples from index [param from] on (to index [param to] when it is not -1): a teleport
## [method value_at] does not reach across.
static func _jumps_after(rows: Array, from: int, property: StringName, cut: float, to := -1) -> bool:
	var before: Variant = null
	var end := rows.size() if to < 0 else mini(to + 1, rows.size())
	for j in range(from, end):
		var now: Variant = (rows[j]["values"] as Dictionary).get(property)
		if now == null:
			continue
		if before != null and ((now is Vector3 and before is Vector3) or (now is Vector2 and before is Vector2)):
			if (now - before).length() > cut:
				return true
		before = now
	return false
