extends "netcode_unchanged_and_lossy_lead.gd"

## The input clock under jitter, a section of netcode_demo.gd.


## A half-minute of a 60 Hz client against a link with [param one_way] ms each way and [param jitter] ms of jitter on each datagram, a snapshot every second tick. Returns the clock's catch-ups and floors after it settled, and how many of the server's ticks ran without their command.
func _jitter_lead_run(one_way: float, jitter: float, seconds: float, seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	# FC declares 66 ticks a second and its engine and server run 60: the clock follows the server's pace.
	var rate := 60
	var clock := GSNetClock.new(66)
	clock.follow_engine_time = false
	var buffer := GSNetInput.Buffer.new(120)
	var frame_ms := 1000.0 / float(rate)
	var up: Array = []
	var down: Array = []
	var sent: Array[GSNetInput] = []
	var settle := 3 * rate
	var settled := {"catch_ups": 0, "floors": 0}
	var out := {"catch_ups": 0, "floors": 0, "starved": 0, "late_reports": 0}
	for frame in int(seconds * float(rate)):
		var now := float(frame) * frame_ms
		var server_at := 1000 + frame
		while not up.is_empty() and float(up[0][0]) <= now:
			var packet: Array = up.pop_front()[1]
			var _b := buffer.push_batch(packet)
		if buffer.take(server_at) == null and frame >= settle:
			out["starved"] = int(out["starved"]) + 1
		var sample := buffer.take_lead_sample()
		if frame % 2 == 0:
			down.append([now + one_way + rng.randf_range(-jitter, jitter), server_at, sample])
			down.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
		while not down.is_empty() and float(down[0][0]) <= now:
			var snapshot: Array = down.pop_front()
			# The transport's smoothed round trip starts high and converges, as ENet's does after a connect.
			var smoothed := 2.0 * one_way + 700.0 * exp(-now / 4000.0)
			clock.sync_from_server(int(snapshot[1]), smoothed)
			var report: Vector2i = snapshot[2]
			if report.x != GSNetInput.Buffer.LEAD_NONE:
				clock.note_input_lead(report.y, report.x)
		var ticks := clock.advance(1.0 / float(rate))
		for i in ticks:
			var input := DemoInput.new()
			input.tick = clock.tick - (ticks - 1 - i)
			sent.append(input)
		if ticks > 0:
			up.append([now + one_way + rng.randf_range(-jitter, jitter), sent.slice(maxi(0, sent.size() - 4))])
			up.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
		if frame == settle:
			settled["catch_ups"] = int(clock.describe()["catch_ups"])
			settled["floors"] = int(clock.describe()["floors"])
	var described := clock.describe()
	out["catch_ups"] = int(described["catch_ups"]) - int(settled["catch_ups"])
	out["floors"] = int(described["floors"]) - int(settled["floors"])
	out["late_reports"] = int(described["late_reports"])
	out["jitter_ms"] = clock.jitter_ms()
	return out


## The clock under 10 ms of jitter each way, the bench of game-fatal-contact's client_bench `--delay 50 --jitter 10`: its jitter estimate read 0 (the round trip it was fed is the transport's smoothed one) and it skipped 3 to 4 ticks every second or so. Armed: without the arrival spread in the estimate and the receive floor in the steering target the clock jumps.
func _test_jitter_lead() -> void:
	_sections_entered += 1
	print("")
	print("[the input lead under jitter]")
	var jumps := 0
	var floors := 0
	var starved := 0
	var jitter_seen := 0.0
	for seed_value in 6:
		var run := _jitter_lead_run(50.0, 10.0, 35.0, 2000 + seed_value)
		jumps += int(run["catch_ups"])
		floors += int(run["floors"])
		starved += int(run["starved"])
		jitter_seen = maxf(jitter_seen, float(run["jitter_ms"]))
	print("    60 Hz, 50 ms +- 10 ms each way, 6 x 30 s: %d jumps (%d onto the receive timeline), %d starved ticks, jitter read up to %.1f ms" % [jumps, floors, starved, jitter_seen])
	_check("the jitter estimate sees the arrival spread (read up to %.1f ms)" % jitter_seen, jitter_seen >= 2.0)
	_check("under 10 ms of jitter the clock does not skip (%d jumps, %d of them onto the receive timeline, in 6 x 30 s)" % [jumps, floors],
		jumps <= 2 and floors == 0)
	_sections_completed += 1

