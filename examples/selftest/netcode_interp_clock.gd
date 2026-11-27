extends "netcode_snapshot_batches.gd"

## Sections of netcode_demo.gd: which clock the interpolation buffer adapts on.


## One long gap between two arrivals (a loading hitch, a debugger pause) counts as at most
## GSNetConfig.interp_arrival_gap_cap snapshot intervals in the jitter estimate; 0 counts all of it.
func _test_arrival_gap_cap() -> void:
	_sections_entered += 1
	print("")
	print("[arrival gap cap]")

	var capped := _target_after_one_gap(8.0)
	_check("one 2 s gap moves a capped buffer by little (%.2f snapshots)" % capped, capped < 3.0)
	var unlimited := _target_after_one_gap(0.0)
	_check("with the cap at 0 the whole gap counts (%.2f snapshots)" % unlimited, unlimited >= 9.9)

	_sections_completed += 1


func _target_after_one_gap(cap: float) -> float:
	var config := GSNetConfig.new()
	config.tick_rate = 64
	config.snapshot_rate = 64
	config.adaptive_interpolation = true
	config.interp_arrival_gap_cap = cap
	var interpolator := GSNetInterpolator.new(config)
	var now := 1000.0
	for _i in range(64):
		now += 1000.0 / 64.0
		interpolator.note_arrival(now)
	interpolator.note_arrival(now + 2000.0)
	return float(interpolator.describe()["target_snapshots"])


## nightly #12646: a harness that steps frames by hand gets them microseconds apart in wall time.
## One real stall grew the buffer, and the shrink ran on wall time, so it never came back down:
## the buffer has to follow the time the render timeline moved, not the OS clock.
func _test_stall_then_hand_stepped() -> void:
	_sections_entered += 1
	print("")
	print("[a stall, then hand-stepped frames]")

	var server_d := _delay_manager(true)
	var client_d := _delay_manager(false)
	for m in [server_d, client_d]:
		(m as GSNetManager).config.tick_rate = 64
		(m as GSNetManager).config.snapshot_rate = 64
	client_d.config.adaptive_interpolation = true
	var ok_setup := server_d.setup().ok and client_d.setup().ok

	var delivered: Array[PackedByteArray] = []
	server_d.send_fn = func(peer_id: int, payload: PackedByteArray, d: int) -> void:
		if peer_id == 2 and d == GSNetMessage.Delivery.UNRELIABLE:
			delivered.append(payload)
	server_d.start()
	client_d.start()
	server_d.add_peer(2)
	server_d.spawner.register_factory(&"player", _build_player)
	client_d.spawner.register_factory(&"player", _build_player)
	var spawned := server_d.spawner.spawn(&"player", 3, Transform3D.IDENTITY, 0)
	var server_entity: GSNetIdentity = spawned.value if spawned.ok else null
	var remote: GSNetIdentity = null
	if server_entity != null:
		var mirrored := client_d.spawner.spawn_remote(
			&"player", server_entity.net_id, 3, Transform3D.IDENTITY, 0)
		remote = mirrored.value if mirrored.ok else null
	_check("a remote entity on a 64-tick client (setup %s)" % ok_setup,
		ok_setup and remote != null and not remote.is_predicted())
	if remote == null:
		_free_delay_managers(server_d, client_d)
		_sections_completed += 1
		return

	(server_entity.behaviours[0] as Movement).velocity = Vector3(10.0, 0.0, 0.0)
	var client_move := remote.behaviours[0] as Movement
	var result := _run_stall_ticks(server_d, client_d, client_move, delivered)

	_check("the stall grew the buffer (%.2f -> %.2f snapshots)" % [result["before"], result["peak"]],
		result["peak"] > result["before"] + 0.3)
	# Lateness comes off the wall-clock receive timeline, so host load moves the floor: check the shrink.
	_check("and hand-stepped frames shrank it (low %.2f in the last 200 ticks, was %.2f, %.0f ms of wall time)"
			% [result["after"], result["before"], result["wall_ms"]],
		result["after"] < result["peak"] - 0.5)
	_check("the remote never moved backwards (worst %.4f m)" % result["backwards"],
		result["backwards"] < 0.0001)

	_free_delay_managers(server_d, client_d)
	_sections_completed += 1


## Ten seconds at 64 ticks with four hand-stepped frames a tick and one real 240 ms stall at tick 200.
func _run_stall_ticks(
		server_d: GSNetManager, client_d: GSNetManager, client_move: Movement,
		delivered: Array[PackedByteArray]) -> Dictionary:
	var interp := client_d.interpolator
	var result := {"before": 0.0, "peak": 0.0, "after": INF, "backwards": 0.0, "wall_ms": 0.0}
	var last_x := -INF
	for tick in range(1, 640):
		if tick == 200:
			result["before"] = interp.delay_snapshots()
			OS.delay_msec(240)
			result["wall_ms"] = -float(Time.get_ticks_msec())
		server_d.server_tick(tick)
		for payload in delivered:
			var _applied := client_d.receive_snapshot(payload)
		delivered.clear()
		for quarter in range(4):
			client_d.interpolate_frame(float(quarter) * 0.25)
			if tick > 64:
				result["backwards"] = maxf(result["backwards"], last_x - client_move.position.x)
			last_x = client_move.position.x
		client_d.step(1.0 / 64.0)
		if tick >= 200:
			result["peak"] = maxf(result["peak"], interp.delay_snapshots())
		if tick >= 440:
			result["after"] = minf(result["after"], interp.delay_snapshots())
	result["wall_ms"] += float(Time.get_ticks_msec())
	return result
