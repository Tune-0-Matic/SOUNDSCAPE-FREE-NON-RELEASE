class_name AudioEngine
extends Node
## Decoding, caching, metadata and queue management for the media player.
##
## FIDELITY CEILING -- read this before trusting the word "lossless" anywhere below.
## Godot 4.7 has no FLAC decoder (AudioStreamFLAC does not exist; AudioStream recognizes
## only mp3str / oggvorbisstr / sample). AudioStreamWAV supports 8- and 16-bit PCM only.
## So a 24-bit source is ALWAYS truncated to 16-bit somewhere in this pipeline. There is
## no bit-transparent path in this engine version, and no arrangement of these functions
## creates one. What IS preserved:
##   - sample rate, exactly, at any rate (44.1 / 48 / 96 / 192 kHz all verified loading)
##   - channel count
##   - no lossy re-encode: FLAC is decoded straight to PCM, never through mp3/ogg
## Set audio/driver/mix_rate to match your material or the AudioServer resamples on output.

signal track_ready(path: String, stream: AudioStream, meta: Dictionary)
signal track_failed(path: String, reason: String)
signal queue_changed()

enum Repeat { OFF, ALL, ONE }

const CHUNK := 1 << 20  # 1 MiB streaming copy, so a 90 MB wav never sits in RAM twice

var queue: Array[String] = []
var index := -1
var repeat: Repeat = Repeat.ALL
var shuffle := false

var _meta := {}          # path -> Dictionary, ffprobe results are immutable, cache forever
var _next_stream: AudioStream  # preloaded so a track change does not stall on disk I/O
var _next_path := ""
var _token := 0

# --- queue ----------------------------------------------------------------
## `current` re-anchors the play position after the queue is rebuilt. Re-sorting or
## rescanning reorders the queue underneath a playing track, and keeping the old integer
## index would make auto-advance jump to whatever now happens to sit in that slot --
## so the index is recovered from the path instead.
func set_queue(paths: Array[String], current: String = "") -> void:
	queue = paths.duplicate()
	index = queue.find(current) if not current.is_empty() else -1
	queue_changed.emit()

## Returns the index that should play next, or -1 when the queue is exhausted.
## Kept pure so the wrap/repeat/shuffle rules are testable without playing anything.
static func peek_next(from: int, wrapped_repeat: Repeat, is_shuffle: bool, size: int, rng_pick: int) -> int:
	if size <= 0:
		return -1
	if wrapped_repeat == Repeat.ONE:
		return from
	if is_shuffle:
		# a pick landing on the track already playing would repeat it, which reads as the
		# shuffle being broken. Step off by one rather than re-rolling, so the caller's RNG
		# stays the only source of randomness and this function stays pure.
		return (rng_pick + 1) % size if rng_pick == from and size > 1 else rng_pick
	if from + 1 < size:
		return from + 1
	return 0 if wrapped_repeat == Repeat.ALL else -1

func next_index() -> int:
	return peek_next(index, repeat, shuffle, queue.size(), randi() % maxi(queue.size(), 1))

func prev_index() -> int:
	if queue.is_empty():
		return -1
	if shuffle:
		return randi() % queue.size()
	return index - 1 if index > 0 else (queue.size() - 1 if repeat == Repeat.ALL else -1)

# --- request ---------------------------------------------------------------
## Asks for a track. Emits track_ready on the main thread when the stream and its
## metadata are both available. Any work that can block (ffmpeg, ffprobe, reading a
## 90 MB wav) happens on a worker; only the newest request is honoured.
func request(i: int) -> void:
	if i < 0 or i >= queue.size():
		return
	index = i
	_token += 1
	var token := _token
	var path := queue[i]
	if path == _next_path and _next_stream:  # preloaded by the previous track
		var s := _next_stream
		_next_stream = null
		_next_path = ""
		_deliver(token, path, s)
		return
	WorkerThreadPool.add_task(func() -> void:
		var s := decode(path)
		var m := metadata(path)
		_deliver.bind(token, path, s, m).call_deferred())

func _deliver(token: int, path: String, s: AudioStream, m: Dictionary = {}) -> void:
	if token != _token:
		return  # superseded by a newer request; drop it rather than hijack playback
	if not s:
		track_failed.emit(path, "decode failed")
		return
	track_ready.emit(path, s, m if not m.is_empty() else metadata(path))
	_preload(next_index())

