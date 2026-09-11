extends PanelContainer
## MEDIA_PLAYER_SYS.EXE -- retro tactical skin over AudioStreamPlayer / VideoStreamPlayer.
## FOLDERS tab collects library roots, TRACKS tab lists everything under them, sorted by path.

## The editor and an exported build share user:// on this machine, so an editor save
## would otherwise be the first thing a shipped player sees. A different filename per
## side keeps the two odometers, libraries and presets apart; on a player's machine
## neither file exists yet, so the export always starts clean.
var _cfg: String = "user://library_dev.cfg" if OS.has_feature("editor") else "user://library.cfg"
const EXTS := ["mp3", "wav", "ogg", "flac"]
const SORTS := ["PATH", "NAME", "TYPE", "DATE", "FOLDER"]

@export_file("*.ogv") var video_path := ""

@onready var _a: AudioStreamPlayer = %AudioA
@onready var _b: AudioStreamPlayer = %AudioB
## Whichever player currently owns playback. Everything downstream -- transport,
## scrub, the spectrum feed -- reads this, so a crossfade only has to reassign it.
@onready var _audio: AudioStreamPlayer = _a
@onready var _video: VideoStreamPlayer = %Video
@onready var _scrub: ProgressBar = %Scrub
@onready var _vol: ProgressBar = %Vol
@onready var _elapsed: Label = %Elapsed
@onready var _total: Label = %Total
@onready var _stats: Label = %Stats
@onready var _status: Label = %Status
@onready var _ticker: Label = %Ticker
@onready var _clock: Label = %Clock
@onready var _nosignal: Label = %NoSignal
@onready var _tracks: ItemList = %Tracks
@onready var _folder_list: ItemList = %Folders
@onready var _count: Label = %Count
@onready var _dialog: FileDialog = %Dialog
@onready var _director: AudioDirector = %Director
@onready var _engine: AudioEngine = %Engine
@onready var _viz: Control = %Viz
@onready var _eq: Equalizer = %Eq

var _folders: Array[String] = []
var _paths: Array[String] = []
var _current := ""
var _dragging := false
var _note := ""
var _sort := 0
var _mtime := {}
## FOLDER view inserts unselectable header rows, so list rows and _paths indices stop
## lining up. These two keep the mapping in both directions; in every other view they
## are simply the identity, so nothing downstream needs to branch.
var _filter := ""
## Sorted view of the library: one entry per _paths index, holding the row string and a
## pre-folded lowercase haystack so a search keystroke never re-derives either.
var _index: Array[Dictionary] = []
var _row_path := PackedInt32Array()
var _path_row := PackedInt32Array()
var _pending := 0
var _busy := false
var _flash := 0.0
var _viz_cfg := {}
var _skin := "WIN98"
var _eq_cfg := {}
var _total_secs := 0.0     # lifetime, carried across sessions
var _session_secs := 0.0
var _save_at := 30.0
var _reboot_armed := 0.0
var _user_name := ""
var _tbs: Array[String] = []
var _fade_on := true
var _fade_ms := 1000
var _delay_ms := 250
var _fading := false
var _max_fps := 30
var _layout := 0       # 0 auto, 1 force landscape, 2 force portrait
var _portrait := false
var _last_vp := Vector2.ZERO
var _feed := 0
var _feed_prev := 0
var _fade_tween: Tween
var _ez_faders: Array[VSlider] = []
var _adv_faders: Array[VSlider] = []
var _fader_base := PackedFloat32Array()
var _fader_sync := false
var _presets: Array = []
var _volume := 80.0
var _boost := 0        # 0..100 on the dial; 0 is unity, no boost

func _ready() -> void:
	assert(_fmt(61.0) == "01:01" and _ratio_at(-9.0, 100.0) == 0.0 and _ratio_at(999.0, 100.0) == 1.0)
	assert(_is_audio("A.MP3") and _is_audio("b.flac") and not _is_audio("cover.jpg"))
	assert(_cmp_by("NAME", "z/a.mp3", "a/b.mp3") and _cmp_by("PATH", "a/b.mp3", "z/a.mp3"))
	assert(_cmp_by("TYPE", "b.flac", "a.mp3") and not _cmp_by("TYPE", "a.mp3", "b.flac"))
	# shuffle must not hand back the track already playing, except in a one-track queue
	assert(AudioEngine.peek_next(2, AudioEngine.Repeat.ALL, true, 5, 2) != 2)
	assert(AudioEngine.peek_next(0, AudioEngine.Repeat.ALL, true, 1, 0) == 0)
	assert(AudioEngine.peek_next(4, AudioEngine.Repeat.OFF, false, 5, 0) == -1)
	var cfg := ConfigFile.new()
	if cfg.load(_cfg) == OK:
		_folders.assign(cfg.get_value("library", "folders", []))
		_sort = clampi(cfg.get_value("library", "sort", 0), 0, SORTS.size() - 1)
		_viz_cfg = cfg.get_value("visual", "viz", {})
		_skin = cfg.get_value("visual", "skin", "WIN98")
		_eq_cfg = cfg.get_value("eq", "state", {})
		_presets = cfg.get_value("eq", "presets", [])
		_total_secs = cfg.get_value("stats", "total_seconds", 0.0)
		# re-anchor the periodic flush, or a loaded odometer trips it on the first frame
		_save_at = _total_secs + 30.0
		_user_name = cfg.get_value("stats", "user_name", "")
		_tbs.assign(cfg.get_value("library", "tbs", []))
		# @onready, so _engine is already bound by the time the _ready body runs
		_engine.shuffle = cfg.get_value("library", "shuffle", false)
		_engine.repeat = clampi(cfg.get_value("library", "repeat", AudioEngine.Repeat.ALL),
			0, 2) as AudioEngine.Repeat
		_volume = clampf(cfg.get_value("audio", "volume", 80.0), 0.0, 100.0)
		_boost = clampi(cfg.get_value("audio", "boost", 0), 0, 100)
		_fade_on = cfg.get_value("audio", "fade", true)
		_fade_ms = clampi(cfg.get_value("audio", "fade_ms", 1000), FADE_MS_MIN, FADE_MS_MAX)
		_delay_ms = clampi(cfg.get_value("audio", "play_delay_ms", 250), DELAY_MS_MIN, DELAY_MS_MAX)
		_feed = clampi(cfg.get_value("visual", "feed_size", 0), 0, 3)
		_layout = clampi(cfg.get_value("visual", "layout", 0), 0, 2)
		_director.track_tempo = cfg.get_value("audio", "track_tempo", false)
		_max_fps = clampi(cfg.get_value("visual", "max_fps", 30), FPS_MIN, FPS_MAX)
	if video_path:
		_video.stream = load(video_path)
	%Play.pressed.connect(_toggle)
	%Stop.pressed.connect(_stop)
	%AddFolder.pressed.connect(_dialog.popup_centered)
	%RemoveFolder.pressed.connect(_remove_folder)
	%Rescan.pressed.connect(_rescan)
	%Sort.pressed.connect(_cycle_sort)
	%Search.text_changed.connect(func(s: String) -> void:
		_filter = s.strip_edges()
		_refill())
	%Reboot.pressed.connect(_on_reboot)
	_setup_fade()
	_setup_feed()
	_setup_fps()
	_setup_boost()
	_setup_layout()
	_setup_beat()
	_setup_tbs()
	%Sort.text = "SORT: %s" % SORTS[_sort]
	_dialog.dir_selected.connect(_add_folder)
	_tracks.item_activated.connect(_on_row_activated)
	_tracks.gui_input.connect(_on_list_scroll)
	for pl in [_a, _b]:
		# the outgoing player of a crossfade must not trigger auto-advance
		pl.finished.connect(func() -> void: if pl == _audio and not _fading: _next())
	_engine.track_ready.connect(_on_track_ready)
	_engine.track_failed.connect(_on_track_failed)
	%Prev.pressed.connect(_prev)
	%Next.pressed.connect(_next)
	%Shuffle.pressed.connect(func() -> void:
		_engine.shuffle = not _engine.shuffle
		_refresh_transport()
		_save())
	%Repeat.pressed.connect(func() -> void:
		_engine.repeat = ((_engine.repeat + 1) % 3) as AudioEngine.Repeat
		_refresh_transport()
		_save())
	_refresh_transport()
	_setup_pixel_font()
	_setup_eq()
	_setup_cursor()
	_setup_visual()
	_director.attach(_audio)
	_director.beat.connect(func(_i: int) -> void: _flash = 0.10)
	_scrub.gui_input.connect(_on_scrub_input)
	_vol.gui_input.connect(_on_vol_input)
	%TickTimer.timeout.connect(func() -> void: _ticker.text = _ticker.text.substr(1) + _ticker.text[0])
	_vol.value = _volume
	_apply_volume()   # the bus was never actually set here, so the slider lied
	_rescan()
	%Boot.finished.connect(func(who: String) -> void:
		_user_name = who
		_save())
	_start_intro()
	_save()   # write a full config immediately, so nothing depends on a later edit
	if _paths.is_empty() and not _video.stream:
		_audio.stream = _demo_tone()
	_stop()

