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