## Warms the NEXT track's stream on a worker so a transition costs no disk I/O.
## Holds one decoded stream in RAM (~90 MB for a 4 min 96 kHz stereo track) -- that is
## the price of gapless-feeling transitions. Drop this call to trade smoothness for RAM.
func _preload(i: int) -> void:
	if i < 0 or i >= queue.size() or queue[i] == _next_path:
		return
	var path := queue[i]
	_next_path = path
	WorkerThreadPool.add_task(func() -> void:
		var s := decode(path)
		(func() -> void:
			if _next_path == path:
				_next_stream = s).call_deferred())

# --- decoding --------------------------------------------------------------
func decode(path: String) -> AudioStream:
	match path.get_extension().to_lower():
		"mp3": return AudioStreamMP3.load_from_file(path)
		"ogg": return AudioStreamOggVorbis.load_from_file(path)
		"wav": return AudioStreamWAV.load_from_file(path)
		"flac":
			var c := cache_path(path)
			return AudioStreamWAV.load_from_file(c) if _to_pcm(path, c) else null
	return null

func cache_path(src: String) -> String:
	return "user://pcm_%d.wav" % hash(src)

## Deletes cached PCM belonging to tracks that are no longer in the library. The cache is
## keyed by a hash of the ABSOLUTE source path, so renaming or moving a FLAC orphans its
## entry permanently and nothing would ever reclaim it -- and these files run 30-120 MB
## each. Called after every library scan; returns how many files were removed.
##
## Anything under user:// starting with "pcm_" is in scope, which also sweeps up the
## `.wav.pcm` and `.wav.part` temporaries a transcode killed part-way through leaves
## behind. A track mid-decode is safe: it is in the library, so its entry is kept.
func prune_cache(active: Array[String]) -> int:
	var keep := {}
	for p in active:
		if p.get_extension().to_lower() == "flac":
			keep[cache_path(p).get_file()] = true
	var dir := DirAccess.open("user://")
	if not dir:
		return 0
	var removed := 0
	for f in dir.get_files():
		if not f.begins_with("pcm_"):
			continue
		# "pcm_123.wav.part" and "pcm_123.wav.pcm" both belong to "pcm_123.wav"
		var owner := f
		var cut := f.find(".wav")
		if cut >= 0:
			owner = f.substr(0, cut + 4)
		if keep.has(owner):
			continue
		if dir.remove(f) == OK:
			removed += 1
	return removed

## FLAC -> PCM at the SOURCE sample rate.
##
## We deliberately do NOT let ffmpeg mux the wav. Above 48 kHz its wav muxer emits
## WAVE_FORMAT_EXTENSIBLE (fmt tag 0xFFFE, 40-byte fmt chunk) and Godot's parser rejects
## that outright -- load_from_file returns null with no error, which reads as "the track
## just will not switch". Piping raw s16le and writing a canonical 16-byte PCM header
## ourselves keeps the native rate AND loads: verified at 44.1 / 48 / 96 / 192 kHz.
## (The older workaround, -ar 44100, also loaded but threw away the hi-res rate.)
func _to_pcm(src: String, dst: String) -> bool:
	if FileAccess.file_exists(dst):
		return true
	var m := metadata(src)
	var rate: int = m.get("sample_rate", 44100)
	var ch: int = clampi(m.get("channels", 2), 1, 2)  # AudioStreamWAV is mono or stereo only
	var raw := ProjectSettings.globalize_path(dst + ".pcm")
	var out: Array = []
	# s16le because AudioStreamWAV has no 24-bit format. This is the truncation point.
	var args := ["-y", "-v", "error", "-i", src, "-map", "0:a:0",
		"-c:a", "pcm_s16le", "-ac", str(ch), "-f", "s16le", raw]
	if OS.execute("ffmpeg", args, out, true) != 0:
		push_warning("ffmpeg failed on %s: %s" % [src.get_file(), "".join(out)])
		DirAccess.remove_absolute(raw)
		return false
	var ok := _wrap_pcm(dst + ".pcm", dst + ".part", rate, ch)
	DirAccess.remove_absolute(raw)
	if not ok:
		return false
	# rename last, so an interrupted run never leaves a half-written file in the cache
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(dst + ".part"),
		ProjectSettings.globalize_path(dst)) == OK

