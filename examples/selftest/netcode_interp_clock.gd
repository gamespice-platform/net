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


## nightly #12646: a harness that steps frames by hand gets them microseconds apart in wall time. One stall grew the buffer, and the shrink ran
## on wall time, so it never came back down: the buffer has to follow the time the render timeline moved. Arrivals are timed on the client's
## stepped clock (GSNetManager.arrival_clock), so the buffer never reads the wall clock and every number is exact: the old shrink fails on any box.
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
	if ok_setup:
		client_d.arrival_clock = client_d.clock.stepped_msec

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
	var r := _run_stall_ticks(server_d, client_d, client_move, delivered)

	_check("the stepped link holds the buffer at %.4f snapshots before the stall (%.4f)" % [STALL_BEFORE, r["before"]],
		absf(r["before"] - STALL_BEFORE) < 0.0001)
	# Exact frames: the buffer moves by the render time each frame moved. A buffer moved by wall time reaches
	# the ceiling sooner on a slow box and later on a quick one, and only by chance on this frame.
	_check("the %d-tick stall grows it to the 10-snapshot ceiling on frame %d (frame %d)"
			% [STALL_TICKS, STALL_PEAK_AT, r["peak_at"]], r["peak_at"] == STALL_PEAK_AT)
	_check("hand-stepped frames bring it back within %.2f of %.4f on frame %d (frame %d, %.0f ms of wall time)"
			% [STALL_TOLERANCE, STALL_BEFORE, STALL_BACK_AT, r["back_at"], r["wall_ms"]],
		r["back_at"] == STALL_BACK_AT)
	_check("and it ends at %.4f snapshots after %d frames (%.4f)" % [STALL_END, r["frames"], r["end"]],
		absf(r["end"] - STALL_END) < 0.0001)
	_check("the remote never moved backwards (worst %.4f m)" % r["backwards"],
		r["backwards"] < 0.0001)

	_free_delay_managers(server_d, client_d)
	_sections_completed += 1


## The buffer on the stepped link just before the stall, in snapshots: still easing from the configured 2 toward 1.
const STALL_BEFORE := 1.1353
## Snapshots the server sends while none reach the client (a quarter second at 64 ticks).
const STALL_TICKS := 16
## Frames counted from the end of the stall: when the buffer first reaches the ceiling, when it is first back within
## STALL_TOLERANCE snapshots of STALL_BEFORE, and where it ends (STALL_RUN_TICKS ticks in all).
const STALL_PEAK_AT := 354
const STALL_BACK_AT := 3672
const STALL_END := 1.0022
const STALL_TOLERANCE := 0.02
const STALL_RUN_TICKS := 1100
## Frames drawn per tick: each is an eighth of a tick of render time and next to no wall time.
const STALL_FRAMES_PER_TICK := 8


## STALL_RUN_TICKS ticks at 64 a second, eight hand-stepped frames a tick, the server's snapshots held back for
## STALL_TICKS ticks from tick 200 and then delivered in one burst.
func _run_stall_ticks(
		server_d: GSNetManager, client_d: GSNetManager, client_move: Movement,
		delivered: Array[PackedByteArray]) -> Dictionary:
	var interp := client_d.interpolator
	var r := {"before": 0.0, "peak_at": -1, "back_at": -1, "end": 0.0, "frames": 0, "backwards": 0.0,
		"wall_ms": -float(Time.get_ticks_msec())}
	var last_x := -INF
	var frame := -1
	for tick in range(1, STALL_RUN_TICKS):
		if tick == 200:
			r["before"] = interp.delay_snapshots()
		server_d.server_tick(tick)
		if tick < 200 or tick >= 200 + STALL_TICKS:
			for payload in delivered:
				var _applied := client_d.receive_snapshot(payload)
			delivered.clear()
		if tick == 200 + STALL_TICKS:
			frame = 0
		for f in range(STALL_FRAMES_PER_TICK):
			client_d.interpolate_frame(float(f) / float(STALL_FRAMES_PER_TICK))
			if tick > 64:
				r["backwards"] = maxf(r["backwards"], last_x - client_move.position.x)
			last_x = client_move.position.x
			if frame < 0:
				continue
			var delay := interp.delay_snapshots()
			if r["peak_at"] < 0 and delay >= 9.9999:
				r["peak_at"] = frame
			elif r["peak_at"] >= 0 and r["back_at"] < 0 and absf(delay - r["before"]) <= STALL_TOLERANCE:
				r["back_at"] = frame
			frame += 1
		client_d.step(1.0 / 64.0)
	r["end"] = interp.delay_snapshots()
	r["frames"] = frame
	r["wall_ms"] += float(Time.get_ticks_msec())
	return r
