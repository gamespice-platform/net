class_name GSNetSnapshotBatch
extends RefCounted
## GameSpice Sim's native snapshot batch ([code]GSSimSnapshotBatch[/code]): a client's whole-snapshot decode and push in one call, for remote entities whose per-entity work is data only. It does what [method GSNetManager._apply_entity] does for a remote one: decodes each behaviour's state into its properties and [code]_baseline[/code], calls [code]_net_state_applied[/code] (only where a value changed, with [member GSNetConfig.skip_unchanged_state_applied]), and pushes the interpolated values to [code]GSSimInterpolator[/code] (and to the GDScript track, when the interpolator keeps one).
## An entity it does not hold (not seen yet, predicted, or with a change handler, a script-read declaration or [member GSNetBehaviour.batch_writes] off) and any body it cannot decode the script's way is left to the script, so errors, logs and counters stay the script's. Optional like [GSNetSimCodec]: without gs-sim, with [member GSNetConfig.snapshot_batch] off, or without its interpolator, the per-entity loop runs alone. docs/native.md.

const CLASS := &"GSSimSnapshotBatch"

## Off for the whole process: for tests and measurements; a game turns it off with [member GSNetConfig.snapshot_batch].
static var enabled := true

var _native: Object
## net_id -> true: an entity that can never be held, not asked again until it is forgotten.
var _never := {}
## The arguments of [code]apply[/code], kept: ([code]bit, end bit, entities, id bits, tick[/code]).
var _args := PackedInt64Array([0, 0, 0, 0, 0])
## Whether the library takes a row's sixth element, [member GSNetBehaviour.state_applied_every_snapshot] (and skips unchanged hooks).
var _always_rows := false
## The [member GSNetConfig.skip_unchanged_state_applied] the library was last given, so a change at run time (a cvar) reaches it.
var _skip := false


## A batch for [param interpolator] (which must draw natively), or null where it cannot run.
static func create(config: GSNetConfig, interpolator: GSNetInterpolator) -> GSNetSnapshotBatch:
	if not enabled or not config.snapshot_batch or not config.sim_codec:
		return null
	if not interpolator.is_native() or not ClassDB.class_exists(CLASS):
		return null
	var batch := GSNetSnapshotBatch.new()
	batch._native = ClassDB.instantiate(CLASS)
	if batch._native == null:
		return null
	# A library older than the skip calls every hook, as the script did before API 26.
	batch._always_rows = batch._native.has_method(&"set_skip_unchanged_hooks")
	if batch._always_rows:
		batch._skip = config.skip_unchanged_state_applied
		batch._native.set_skip_unchanged_hooks(batch._skip)
	return batch


## Applies entities of [param reader]'s snapshot at [param tick] for [param interpolator] (which holds the batch, so the batch keeps no reference to it) until one is not the batch's. Returns how many of [param left] are still to read, the reader at the first of them.
func apply(interpolator: GSNetInterpolator, reader: GSNetReader, left: int, tick: int) -> int:
	var args := _args
	args[0] = reader._bit_pos
	args[1] = reader._end_bits
	args[2] = left
	args[3] = GSNetRegistry.ID_BITS
	args[4] = tick
	if _always_rows and interpolator.config.skip_unchanged_state_applied != _skip:
		_skip = not _skip
		_native.set_skip_unchanged_hooks(_skip)
	var out: PackedInt64Array = _native.apply(reader._bytes, args, interpolator._native)
	if out.size() != 2 or int(out[1]) >= left:
		return left
	reader._bit_pos = out[0]
	interpolator._note_timeline(tick)
	return out[1]


## Offers [param identity], just applied by the script, to the batch: held from the next snapshot on if all of it is the batch's to do.
func hold(interpolator: GSNetInterpolator, identity: GSNetIdentity) -> void:
	var net_id := identity.net_id
	if _never.has(net_id) or _native.has(net_id) or identity.is_predicted():
		return
	if not interpolator.has_track(net_id):
		return
	# Null when the library holds the only tracks (GSNetInterpolator._native_only).
	var track: Object = interpolator._tracks.get(net_id)

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
		# Hooked only when the script overrides the inherited no-op ([method GSNetBehaviour.listens_state_applied]).
		var row := [behaviour, codec, names, flags, behaviour.listens_state_applied()]
		if _always_rows:
			row.append(behaviour.state_applied_every_snapshot)
		parts.append(row)

	if not _native.register(net_id, parts, track):
		_never[net_id] = true
		return
	# A new owner may make it predicted: the script takes it from there.
	var changed := _on_owner_changed.bind(net_id)
	if not identity.owner_changed.is_connected(changed):
		identity.owner_changed.connect(changed)


## The net ids the last [method apply] changed a value of, in wire order (empty with a library older than API 26).
func last_changed() -> PackedInt64Array:
	return _native.last_changed() if _always_rows else PackedInt64Array()


## How many [code]_net_state_applied[/code] calls [member GSNetConfig.skip_unchanged_state_applied] saved in this batch.
func hooks_skipped() -> int:
	return _native.hooks_skipped() if _always_rows else 0


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

