extends SceneTree
## Runnable accuracy check for AudioDirector. Synthesises a click track at a known
## tempo, plays it, and measures the locked BPM and the beat-to-click phase error.
##   godot --headless --path . --script res://test_director.gd

# Engine.max_fps is load-bearing: headless Godot runs _process uncapped, which aliases
# against the audio mix callback and smears get_playback_position() + time_since_last_mix.
# Without this the fit reads ~1.5 BPM high with +/-0.1 s jitter and looks like a tracker bug.
const FPS := 60
const TOL_BPM := 2.0
const TOL_PHASE := 0.030

func _click_track(track_bpm: float, secs: float) -> AudioStreamWAV:
	var sr := 44100
	var n := int(sr * secs)
	var buf := PackedByteArray()
	buf.resize(n * 2)
	var period := 60.0 / track_bpm
	for i in n:
		var t := float(i) / sr
		var since := fmod(t, period)
		# 55 ms kick: pitch sweep 120 -> 45 Hz with exponential decay, which is what a
		# real transient looks like. A sub-one-cycle blip is not a fair test signal.
		var v := 0.0
		if since < 0.055:
			var hz: float = 45.0 + 75.0 * exp(-since * 45.0)
			v = sin(TAU * hz * since) * exp(-since * 32.0) * 0.9
		buf.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = sr
	s.data = buf
	return s

func _initialize() -> void:
	Engine.max_fps = FPS
	var player := AudioStreamPlayer.new()
	root.add_child(player)
	var director := AudioDirector.new()
	root.add_child(director)
	await process_frame  # nodes added during _initialize are not ready until the first frame
	director.track_tempo = true  # the feature under test
	director.attach(player)

	var failures := 0
	for track_bpm in [90.0, 120.0, 128.0, 174.0]:
		director.reset()
		player.stream = _click_track(track_bpm, 24.0)
		player.play()
		var guard := 0
		while not player.playing and guard < 120:  # play() defers until the node is ready
			await process_frame
			guard += 1
		var errors := PackedFloat64Array()
		director.beat.connect(func(_i: int) -> void:
			var period: float = 60.0 / track_bpm
			var e: float = fposmod(director.song_time(), period)
			errors.append(e if e < period * 0.5 else e - period))
		while player.playing and director.song_time() < 23.0:
			await process_frame
		player.stop()

		# ignore the lock-in transient: judge the second half only
		var late := errors.slice(errors.size() / 2)
		var mean := 0.0
		for e in late:
			mean += e
		mean = mean / late.size() if late.size() > 0 else INF
		var sd := 0.0
		for e in late:
			sd += (e - mean) * (e - mean)
		sd = sqrt(sd / late.size()) if late.size() > 0 else INF
		var d_bpm: float = absf(director.bpm - track_bpm)
		var ok := d_bpm <= TOL_BPM and absf(mean) <= TOL_PHASE
		if not ok:
			failures += 1
		print("%s %6.1f BPM -> locked %6.2f (d %4.2f)  phase %+.1f ms (sd %.1f)  conf %.2f  beats %d" % [
			"OK  " if ok else "FAIL", track_bpm, director.bpm, d_bpm,
			mean * 1000.0, sd * 1000.0, director.confidence, errors.size()])

		print("      onsets=%d spectrum=%s driver=%s" % [director.get("_onsets").size(), director.get("_spectrum") != null, AudioServer.get_driver_name() if AudioServer.has_method("get_driver_name") else OS.get_name()])
	print("RESULT ", "ALL PASS" if failures == 0 else "%d FAILED" % failures)
	quit(1 if failures > 0 else 0)