func _wrap_pcm(raw: String, dst: String, rate: int, ch: int) -> bool:
	var src := FileAccess.open(raw, FileAccess.READ)
	if not src:
		return false
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if not f:
		src.close()
		return false
	f.store_buffer(wav_header(src.get_length(), rate, ch))
	while not src.eof_reached():
		f.store_buffer(src.get_buffer(CHUNK))
	f.close()
	src.close()
	return true

## Canonical 44-byte RIFF/WAVE header: 16-byte fmt chunk, wFormatTag = 1 (PCM).
## Godot accepts this at any sample rate; it is the extensible variant it refuses.
static func wav_header(data_bytes: int, rate: int, ch: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.append_array("RIFF".to_ascii_buffer())
	b.append_array(_i32(36 + data_bytes))
	b.append_array("WAVEfmt ".to_ascii_buffer())
	b.append_array(_i32(16))          # fmt chunk size: 16, never 40
	b.append_array(_i16(1))           # WAVE_FORMAT_PCM
	b.append_array(_i16(ch))
	b.append_array(_i32(rate))
	b.append_array(_i32(rate * ch * 2))  # byte rate
	b.append_array(_i16(ch * 2))         # block align
	b.append_array(_i16(16))             # bits per sample
	b.append_array("data".to_ascii_buffer())
	b.append_array(_i32(data_bytes))
	return b

static func _i32(v: int) -> PackedByteArray:
	var a := PackedByteArray()
	a.resize(4)
	a.encode_s32(0, v)
	return a

static func _i16(v: int) -> PackedByteArray:
	var a := PackedByteArray()
	a.resize(2)
	a.encode_s16(0, v)
	return a

# --- metadata --------------------------------------------------------------
## Godot cannot read FLAC/Vorbis/ID3 tags, so this shells out to ffprobe, which ships
## with ffmpeg and is therefore already a dependency. Results never change for a given
## file, so they are cached for the session.
func metadata(path: String) -> Dictionary:
	if _meta.has(path):
		return _meta[path]
	var d := {
		"title": path.get_file().get_basename(), "artist": "", "album": "",
		"sample_rate": 44100, "channels": 2, "bits": 16, "codec": path.get_extension().to_upper(),
	}
	# ffprobe emits UTF-8, but OS.execute decodes its output with the system ANSI codepage,
	# which mojibakes any non-Latin tag (Japanese album names came back as "ä¸­åŽŸ").
	# Writing to a file and reading it back with FileAccess decodes UTF-8 correctly.
	var tmp := ProjectSettings.globalize_path("user://probe_%d.json" % hash(path))
	var args := ["-v", "error", "-select_streams", "a:0", "-show_entries",
		"stream=sample_rate,channels,bits_per_raw_sample,codec_name:format_tags=title,artist,album",
		"-of", "json", "-o", tmp, path]
	if OS.execute("ffprobe", args, [], true) == 0:
		var j = JSON.parse_string(FileAccess.get_file_as_string(tmp))
		DirAccess.remove_absolute(tmp)
		if j is Dictionary:
			var st: Dictionary = (j.get("streams", []) as Array)[0] if (j.get("streams", []) as Array).size() > 0 else {}
			d["sample_rate"] = int(st.get("sample_rate", 44100))
			d["channels"] = int(st.get("channels", 2))
			d["bits"] = int(st.get("bits_per_raw_sample", 16)) if st.get("bits_per_raw_sample") else 16
			d["codec"] = str(st.get("codec_name", d["codec"])).to_upper()
			var tags: Dictionary = j.get("format", {}).get("tags", {})
			for k in ["title", "artist", "album"]:
				for variant in [k, k.capitalize(), k.to_upper()]:
					if tags.has(variant) and str(tags[variant]) != "":
						d[k] = str(tags[variant])
						break
	_meta[path] = d
	return d

## One line for the status ticker: what the file is, and what the engine actually plays.
func ticker_line(path: String) -> String:
	var m := metadata(path)
	var who: String = "%s - %s" % [m["artist"], m["title"]] if m["artist"] != "" else m["title"]
	var served := 16  # AudioStreamWAV ceiling; see FIDELITY CEILING at the top
	return "// %s // %s %d HZ %d BIT %s // ENGINE %d HZ %d BIT // MIX %d HZ " % [
		who.to_upper(), m["codec"], m["sample_rate"], m["bits"],
		"STEREO" if m["channels"] >= 2 else "MONO",
		m["sample_rate"], served, int(AudioServer.get_mix_rate())]