# --- library --------------------------------------------------------------
func _cycle_sort() -> void:
	_sort = (_sort + 1) % SORTS.size()
	%Sort.text = "SORT: %s" % SORTS[_sort]
	_save()
	_reindex()  # re-sort only; no reason to re-walk the disk

func _cmp_by(mode: String, a: String, b: String) -> bool:
	match mode:
		"NAME":
			return a.get_file().naturalcasecmp_to(b.get_file()) < 0
		"TYPE":
			var d := a.get_extension().nocasecmp_to(b.get_extension())
			return d < 0 if d != 0 else a.naturalcasecmp_to(b) < 0
		"DATE":
			var ta: int = _mtime.get(a, 0)
			var tb: int = _mtime.get(b, 0)
			return ta > tb if ta != tb else a.naturalcasecmp_to(b) < 0  # newest first
	return a.naturalcasecmp_to(b) < 0  # PATH and FOLDER: keeps directories contiguous

## SCAN SONGS: re-walks every root from disk. Reports what the selected folder holds
## afterwards, so the button visibly did something even when the count has not changed.
func _rescan() -> void:
	var sel := _folder_list.get_selected_items()
	var watch: String = _folders[sel[0]] if not sel.is_empty() and sel[0] < _folders.size() else ""
	_paths.clear()
	for f in _folders:
		_walk(f, _paths)
	_engine.prune_cache(_paths)   # the library just changed; drop cache nothing points at
	_reindex()
	if watch.is_empty():
		_note = "  //  SCANNED %d TRACKS" % _paths.size()
	else:
		var n := 0
		for path in _paths:
			if path.begins_with(watch):
				n += 1
		_note = "  //  %s: %d TRACKS" % [watch.get_file().to_upper(), n]
	_clear_note_later()

## Everything that is invariant under a search keystroke: the sort, the per-folder track
## counts, the queue hand-off, and the row strings themselves. Typing used to re-run all of
## it per character -- an O(n log n) sort plus an O(folders x tracks) prefix scan -- so it
## is split out here and called only when the library or the sort order actually changes.
## `_index` stays index-aligned with `_paths`, which is what `_row_path` and the queue mean.
func _reindex() -> void:
	_mtime.clear()
	if SORTS[_sort] == "DATE":  # stat once here, not once per comparison
		for p in _paths:
			_mtime[p] = FileAccess.get_modified_time(p)
	_paths.sort_custom(func(a: String, b: String) -> bool: return _cmp_by(SORTS[_sort], a, b))
	_index.clear()
	for path in _paths:
		var dir := path.get_base_dir()
		var row := "%s/%s" % [dir.get_file(), path.get_file()]
		# folded once here rather than on every keystroke for every track
		_index.append({"dir": dir, "file": path.get_file(), "row": row, "hay": row.to_lower()})
	_folder_list.clear()
	for f in _folders:
		var n := 0
		for path in _paths:
			if path.begins_with(f):
				n += 1
		_folder_list.add_item("%s  [%d]" % [f, n])
	_engine.set_queue(_paths, _current)
	_refill()

## Rebuilds only the visible list, matching the filter against the cached lowercase
## haystack. Cheap enough to run on every keystroke.
func _refill() -> void:
	_tracks.clear()
	_row_path.clear()
	_path_row.resize(_index.size())
	_path_row.fill(-1)          # a filtered-out track has no row at all
	var needle := _filter.to_lower()
	var grouped: bool = SORTS[_sort] == "FOLDER"
	var header := theme.get_color("font_color", "Green")
	var last_dir := ""
	var shown := 0
	for i in _index.size():
		var e: Dictionary = _index[i]
		# matched against folder + filename, which is what the row actually shows
		if not needle.is_empty() and not (e["hay"] as String).contains(needle):
			continue
		if grouped:
			if e["dir"] != last_dir:
				last_dir = e["dir"]
				_tracks.add_item((e["dir"] as String).get_file().to_upper() + "/")
				# headers are labels, not tracks: unselectable so a double-click or an
				# arrow key can never land on one
				_tracks.set_item_selectable(_tracks.item_count - 1, false)
				_tracks.set_item_custom_fg_color(_tracks.item_count - 1, header)
				_row_path.append(-1)
			_tracks.add_item("  " + e["file"])
		else:
			_tracks.add_item(e["row"])
		_path_row[i] = _tracks.item_count - 1
		_row_path.append(i)
		shown += 1
	if needle.is_empty():
		_count.text = "%d TRACKS // %d FOLDERS // %s" % [_paths.size(), _folders.size(), SORTS[_sort]]
	else:
		_count.text = "%d / %d MATCH" % [shown, _paths.size()]
	var playing := _paths.find(_current)
	# the current track can be filtered out, and then it simply has no row to select
	if playing >= 0 and playing < _path_row.size() and _path_row[playing] >= 0:
		_tracks.select(_path_row[playing])

func _walk(dir: String, out: Array[String]) -> void:
	for f in DirAccess.get_files_at(dir):
		if _is_audio(f):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_walk(dir.path_join(d), out)

func _add_folder(dir: String) -> void:
	if dir in _folders:
		return
	_folders.append(dir)
	_save()
	_rescan()

