class_name GSNetSnapshotBatch
extends RefCounted
## GameSpice Sim's native snapshot batch ([code]GSSimSnapshotBatch[/code]): a client's whole-snapshot decode and push in one call, for the remote entities whose per-entity work is
## data only. For each such entity the native side does what [method GSNetManager._apply_entity] does for a remote one: every behaviour's state decoded and written to its
## properties and [code]_baseline[/code], its [code]_net_state_applied[/code] hook called, the interpolated values pushed to the track and to [code]GSSimInterpolator[/code].
##
## An entity it does not hold (not seen yet, predicted, or with a change handler, a script-read declaration or [member GSNetBehaviour.batch_writes] off) and any body it
## cannot decode the script's way is left to the script with the reader back at that entity, so errors, logs and counters stay the script's. Optional like [GSNetSimCodec]:
## without gs-sim, with [member GSNetConfig.snapshot_batch] off, or without its interpolator, the per-entity loop runs alone. docs/native.md.

const CLASS := &"GSSimSnapshotBatch"

## Off for the whole process: for tests and measurements; a game turns it off with [member GSNetConfig.snapshot_batch].
static var enabled := true

var _native: Object
var _interpolator: GSNetInterpolator
## net_id -> true: an entity that can never be held, not asked again until it is forgotten.
var _never := {}
## The arguments of [code]apply[/code], kept: ([code]bit, end bit, entities, id bits, tick[/code]).
var _args := PackedInt64Array([0, 0, 0, 0, 0])


## A batch for [param interpolator] (which must draw natively), or null where it cannot run.
static func create(config: GSNetConfig, interpolator: GSNetInterpolator) -> GSNetSnapshotBatch:
	if not enabled or not config.snapshot_batch or not config.sim_codec:
		return null
	if not interpolator.is_native() or not ClassDB.class_exists(CLASS):
		return null
	var batch := GSNetSnapshotBatch.new()
	batch._native = ClassDB.instantiate(CLASS)
	batch._interpolator = interpolator
	return batch if batch._native != null else null


## Applies entities of [param reader]'s snapshot at [param tick] until one is not the batch's. Returns how many of [param left] are still to read, the reader at the first of them.
func apply(reader: GSNetReader, left: int, tick: int) -> int:
	var args := _args
	args[0] = reader._bit_pos
	args[1] = reader._end_bits
	args[2] = left
	args[3] = GSNetRegistry.ID_BITS
	args[4] = tick
	var out: PackedInt64Array = _native.apply(reader._bytes, args, _interpolator._native)
	if out.size() != 2 or int(out[1]) >= left:
		return left
	reader._bit_pos = out[0]
	_interpolator._note_timeline(tick)
	return out[1]


## Offers [param identity], just applied by the script, to the batch: held from the next snapshot on if all of it is the batch's to do.
func hold(identity: GSNetIdentity) -> void:
	var net_id := identity.net_id
	if _never.has(net_id) or _native.has(net_id) or identity.is_predicted():
		return
	var track: Object = _interpolator._tracks.get(net_id)
	if track == null:
		return

	var parts: Array = []
	for behaviour in identity.behaviours:
		if not behaviour.is_bound():
			return
		var codec: Object = behaviour._sim_codec
		var names: Array = []
		var flags := PackedByteArray()
		for i in range(behaviour.net_vars.size()):
			var declaration := behaviour.net_vars[i]
			if codec == null or not codec.is_native(i) or declaration.change_handler.is_valid():
				_never[net_id] = true
				return
			names.append(declaration.property)
			flags.append(1 if declaration.interpolate else 0)
		if not behaviour.batch_writes:
			_never[net_id] = true
			return
		# Always hooked: a script's override cannot be told from the inherited no-op (a script's method list holds both).
		parts.append([behaviour, codec, names, flags, true])

	if not _native.register(net_id, parts, track):
		_never[net_id] = true
		return
	# A new owner may make it predicted: the script takes it from there.
	var changed := _on_owner_changed.bind(net_id)
	if not identity.owner_changed.is_connected(changed):
		identity.owner_changed.connect(changed)


func has(net_id: int) -> bool:
	return _native.has(net_id)


func size() -> int:
	return _native.size()


func forget(net_id: int) -> void:
	_native.forget(net_id)
	_never.erase(net_id)


func clear() -> void:
	_native.clear()
	_never.clear()


func _on_owner_changed(_old: int, _new: int, net_id: int) -> void:
	forget(net_id)

