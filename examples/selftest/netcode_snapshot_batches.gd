extends "netcode_unchanged_and_lossy_lead.gd"

## Sections of netcode_demo.gd: the client snapshot batches, each against the script path.


func _test_snapshot_batches() -> void:
	_unchanged_batch_parity()
	_snapshot_batch_parity()


## What one run of [method _unchanged_batch_parity] leaves behind: the interpolator's answer for each
## entity at a spread of ticks, and every entity's applied position.
func _unchanged_batch_run(batch: bool, native: bool) -> Dictionary:
	const ENTITIES := 12
	var rig := _unchanged_rig(ENTITIES)
	var fresh := rig.fresh
	fresh.config.batch_unchanged = batch
	fresh.config.sim_interp = native
	fresh.interpolator = GSNetInterpolator.new(fresh.config)
	for i in ENTITIES:
		rig.on_server[i].position = Vector3(1.0 + i, 0, 0)
	rig.deliver(3)
	# Entities 0 and 5 move, the rest repeat; then a tick where only 5 moves, a tick with nothing
	# moving, and one that arrives after a newer one (applied by neither).
	rig.on_server[0].position = Vector3(50, 0, 0)
	rig.on_server[5].position = Vector3(-8, 1, 0)
	rig.deliver(6)
	rig.on_server[5].position = Vector3(-9, 2, 0)
	rig.deliver(9)
	rig.deliver(12)
	var out := {"native": fresh.interpolator.is_native(), "samples": [], "applied": [], "last": []}
	for i in ENTITIES:
		var net_id: int = rig.on_fresh[i].identity.net_id
		for t in [3.0, 4.5, 6.0, 7.5, 9.0, 10.5, 12.0, 13.0]:
			(out["samples"] as Array).append(fresh.interpolator.sample(net_id, t))
		(out["applied"] as Array).append(rig.on_fresh[i].position)
		(out["last"] as Array).append(rig.on_fresh[i].last_applied)
	rig.host.stop()
	rig.fresh.stop()
	rig.legacy.stop()
	for m in [rig.host, rig.fresh, rig.legacy]:
		remove_child(m)
		(m as GSNetManager).free()
	return out


## [b]Repeating an unchanged entity's newest sample is the same as pushing it again.[/b]
## [member GSNetConfig.batch_unchanged] on and off, in the script interpolator and the native
## one: the same samples, positions and hook ticks.
func _unchanged_batch_parity() -> void:
	var reference := _unchanged_batch_run(false, false)
	for native in [false, true]:
		for batch in [false, true]:
			if not native and not batch:
				continue
			var got := _unchanged_batch_run(batch, native)
			var label := "%s interpolator, batch %s" % ["native" if native else "script", batch]
			if native and not got["native"]:
				print("  (native interpolator not available, %s skipped)" % label)
				continue
			_check("unchanged batch parity: %s draws what one push each draws" % label,
				got["samples"] == reference["samples"] and got["applied"] == reference["applied"]
					and got["last"] == reference["last"])


## What one run of [method _snapshot_batch_parity] leaves behind.
func _snapshot_batch_run(batch: bool) -> Dictionary:
	const ENTITIES := 12
	var rig := _unchanged_rig(ENTITIES)
	var fresh := rig.fresh
	fresh.config.snapshot_batch = batch
	fresh.interpolator = GSNetInterpolator.new(fresh.config)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var tick := 3
	for round_index in 14:
		for i in ENTITIES:
			# About half the entities move each snapshot, the rest repeat.
			if round_index == 0 or rng.randf() < 0.5:
				rig.on_server[i].position = Vector3(rng.randf_range(-50, 50), rng.randf_range(-5, 5), rng.randf_range(-50, 50))
		rig.deliver(tick)
		if round_index == 6:
			# One that arrives after a newer one, applied by neither.
			rig.deliver(tick - 3)
		tick += 3
	var held: int = fresh.interpolator.snapshot_batch.size() if fresh.interpolator.snapshot_batch != null else 0
	var out := {"held": held, "samples": [], "applied": [], "last": [], "baseline": [], "newest": []}
	for i in ENTITIES:
		var behaviour = rig.on_fresh[i]
		var net_id: int = behaviour.identity.net_id
		for t in [3.0, 4.5, 10.0, 21.5, 30.0, 41.0, 44.0]:
			(out["samples"] as Array).append(fresh.interpolator.sample(net_id, t))
		(out["applied"] as Array).append(behaviour.position)
		(out["last"] as Array).append(behaviour.last_applied)
		(out["baseline"] as Array).append(behaviour._baseline.duplicate())
		var track: Variant = fresh.interpolator._tracks.get(net_id)
		(out["newest"] as Array).append(-1 if track == null else int(track.newest_tick()))
	rig.host.stop()
	rig.fresh.stop()
	rig.legacy.stop()
	for m in [rig.host, rig.fresh, rig.legacy]:
		remove_child(m)
		(m as GSNetManager).free()
	return out


## [b]Decoding a whole snapshot in one native call changes nothing.[/b]
## [member GSNetConfig.snapshot_batch] on and off over random snapshots: the same samples,
## positions, baselines, tracks and hook ticks, the batch holding every entity by the end.
func _snapshot_batch_parity() -> void:
	var reference := _snapshot_batch_run(false)
	var got := _snapshot_batch_run(true)
	if int(got["held"]) == 0 and not ClassDB.class_exists(GSNetSnapshotBatch.CLASS):
		print("  (native snapshot batch not available, parity skipped)")
		return
	_check("snapshot batch parity: the batch holds the entities (%d of 12)" % got["held"],
		int(got["held"]) == 12 and int(reference["held"]) == 0)
	for key in ["samples", "applied", "last", "baseline", "newest"]:
		_check("snapshot batch parity: %s match the script path" % key, got[key] == reference[key])