## Transient status text: the note sits in the status bar rather than a popup, so it
## needs clearing or it would still be there ten minutes later.
func _clear_note_later() -> void:
	var keep := _note
	await get_tree().create_timer(4.0).timeout
	if _note == keep:
		_note = ""

func _remove_folder() -> void:
	var sel := _folder_list.get_selected_items()
	if sel.is_empty():
		return
	var gone: String = _folders[sel[0]]
	_folders.remove_at(sel[0])
	_save()
	_rescan()
	_note = "  //  REMOVED %s" % gone.get_file().to_upper()
	_clear_note_later()

func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("library", "folders", _folders)
	cfg.set_value("library", "sort", _sort)
	cfg.set_value("library", "tbs", _tbs)
	cfg.set_value("library", "shuffle", _engine.shuffle)
	cfg.set_value("library", "repeat", int(_engine.repeat))
	cfg.set_value("audio", "volume", _volume)
	cfg.set_value("audio", "boost", _boost)
	cfg.set_value("audio", "fade", _fade_on)
	cfg.set_value("audio", "fade_ms", _fade_ms)
	cfg.set_value("audio", "play_delay_ms", _delay_ms)
	cfg.set_value("audio", "track_tempo", _director.track_tempo)
	# never persist FULLSCREEN: it would boot into a UI with no visible way out
	cfg.set_value("visual", "feed_size", _feed_prev if _feed == Feed.FULLSCREEN else _feed)
	cfg.set_value("visual", "max_fps", _max_fps)
	cfg.set_value("visual", "layout", _layout)
	cfg.set_value("visual", "skin", _skin)
	cfg.set_value("eq", "state", _eq.to_dict())
	cfg.set_value("eq", "presets", _presets)
	cfg.set_value("stats", "total_seconds", _total_secs)
	cfg.set_value("stats", "user_name", _user_name)
	cfg.set_value("visual", "viz", {
		"mode": int(_viz.mode), "color": _viz.color_index, "sens": _viz.sensitivity,
		"tilt": _viz.tilt_db, "height": _viz.height_scale, "speed": _viz.speed})
	cfg.save(_cfg)

## Closing the window is the only way out of the app, and the odometer only flushes every
## 30 s, so without this the last half-minute of every session is lost. This is the ONLY
## exit write: _exit_tree() used to duplicate it, and both fired on a normal close.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and is_node_ready():
		_save()

# --- playback (decoding, metadata and preload live in AudioEngine) ---------
func _open(i: int) -> void:
	if i < 0 or i >= _paths.size():
		return
	_video.stream = null
	if not _fade_on:
		_stop()           # legacy behaviour: the outgoing track dies immediately
	_busy = true
	_note = "  //  LOADING %s" % _paths[i].get_file()
	_engine.request(i)

func _on_track_ready(path: String, stream: AudioStream, _meta: Dictionary) -> void:
	_busy = false
	_note = ""
	_current = path
	if _fade_on and _audio.playing:
		_crossfade(stream)
	else:
		_stop()
		_audio.stream = stream  # already decoded on a worker, or handed over from preload
		_audio.volume_db = ACTIVE_DB
		_audio.play()
	# the spectrum feed follows whichever player is live, and attach() resets the tempo
	# lock for us -- it is per-track, and carrying it over would fight the new song
	_director.attach(_audio)
	_ticker.text = _engine.ticker_line(path)
	var i := _paths.find(path)
	if i >= 0 and i < _path_row.size() and _path_row[i] >= 0:
		_tracks.select(_path_row[i])

func _on_track_failed(path: String, reason: String) -> void:
	_busy = false
	_note = "  //  %s: %s" % [reason.to_upper(), path.get_file()]

func _next() -> void:
	_open(_engine.next_index())

func _prev() -> void:
	_open(_engine.prev_index())

# --- backend switch: the only place audio vs video APIs differ -------------
func _vid() -> bool: return _video.stream != null
func _len() -> float: return _video.get_stream_length() if _vid() else (_audio.stream.get_length() if _audio.stream else 0.0)
func _pos() -> float: return _video.stream_position if _vid() else _audio.get_playback_position()
func _playing() -> bool: return _video.is_playing() if _vid() else _audio.playing
func _paused() -> bool: return _video.paused if _vid() else _audio.stream_paused
func _seek(t: float) -> void:
	# ponytail: VideoStreamPlayer seeks to the nearest keyframe; exact only for audio.
	if _vid(): _video.stream_position = t
	else: _audio.seek(t)

func _set_paused(v: bool) -> void:
	if _vid(): _video.paused = v
	else: _audio.stream_paused = v

# --- transport ------------------------------------------------------------
## Single play/pause control -- the button's label is derived from _state(), so it can
## never disagree with what the audio is actually doing.
func _toggle() -> void:
	if _state() == "PLAYING":
		_set_paused(true)
	else:
		_play()

func _play() -> void:
	_set_paused(false)
	if _playing():
		return
	if _vid(): _video.play()
	elif _audio.stream: _audio.play()

func _stop() -> void:
	if _fade_tween and _fade_tween.is_valid():
		_fade_tween.kill()
	_fading = false
	_video.stop()
	for pl in [_a, _b]:
		pl.stop()
		pl.stream_paused = false
		pl.volume_db = ACTIVE_DB
	_scrub.value = 0.0

func _state() -> String:
	# AudioStreamPlayer.playing goes false while stream_paused is set, so test paused first.
	if _paused(): return "PAUSED"
	return "PLAYING" if _playing() else "STOPPED"

# --- scrub / volume: click-drag on a ProgressBar, no slider grabber art ----
func _on_scrub_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		_dragging = e.pressed
		if e.pressed: _scrub.value = _ratio_at(e.position.x, _scrub.size.x) * 100.0
		else: _seek(_scrub.value / 100.0 * _len())
	elif e is InputEventMouseMotion and _dragging:
		_scrub.value = _ratio_at(e.position.x, _scrub.size.x) * 100.0

func _on_vol_input(e: InputEvent) -> void:
	var held: bool = e is InputEventMouseMotion and (e.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0
	var click: bool = e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT
	if held or click:
		_volume = _ratio_at(e.position.x, _vol.size.x) * 100.0
		_vol.value = _volume
		_apply_volume()
		_save_soon()

# --- readout --------------------------------------------------------------
func _process(_delta: float) -> void:
	var l := _len()
	var p := _pos()
	if not _dragging and l > 0.0:
		_scrub.value = p / l * 100.0
	_elapsed.text = _fmt(p)
	_total.text = _fmt(l)
	_clock.text = Time.get_time_string_from_system()
	_nosignal.visible = _state() == "STOPPED"
	_nosignal.text = "[ LOADING ]" if _busy else "[ NO SIGNAL ]"
	_session_secs += _delta
	_total_secs += _delta
	_reboot_armed = maxf(_reboot_armed - _delta, 0.0)
	if _reboot_armed <= 0.0 and %Reboot.text != "REBOOT":
		%Reboot.text = "REBOOT"
	# periodic flush so a crash or a kill loses at most half a minute of the odometer
	if _total_secs >= _save_at:
		_save_at = _total_secs + 30.0
		_save()
	var vp := get_viewport().get_visible_rect().size
	if vp != _last_vp:
		_last_vp = vp
		_update_orientation()
	_flash = maxf(_flash - _delta, 0.0)
	%Play.text = "PAUSE" if _state() == "PLAYING" else "PLAY"
	_status.text = "STATE: %s  //  %s  //  ERR: %04d%s" % [
		_state(), _bpm_readout(), 0 if _note.is_empty() else 1, _note]
	_stats.text = "\n".join([
		"USER....%s" % (_user_name if _user_name else "-"),
		"SOURCE..%s" % _src(),
		"FORMAT..%s" % (_current.get_extension().to_upper() if _current else "PCM"),
		"LENGTH..%s" % _fmt(l),
		"CURSOR..%s" % _fmt(p),
		"REMAIN..%s" % _fmt(maxf(l - p, 0.0)),
		"STATE...%s" % _state(),
		"VOLUME..%03d%%" % int(_vol.value),
		"LIBRARY.%d" % _paths.size(),
		"SESSION.%s" % _hms(_session_secs),
		"TOTAL...%s" % _hms(_total_secs),
	])

func _src() -> String:
	if _current:
		return _current.get_file().to_upper()
	var f := video_path.get_file()
	return f.to_upper() if f else "DEMO_TONE.WAV"

# ponytail: synthesized so the player runs with an empty library -- harmless once folders are added.
func _demo_tone() -> AudioStreamWAV:
	var sr := 22050
	var buf := PackedByteArray()
	buf.resize(sr * 16 * 2)
	for i in sr * 16:
		var t := float(i) / sr
		var hz := 220.0 * pow(2.0, floor(fmod(t, 8.0)) / 12.0)
		buf.encode_s16(i * 2, int(sin(TAU * hz * t) * (1.0 - fmod(t, 1.0)) * 0.3 * 32767.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = sr
	s.data = buf
	return s

# ponytail: mm:ss only -- rolls past 60 min as "61:04", add hours when a source needs it.
func _fmt(t: float) -> String:
	return "%02d:%02d" % [int(t) / 60, int(t) % 60]

static func _is_audio(f: String) -> bool:
	return f.get_extension().to_lower() in EXTS

static func _ratio_at(x: float, w: float) -> float:
	return clampf(x / maxf(w, 1.0), 0.0, 1.0)


# --- visualizer settings (VISUAL tab) -------------------------------------
const VIZ_NAMES := ["SEGMENTS", "MIRROR", "WATERFALL", "GRID", "RADIAL", "MATRIX",
	"TUNNEL", "CRUISE", "FIRE", "KALEIDO"]

func _setup_visual() -> void:
	_viz.director = _director
	Skins.apply(theme, self, _skin)
	%Skin.text = "SKIN: %s" % _skin
	%Skin.pressed.connect(func() -> void:
		_skin = Skins.NAMES[(Skins.NAMES.find(_skin) + 1) % Skins.NAMES.size()]
		Skins.apply(theme, self, _skin)
		%Skin.text = "SKIN: %s" % _skin
		_refill()  # folder headers carry the accent colour, so they need repainting
		_save())
	_viz.mode = clampi(_viz_cfg.get("mode", 0), 0, VIZ_NAMES.size() - 1)
	# PRESETS.size() is the rainbow slot, one past the last fixed colour
	_viz.color_index = clampi(_viz_cfg.get("color", 0), 0, _viz.PRESETS.size())
	_viz.sensitivity = _viz_cfg.get("sens", 0.5)
	_viz.tilt_db = _viz_cfg.get("tilt", 20.0)
	_viz.height_scale = _viz_cfg.get("height", 0.62)
	_viz.speed = _viz_cfg.get("speed", 0.5)
	# one swatch per preset; a ColorPickerButton popup needs a pile of extra theme
	# entries and would not match anything else on screen
	# one extra swatch past the presets: the rainbow mode
	for i in _viz.PRESETS.size() + 1:
		var b := Button.new()
		b.custom_minimum_size = Vector2(0, 18)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var sb: StyleBox
		if i < _viz.PRESETS.size():
			var flat := StyleBoxFlat.new()
			flat.bg_color = _viz.PRESETS[i]
			flat.border_color = Color(0, 0, 0)
			flat.set_border_width_all(1)
			sb = flat
		else:
			sb = _rainbow_swatch()
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("hover", sb)
		b.add_theme_stylebox_override("pressed", sb)
		b.pressed.connect(func() -> void:
			_viz.color_index = i
			_save())
		%ColorRow.add_child(b)
	%VizMode.pressed.connect(func() -> void:
		_viz.mode = (_viz.mode + 1) % VIZ_NAMES.size()
		_refresh_visual()
		_save())
	for bar in [%Sens, %Tilt, %Height, %Speed]:
		bar.gui_input.connect(_on_viz_bar.bind(bar))
	_refresh_visual()

func _refresh_visual() -> void:
	%VizMode.text = "MODE: %s" % VIZ_NAMES[_viz.mode]
	%Sens.value = _viz.sensitivity * 100.0
	%Tilt.value = _viz.tilt_db / 40.0 * 100.0
	%Height.value = _viz.height_scale * 100.0
	%Speed.value = _viz.speed * 100.0

func _on_viz_bar(e: InputEvent, bar: ProgressBar) -> void:
	var held: bool = e is InputEventMouseMotion and (e.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0
	var click: bool = e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT
	if not (held or click):
		return
	var r := _ratio_at(e.position.x, bar.size.x)
	bar.value = r * 100.0
	if bar == %Sens: _viz.sensitivity = r
	elif bar == %Tilt: _viz.tilt_db = r * 40.0
	elif bar == %Speed: _viz.speed = r
	else: _viz.height_scale = maxf(r, 0.2)
	_save()


## Wheel scrolling lands on whole rows instead of part-way through one.
## ItemList in Godot 4.7 has NO fixed_item_height (only fixed_column_width and
## fixed_icon_size), so the row height has to be measured off a real item.
## A double-click gives a LIST row; everything downstream works in _paths indices.
func _on_row_activated(row: int) -> void:
	if row >= 0 and row < _row_path.size() and _row_path[row] >= 0:
		_open(_row_path[row])

func _on_list_scroll(e: InputEvent) -> void:
	if not (e is InputEventMouseButton and e.pressed):
		return
	var dir := 0
	if e.button_index == MOUSE_BUTTON_WHEEL_UP: dir = -1
	elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN: dir = 1
	else: return
	if _tracks.item_count == 0:
		return
	var step := _tracks.get_item_rect(0).size.y
	if step <= 0.0:
		return
	var bar := _tracks.get_v_scroll_bar()
	bar.value = snappedf(bar.value + dir * step * 3.0, step)
	_tracks.accept_event()


## Px437 is a codepage-437 bitmap font: no CJK glyphs at all, so the Japanese track
## names would render as tofu. Chaining a SystemFont fallback keeps the pixel look for
## everything it covers and quietly hands the rest to the OS.
func _setup_pixel_font() -> void:
	var px := theme.default_font
	if not px:
		return
	var cjk := SystemFont.new()
	cjk.font_names = PackedStringArray(["Yu Gothic UI", "Meiryo", "MS Gothic", "Segoe UI"])
	cjk.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	cjk.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	px.fallbacks = [cjk]


## Classic 12x19 arrow, built in code and nearest-scaled up. '#' is the black outline,
## '.' the white fill, space transparent. Drawing it rather than shipping a PNG keeps
## it one file and lets CURSOR_SCALE decide how chunky the pixels read.
const CURSOR_SCALE := 3
const CURSOR_ART := [
	"#",
	"##",
	"#.#",
	"#..#",
	"#...#",
	"#....#",
	"#.....#",
	"#......#",
	"#.......#",
	"#........#",
	"#.....#####",
	"#..#..#",
	"#.# #..#",
	"##  #..#",
	"#    #..#",
	"     #..#",
	"      #..#",
	"      #..#",
	"       ##",
]

func _setup_cursor() -> void:
	var w := 0
	for row in CURSOR_ART:
		w = maxi(w, row.length())
	var img := Image.create(w * CURSOR_SCALE, CURSOR_ART.size() * CURSOR_SCALE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in CURSOR_ART.size():
		var row: String = CURSOR_ART[y]
		for x in row.length():
			if row[x] == " ":
				continue
			var col := Color.BLACK if row[x] == "#" else Color.WHITE
			for dy in CURSOR_SCALE:
				for dx in CURSOR_SCALE:
					img.set_pixel(x * CURSOR_SCALE + dx, y * CURSOR_SCALE + dy, col)
	# hotspot at the tip, which is pixel (0,0) of the art
	Input.set_custom_mouse_cursor(ImageTexture.create_from_image(img), Input.CURSOR_ARROW, Vector2.ZERO)


# --- EQUALIZER tab --------------------------------------------------------
const EQ_MODES := ["OFF", "EZ EQ", "ADVANCED"]
const EZ_LABELS := ["LOW", "MID", "HIGH"]

func _setup_eq() -> void:
	_eq.setup("Master")
	# the EQ chain is inserted ahead of the analyser, which invalidates the handle the
	# director cached in its own _ready (children are ready before their parent)
	_director.rebind()
	_eq.from_dict(_eq_cfg)
	var cap := Equalizer.grabber_texture()
	for i in EZ_LABELS.size():
		_ez_faders.append(_make_fader(%EzPanel, EZ_LABELS[i], cap, _eq.ez_db[i]))
	for i in Equalizer.LANES:
		# label every fourth lane only; 16 stacked captions is unreadable at this width
		var tag := _lane_hz(i) if i % 4 == 0 else ""
		_adv_faders.append(_make_fader(%AdvPanel, tag, cap, _eq.lane_db[i]))
	for i in _ez_faders.size():
		_ez_faders[i].value_changed.connect(func(v: float) -> void: _eq.set_ez(i, v))
	for i in _adv_faders.size():
		var f := _adv_faders[i]
		f.drag_started.connect(func() -> void: _fader_base = _eq.lane_db.duplicate())
		f.value_changed.connect(_on_lane_changed.bind(i))
	%EqMode.pressed.connect(func() -> void:
		_eq.set_mode(((_eq.mode + 1) % 3) as Equalizer.Mode)
		_refresh_eq()
		_save())
	%EqAdapt.toggled.connect(func(on: bool) -> void:
		_eq.adapt = on
		_save())
	for bar in [%TBass, %BBE]:
		bar.gui_input.connect(_on_dsp_bar.bind(bar))
	_setup_presets()
	_eq.changed.connect(_save_soon)
	%EqAdapt.button_pressed = _eq.adapt
	%TBass.value = _eq.tbass * 100.0
	%BBE.value = _eq.bbe * 100.0
	_refresh_eq()

## Lane centre frequencies, 32 Hz to 16 kHz spread logarithmically across the 16 lanes.
func _lane_hz(i: int) -> String:
	var hz := 32.0 * pow(500.0, float(i) / float(Equalizer.LANES - 1))
	return "%dK" % int(hz / 1000.0) if hz >= 1000.0 else "%d" % int(hz)

func _make_fader(parent: Control, tag: String, cap: ImageTexture, value: float) -> VSlider:
	var lane := VBoxContainer.new()
	lane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lane.add_theme_constant_override("separation", 2)
	var f := VSlider.new()
	f.min_value = Equalizer.GAIN_MIN
	f.max_value = Equalizer.GAIN_MAX
	f.step = 0.5
	f.value = value
	f.size_flags_vertical = Control.SIZE_EXPAND_FILL
	f.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	# generated cap: the stock grabber is a soft round dot that matches nothing else here,
	# and a theme icon needs a real texture either way
	f.add_theme_icon_override("grabber", cap)
	f.add_theme_icon_override("grabber_highlight", cap)
	lane.add_child(f)
	var l := Label.new()
	l.text = tag
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lane.add_child(l)
	parent.add_child(lane)
	return f

## ADAPT rewrites every lane, so the other 15 sliders have to be pushed back without
## re-entering this handler -- hence the sync guard rather than disconnecting signals.
func _on_lane_changed(v: float, i: int) -> void:
	if _fader_sync:
		return
	if _fader_base.size() != Equalizer.LANES:
		_fader_base = _eq.lane_db.duplicate()
	_eq.apply_lane(i, v, _fader_base)
	if not _eq.adapt:
		return
	_fader_sync = true
	for j in Equalizer.LANES:
		if j != i:
			_adv_faders[j].value = _eq.lane_db[j]
	_fader_sync = false

func _on_dsp_bar(e: InputEvent, bar: ProgressBar) -> void:
	var held: bool = e is InputEventMouseMotion and (e.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0
	var click: bool = e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT
	if not (held or click):
		return
	var r := _ratio_at(e.position.x, bar.size.x)
	bar.value = r * 100.0
	_eq.set_dsp("tbass" if bar == %TBass else "bbe", r)

func _refresh_eq() -> void:
	%EqMode.text = "EQ: %s" % EQ_MODES[_eq.mode]
	%EzPanel.visible = _eq.mode == Equalizer.Mode.EZ
	%AdvPanel.visible = _eq.mode == Equalizer.Mode.ADVANCED
	%EqAdapt.visible = _eq.mode == Equalizer.Mode.ADVANCED
	%PresetRow.visible = _eq.mode == Equalizer.Mode.ADVANCED
	%NameRow.visible = _eq.mode == Equalizer.Mode.ADVANCED

func _apply_volume() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(_volume, 0.01) / 100.0))

## Continuous controls (EQ faders, the volume bar) change many times per second, and
## writing library.cfg at that rate would hammer the disk. Every such control funnels
## through here instead, so at most one write lands per 1.5 s no matter how many move.
func _save_soon() -> void:
	if has_meta("save_pending"):
		return
	set_meta("save_pending", true)
	await get_tree().create_timer(1.5).timeout
	remove_meta("save_pending")
	_save()


# --- uptime and factory reset ---------------------------------------------
func _hms(secs: float) -> String:
	var s := int(secs)
	var d := s / 86400
	var h := (s % 86400) / 3600
	return ("%dD %02d:%02d:%02d" % [d, h, (s % 3600) / 60, s % 60]) if d > 0 \
		else ("%02d:%02d:%02d" % [h, (s % 3600) / 60, s % 60])

## REBOOT is destructive -- it drops every library root -- so the first click only arms
## it. A second click within four seconds commits; otherwise it disarms itself.
func _on_reboot() -> void:
	if _reboot_armed <= 0.0:
		_reboot_armed = 4.0
		%Reboot.text = "CONFIRM?"
		return
	_reboot_armed = 0.0
	_stop()
	_current = ""
	_folders.clear()
	_paths.clear()
	_tbs.clear()
	_sort = 0
	_skin = "WIN98"
	_user_name = ""   # next launch asks for a name again
	_eq.reset_all()
	_presets.clear()
	_init_presets()
	_refresh_presets()
	_viz.mode = 0                 # SEGMENTS
	_viz.color_index = 0          # green
	_viz.sensitivity = 0.5
	_viz.tilt_db = 20.0
	_viz.height_scale = 0.62
	_viz.speed = 0.5
	_boost = 0
	_refresh_boost()
	_engine.shuffle = false
	_engine.repeat = AudioEngine.Repeat.ALL
	_refresh_transport()
	_director.track_tempo = false
	_director.reset()
	_refresh_beat()
	_layout = 0
	%Layout.selected = 0
	_update_orientation()
	_max_fps = 30
	%MaxFps.text = "30"
	Engine.max_fps = 30
	_apply_feed(Feed.LARGE)
	_audio.stream = _demo_tone()  # library is empty again, so the tone comes back
	for i in Equalizer.LANES:
		_adv_faders[i].value = 0.0
	for f in _ez_faders:
		f.value = 0.0
	%TBass.value = 0.0
	%BBE.value = 0.0
	%EqAdapt.button_pressed = true
	%Skin.text = "SKIN: WIN98"
	Skins.apply(theme, self, _skin)
	_refresh_eq()
	_refresh_visual()
	_rescan()
	_save()
	_note = "  //  REBOOTED TO DEFAULTS"
	_clear_note_later()


# --- TBS: a staging list of tracks flagged for sorting later ---------------
func _setup_tbs() -> void:
	%TbsAdd.pressed.connect(_tbs_add_selected)
	%TbsRemove.pressed.connect(_tbs_remove_selected)
	%TbsClear.pressed.connect(func() -> void:
		_tbs.clear()
		_refill_tbs()
		_save())
	%TbsList.item_activated.connect(func(row: int) -> void:
		# entries hold absolute paths, so a track that has since left the library
		# simply will not be found and the click is ignored
		var i := _paths.find(_tbs[row])
		if i >= 0:
			_open(i))
	_refill_tbs()

func _tbs_add_selected() -> void:
	var sel := _tracks.get_selected_items()
	if sel.is_empty():
		_note = "  //  SELECT A TRACK FIRST"
		_clear_note_later()
		return
	var row: int = sel[0]
	if row >= _row_path.size() or _row_path[row] < 0:
		return                  # a FOLDER group header: a label, not a track
	var path: String = _paths[_row_path[row]]
	if path in _tbs:
		_note = "  //  ALREADY IN TBS"
	else:
		_tbs.append(path)
		_note = "  //  TBS + %s" % path.get_file().to_upper()
		_refill_tbs()
		_save()
	_clear_note_later()

func _tbs_remove_selected() -> void:
	var sel: PackedInt32Array = %TbsList.get_selected_items()
	if sel.is_empty():
		return
	_tbs.remove_at(sel[0])
	_refill_tbs()
	_save()

func _refill_tbs() -> void:
	%TbsList.clear()
	for path in _tbs:
		var missing: bool = _paths.find(path) < 0
		%TbsList.add_item("%s/%s%s" % [path.get_base_dir().get_file(), path.get_file(),
			"  [MISSING]" if missing else ""])
	%TbsCount.text = "%d TO BE SORTED" % _tbs.size()


# --- crossfade -------------------------------------------------------------
const ACTIVE_DB := 0.0
const SILENT_DB := -80.0
const FADE_MS_MIN := 100
const FADE_MS_MAX := 10000
const DELAY_MS_MIN := 0
const DELAY_MS_MAX := 2000
## The incoming ramp is never allowed to collapse to nothing: if PLAY DELAY is set at or
## past FADE TIME the delay is pulled back so this much fade-in always survives, which is
## what keeps an over-long delay from turning the transition into a hard cut.
const MIN_FADE_IN_MS := 100

func _setup_fade() -> void:
	%Fade.pressed.connect(func() -> void:
		_fade_on = not _fade_on
		%Fade.text = "FADE: %s" % ("ON" if _fade_on else "OFF")
		_save())
	%FadeMs.text_submitted.connect(func(_s: String) -> void: _commit_fade_ms())
	%FadeMs.focus_exited.connect(_commit_fade_ms)
	%DelayMs.text_submitted.connect(func(_s: String) -> void: _commit_delay_ms())
	%DelayMs.focus_exited.connect(_commit_delay_ms)
	%Fade.text = "FADE: %s" % ("ON" if _fade_on else "OFF")
	%FadeMs.text = str(_fade_ms)
	%DelayMs.text = str(_delay_ms)

## Clamped on commit rather than per keystroke, so typing "2" on the way to "2500"
## does not get rewritten to the 100 ms floor under the cursor.
func _commit_fade_ms() -> void:
	_fade_ms = clampi(int(%FadeMs.text), FADE_MS_MIN, FADE_MS_MAX)
	%FadeMs.text = str(_fade_ms)
	%DelayMs.text = str(_delay_ms)
	_save()

## Equal-length ramps on two players. The active reference swaps up front so the
## transport, scrub and spectrum follow the incoming track from the first frame.
##
## Selecting a third track mid-fade is safe with only two players: the still-fading
## player becomes the new incoming one, its volume is reset explicitly, and the killed
## tween's cleanup callback is simply never needed.
func _crossfade(stream: AudioStream) -> void:
	if _fade_tween and _fade_tween.is_valid():
		_fade_tween.kill()
	var outgoing := _audio
	var incoming := _b if _audio == _a else _a

	# clamped so delay + fade-in always fits inside FADE TIME; both ramps therefore
	# finish together and the whole transition still lasts exactly FADE TIME
	var delay_ms: int = clampi(_delay_ms, DELAY_MS_MIN, maxi(_fade_ms - MIN_FADE_IN_MS, 0))
	var fade_s := float(_fade_ms) / 1000.0
	var delay_s := float(delay_ms) / 1000.0
	var in_s: float = maxf(fade_s - delay_s, float(MIN_FADE_IN_MS) / 1000.0)

	# armed but silent and NOT playing: starting it now would advance the playhead
	# during the delay, so the track would be mid-intro by the time it is audible
	incoming.stream = stream
	incoming.volume_db = SILENT_DB
	incoming.stream_paused = false
	_fading = true

	_fade_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_fade_tween.set_parallel(true)
	# T = 0: the outgoing track starts falling immediately, over the full fade time
	_fade_tween.tween_property(outgoing, "volume_db", SILENT_DB, fade_s)
	# T = PLAY DELAY: the incoming track starts, and only then begins its ramp
	_fade_tween.tween_callback(func() -> void:
		incoming.volume_db = SILENT_DB
		incoming.play()
		_audio = incoming              # transport and scrub hand over at the audible moment
		_director.attach(_audio)).set_delay(delay_s)
	_fade_tween.tween_property(incoming, "volume_db", ACTIVE_DB, in_s).set_delay(delay_s)
	# chain() waits for every parallel step, so this is the true end of the transition
	_fade_tween.chain().tween_callback(func() -> void:
		outgoing.stop()
		outgoing.volume_db = ACTIVE_DB
		outgoing.stream = null
		_fading = false)

func _commit_delay_ms() -> void:
	_delay_ms = clampi(int(%DelayMs.text), DELAY_MS_MIN, DELAY_MS_MAX)
	%DelayMs.text = str(_delay_ms)
	_save()

## Gradient chip for the rainbow option. A StyleBoxFlat holds a single colour, so the
## swatch has to be a stretched texture to show what the mode actually does.
func _rainbow_swatch() -> StyleBoxTexture:
	var img := Image.create(32, 1, false, Image.FORMAT_RGBA8)
	for x in 32:
		img.set_pixel(x, 0, Color.from_hsv(float(x) / 32.0, 0.85, 1.0))
	var sb := StyleBoxTexture.new()
	sb.texture = ImageTexture.create_from_image(img)
	return sb


# --- VISUAL FEED SIZE ------------------------------------------------------
enum Feed { LARGE, MEDIUM, SMALL, GONE, FULLSCREEN }
const FEED_NAMES := ["LARGE", "MEDIUM", "SMALL", "GONE", "FULLSCREEN"]
## Left-column stretch against the sidebar's 1.0. GONE and FULLSCREEN are visibility
## states rather than ratios, so their entries are never read.
const FEED_RATIO := [3.0, 1.5, 0.5, 0.0, 0.0]

func _setup_feed() -> void:
	for i in FEED_NAMES.size():
		%FeedSize.add_item(FEED_NAMES[i], i)
	%FeedSize.item_selected.connect(func(i: int) -> void:
		if i == Feed.FULLSCREEN and _feed != Feed.FULLSCREEN:
			_feed_prev = _feed          # remembered so ESC has somewhere to return to
		_apply_feed(i)
		_save())
	_apply_feed(_feed)

func _apply_feed(mode: int) -> void:
	_feed = mode
	var full: bool = mode == Feed.FULLSCREEN
	var gone: bool = mode == Feed.GONE
	# the transport now sits in Main, not in the feed's column, so GONE can drop the
	# whole column and hand the workspace to the sidebar without taking the deck with it
	%LeftColumn.visible = not gone
	%ScreenPanel.visible = true
	%RightSidebar.visible = not full
	%TopHeaderBar.visible = not full
	%TickerBar.visible = not full
	%StatusBar.visible = not full
	%ScrubRow.visible = not full
	%ControlDeck.visible = not full
	if not gone and not full:
		var table: Array = FEED_RATIO_V if _portrait else FEED_RATIO
		%LeftColumn.size_flags_stretch_ratio = table[mode]
	# the 6px chassis inset would leave a border in fullscreen
	for side in ["left", "top", "right", "bottom"]:
		%Margin.add_theme_constant_override("margin_" + side, 0 if full else 6)
	if %FeedSize.selected != mode:
		%FeedSize.selected = mode

## ESC only means anything in FULLSCREEN, so the event is left alone otherwise -- the
## boot screen and any future dialog keep their own handling. SPACE toggles play/pause;
## a focused LineEdit/etc consumes the keypress before it ever reaches here, so typing a
## space in a text field is unaffected.
func _unhandled_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k and k.pressed and k.keycode == KEY_SPACE:
		_toggle()
		get_viewport().set_input_as_handled()
		return
	if _feed != Feed.FULLSCREEN:
		return
	if k and k.pressed and k.keycode == KEY_ESCAPE:
		_apply_feed(Feed.LARGE if _feed_prev == Feed.FULLSCREEN else _feed_prev)
		_save()
		get_viewport().set_input_as_handled()


# --- MAX FRAMERATE ---------------------------------------------------------
const FPS_MIN := 10
const FPS_MAX := 240

func _setup_fps() -> void:
	%MaxFps.text_submitted.connect(func(_s: String) -> void: _commit_max_fps())
	%MaxFps.focus_exited.connect(_commit_max_fps)
	%MaxFps.text = str(_max_fps)
	Engine.max_fps = _max_fps

## Clamped on commit, same as the fade fields: rewriting per keystroke would fight the
## cursor while you type. Applied straight to Engine.max_fps, which caps the whole app.
func _commit_max_fps() -> void:
	_max_fps = clampi(int(%MaxFps.text), FPS_MIN, FPS_MAX)
	%MaxFps.text = str(_max_fps)
	Engine.max_fps = _max_fps
	_save()




# --- user EQ preset slots --------------------------------------------------
## Eight empty slots the user fills themselves. Nothing ships preloaded: a slot is a
## name plus a captured curve, and an unused one loads nothing when selected.
const EQ_SLOTS := 8

func _init_presets() -> void:
	while _presets.size() < EQ_SLOTS:
		_presets.append({"name": "CUSTOM %d" % (_presets.size() + 1), "lanes": [], "used": false})
	_presets.resize(EQ_SLOTS)

func _setup_presets() -> void:
	_init_presets()
	%EqPreset.item_selected.connect(_load_preset)
	%EqPresetSave.pressed.connect(_store_preset)
	%EqPresetName.text_submitted.connect(func(_s: String) -> void: _rename_preset())
	%EqPresetName.focus_exited.connect(_rename_preset)
	# uppercase as you type. Setting `text` in code does not re-emit text_changed, so
	# there is no recursion, but it does reset the caret -- hence saving the column.
	%EqPresetName.text_changed.connect(func(s: String) -> void:
		var up := s.to_upper()
		if up != s:
			var col: int = %EqPresetName.caret_column
			%EqPresetName.text = up
			%EqPresetName.caret_column = col)
	_refresh_presets()

## Rebuilt rather than patched in place: the list is eight items, and one code path
## means a rename, a save and a REBOOT all render identically.
func _refresh_presets() -> void:
	var keep: int = maxi(%EqPreset.selected, 0)
	%EqPreset.clear()
	for i in _presets.size():
		var slot: Dictionary = _presets[i]
		# a trailing dot marks a slot that holds a curve, so empty ones read as empty
		%EqPreset.add_item(("%s ." % slot["name"]) if slot["used"] else slot["name"], i)
	%EqPreset.selected = clampi(keep, 0, _presets.size() - 1)
	%EqPresetName.text = _presets[%EqPreset.selected]["name"]

func _load_preset(i: int) -> void:
	if i < 0 or i >= _presets.size():
		return
	var slot: Dictionary = _presets[i]
	# the dropdown moves itself when the user picks an item, but not when this is
	# called in code -- and a stale selection makes SAVE and rename hit the wrong slot
	if %EqPreset.selected != i:
		%EqPreset.selected = i
	%EqPresetName.text = slot["name"]
	if not slot["used"]:
		return                       # empty slot: selecting it just parks you there
	_eq.set_lanes(slot["lanes"])
	# sync guard up, or each fader write bounces back through _on_lane_changed
	_fader_sync = true
	for j in Equalizer.LANES:
		_adv_faders[j].value = _eq.lane_db[j]
	_fader_sync = false
	_fader_base = _eq.lane_db.duplicate()
	_note = "  //  LOADED %s" % slot["name"].to_upper()
	_clear_note_later()

func _store_preset() -> void:
	var i: int = maxi(%EqPreset.selected, 0)
	_presets[i] = {"name": _presets[i]["name"], "lanes": Array(_eq.lane_db), "used": true}
	_refresh_presets()
	_save()
	_note = "  //  SAVED %s" % _presets[i]["name"].to_upper()
	_clear_note_later()

func _rename_preset() -> void:
	var i: int = maxi(%EqPreset.selected, 0)
	var want: String = %EqPresetName.text.strip_edges().to_upper()
	if want.is_empty():
		want = "CUSTOM %d" % (i + 1)   # never leave a slot with no label at all
	_presets[i]["name"] = want
	_refresh_presets()
	_save()


# --- logo intro ------------------------------------------------------------
## Plays before the BIOS screen, then hands over. Godot 4 has no H.264 decoder, so the
## source MP4 was transcoded to Ogg Theora (intro.ogv) -- VideoStreamPlayer will not
## take an .mp4 at all, silently or otherwise.
func _start_intro() -> void:
	if not %IntroVid.stream:
		_begin_boot()
		return
	%Intro.visible = true
	%IntroVid.finished.connect(_begin_boot, CONNECT_ONE_SHOT)
	%IntroVid.play()

func _begin_boot() -> void:
	if not %Intro.visible:
		return                      # already handed over; a skip and the end can race
	%IntroVid.stop()
	%Intro.visible = false
	%Boot.begin(_user_name, _paths.size())

## Any key or click skips the logo. Handled here rather than in boot.gd because the
## boot screen has not been handed control yet.
func _input(event: InputEvent) -> void:
	if not %Intro.visible:
		return
	var skip: bool = (event is InputEventKey and event.pressed) or (event is InputEventMouseButton and event.pressed)
	if skip:
		_begin_boot()
		get_viewport().set_input_as_handled()


# --- volume booster --------------------------------------------------------
func _setup_boost() -> void:
	%Boost.gui_input.connect(_on_boost_bar)
	_refresh_boost()
	_eq.set_boost(_boost_gain())

## The dial reads 0-100; the engine still wants dB. 0 maps to unity, so the bottom of
## the slider is genuinely no boost rather than a small permanent one.
func _boost_gain() -> float:
	return float(_boost) / 100.0 * Equalizer.BOOST_MAX

## Same click-drag ProgressBar the volume, sensitivity and DSP controls use, so the
## booster reads as part of the same panel rather than a lone text field.
func _on_boost_bar(e: InputEvent) -> void:
	var held: bool = e is InputEventMouseMotion and (e.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0
	var click: bool = e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT
	if not (held or click):
		return
	_boost = clampi(int(roundf(_ratio_at(e.position.x, %Boost.size.x) * 100.0)), 0, 100)
	_refresh_boost()
	_eq.set_boost(_boost_gain())
	_save_soon()

func _refresh_boost() -> void:
	%Boost.value = float(_boost)
	%BoostLabel.text = "VOLUME BOOST: %d" % _boost


# --- responsive orientation ------------------------------------------------
## Portrait proportions for the same five feed sizes. The sidebar is always 1.0, so
## LARGE reads as 45/55 -- visualizer on top, tab dock filling the rest beneath it.
const FEED_RATIO_V := [0.82, 0.54, 0.30, 0.0, 0.0]
## Anything squarer than this counts as portrait. 1.1 rather than 1.0 so a near-square
## window commits to one layout instead of flickering between the two on tiny resizes.
const PORTRAIT_BELOW := 1.1
const LAYOUT_NAMES := ["AUTO-DETECT", "FORCE LANDSCAPE", "FORCE PORTRAIT"]

func _setup_layout() -> void:
	for i in LAYOUT_NAMES.size():
		%Layout.add_item(LAYOUT_NAMES[i], i)
	%Layout.selected = _layout
	%Layout.item_selected.connect(func(i: int) -> void:
		_layout = i
		_update_orientation()
		_save())
	get_viewport().size_changed.connect(_update_orientation)
	_update_orientation()

## Picks the axis and re-applies the feed size, which is what actually sets the split.
## Runs on every viewport resize, so dragging a window across the threshold restructures
## the UI live rather than only at startup.
func _update_orientation() -> void:
	var vp := get_viewport().get_visible_rect().size
	var aspect: float = vp.x / maxf(vp.y, 1.0)
	var want: bool = aspect < PORTRAIT_BELOW
	if _layout == 1:
		want = false
	elif _layout == 2:
		want = true
	_portrait = want
	# the 575 px floor keeps the tab dock usable beside the feed, but stacked it is a
	# horizontal floor on the WHOLE window -- anything narrower would overflow
	%RightSidebar.custom_minimum_size.x = 0.0 if _portrait else SIDEBAR_MIN_X
	%Workspace.vertical = _portrait
	_apply_feed(_feed)


## SHUF and RPT are persisted now, so their captions have to be derived from the engine
## rather than toggled in place -- the .tscn defaults would otherwise lie after a reload.
func _refresh_transport() -> void:
	%Shuffle.text = "SHUF:%s" % ("ON" if _engine.shuffle else "OFF")
	%Repeat.text = "RPT:%s" % ["OFF", "ALL", "ONE"][_engine.repeat]


## The tempo fit sweeps ~560 candidate periods every 0.5 s on the main thread, so it stays
## off unless asked for -- and AudioDirector._process returns before any of that work when
## it is off, which is what keeps the readout free. Saying "BPM: OFF" is honest; the old
## permanent "-- BPM" read as a tracker that was running and failing. The [#] ticker is
## only meaningful while the beat clock is live, so it is dropped entirely when it is not.
func _bpm_readout() -> String:
	if not _director.track_tempo:
		return "BPM: OFF"
	var tick := "[#]" if _flash > 0.0 else "[ ]"
	if _director.bpm <= 0.0:
		return "%s BPM: ----" % tick     # tracking, but not locked yet
	return "%s %.1f BPM" % [tick, _director.bpm]


# --- beat tracking ---------------------------------------------------------
## Width the tab dock needs to stay usable beside the visualizer. Only applied in
## landscape; see _update_orientation().
const SIDEBAR_MIN_X := 575.0

## The tempo fit is the one genuinely expensive thing in this program -- ~560 candidate
## periods swept against every onset in a 10 s history, every 0.5 s, on the main thread --
## and nothing but the status readout consumes it. So it ships off and this is the switch,
## rather than a cost every user pays for a number most will never look at.
func _setup_beat() -> void:
	%BeatTrack.pressed.connect(func() -> void:
		_director.track_tempo = not _director.track_tempo
		# drop the old lock either way: stale on resume, and a stale BPM would otherwise
		# sit in the status bar after switching off
		_director.reset()
		_refresh_beat()
		_save())
	_refresh_beat()

func _refresh_beat() -> void:
	%BeatTrack.text = "ON" if _director.track_tempo else "OFF"
