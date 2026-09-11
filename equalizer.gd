class_name Equalizer
extends Node
## Real-time EQ and hardware-DSP emulation on the Master bus.
##
## Chain order matters: every effect here is inserted AHEAD of AudioDirector's
## SpectrumAnalyzer, so the visualizer shows post-EQ audio -- what you see is what you
## hear. Bus effects also run before the bus volume is applied on send, so none of this
## is affected by where the VOL control sits.
##
## Godot has no AudioEffectEQ16: the shipped sizes are EQ6/EQ10/EQ21. The 16 UI lanes
## are therefore a control curve that is interpolated onto EQ21's 21 bands.

signal changed()

enum Mode { OFF, EZ, ADVANCED }

const LANES := 16
const GAIN_MIN := -18.0
const GAIN_MAX := 18.0
## Gaussian width for ADAPT, in lanes. 1.6 puts the immediate neighbour at ~0.82 of the
## dragged lane and the third one out at ~0.17 -- a smooth shoulder, not a plateau.
const ADAPT_SIGMA := 1.6
## Ceiling for the output booster, in dB. 24 dB is 16x amplitude -- enough to bring a
## quiet master right up. The hard limiter behind it is what makes that safe: past the
## point where the signal would clip it saturates instead, so the top of the dial
## trades dynamics for loudness rather than breaking up.
const BOOST_MAX := 24.0

var mode: Mode = Mode.OFF
var adapt := true
var lane_db := PackedFloat32Array()
var ez_db := PackedFloat32Array()      # LOW, MID, HIGH
var tbass := 0.0                        # 0..1
var bbe := 0.0                          # 0..1
var boost_db := 0.0                     # extra output gain, 0..BOOST_MAX

var _bus := 0
var _eq: AudioEffectEQ21
var _tb_shelf: AudioEffectLowShelfFilter
var _tb_drive: AudioEffectDistortion
var _bbe_shelf: AudioEffectHighShelfFilter
var _bbe_phase: AudioEffectStereoEnhance
var _boost: AudioEffectAmplify
var _limiter: AudioEffectHardLimiter
var _idx := {}                          # effect -> bus slot, for true bypass
var _dirty := true

func _init() -> void:
	lane_db.resize(LANES)
	ez_db.resize(3)

## Inserted at ascending slots from the head of the bus so the analyser, which is
## appended by AudioDirector, always ends up last in the chain.
func setup(bus_name := "Master") -> void:
	_bus = maxi(AudioServer.get_bus_index(bus_name), 0)
	_eq = AudioEffectEQ21.new()
	_tb_shelf = AudioEffectLowShelfFilter.new()
	_tb_drive = AudioEffectDistortion.new()
	_bbe_shelf = AudioEffectHighShelfFilter.new()
	_bbe_phase = AudioEffectStereoEnhance.new()
	_boost = AudioEffectAmplify.new()
	_limiter = AudioEffectHardLimiter.new()

	_tb_shelf.cutoff_hz = 120.0
	# OVERDRIVE with a low keep_hf makes the harmonics band-limited, so T-BASS thickens
	# the bottom end instead of fizzing the whole mix like a full-range distortion would.
	_tb_drive.mode = AudioEffectDistortion.MODE_OVERDRIVE
	_tb_drive.keep_hf_hz = 320.0
	_bbe_shelf.cutoff_hz = 3500.0
	_bbe_phase.pan_pullout = 1.0
	# a hair under 0 dBFS: the booster exists to be pushed, and this is what stops it
	# turning into hard digital clipping on a loud master
	_limiter.ceiling_db = -0.5

	var slot := 0
	# boost + limiter go last in this block, so they act on the fully EQ'd signal.
	# They are effects rather than bus volume on purpose: bus volume is applied after
	# the chain on send, so a limiter placed here could never catch clipping it caused.
	for fx in [_eq, _tb_shelf, _tb_drive, _bbe_shelf, _bbe_phase, _boost, _limiter]:
		AudioServer.add_bus_effect(_bus, fx, slot)
		_idx[fx] = slot
		# add_bus_effect enables by default, and _push does not run until the first
		# frame -- without this the chain would process a frame or two of audio before
		# anything had decided it should be on.
		AudioServer.set_bus_effect_enabled(_bus, slot, false)
		slot += 1
	_dirty = true

# --- lane control ---------------------------------------------------------
## ADAPT spreads a change across neighbours using a Gaussian falloff, measured from a
## snapshot taken when the drag began. Working from the snapshot rather than the live
## values is what stops the curve compounding into a spike during a long drag.
func apply_lane(i: int, db: float, base: PackedFloat32Array) -> void:
	if not adapt:
		lane_db[i] = db
		_dirty = true
		return
	var delta := db - base[i]
	for j in LANES:
		var d := float(j - i)
		var w: float = exp(-(d * d) / (2.0 * ADAPT_SIGMA * ADAPT_SIGMA))
		lane_db[j] = clampf(base[j] + delta * w, GAIN_MIN, GAIN_MAX)
	_dirty = true

## Bulk lane write for presets. Goes through the same dirty flag as a fader drag, so
## the bus is updated on the next frame by the one code path that talks to AudioServer.
func set_lanes(values: Array) -> void:
	for i in mini(values.size(), LANES):
		lane_db[i] = clampf(values[i], GAIN_MIN, GAIN_MAX)
	_dirty = true

func set_ez(i: int, db: float) -> void:
	ez_db[i] = db
	_dirty = true

func set_mode(m: Mode) -> void:
	mode = m
	_dirty = true

## Independent of the EQ mode: the booster is an output stage, so it still works with
## the equalizer switched OFF. At 0 dB both effects bypass and the path stays clean.
func set_boost(db: float) -> void:
	boost_db = clampf(db, 0.0, BOOST_MAX)
	_dirty = true

func set_dsp(which: String, amount: float) -> void:
	if which == "tbass":
		tbass = clampf(amount, 0.0, 1.0)
	else:
		bbe = clampf(amount, 0.0, 1.0)
	_dirty = true

## EZ mode is three macros over the same 16-lane curve, weighted with raised cosines so
## the bands overlap smoothly rather than stepping at the crossover.
func _ez_curve() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(LANES)
	for i in LANES:
		var t := float(i) / float(LANES - 1)    # 0 at 32 Hz, 1 at 16 kHz
		var w_low: float = _bump(t, 0.0)
		var w_mid: float = _bump(t, 0.5)
		var w_high: float = _bump(t, 1.0)
		var sum: float = w_low + w_mid + w_high
		out[i] = (ez_db[0] * w_low + ez_db[1] * w_mid + ez_db[2] * w_high) / maxf(sum, 0.001)
	return out

static func _bump(t: float, centre: float) -> float:
	var d: float = absf(t - centre) / 0.5
	return 0.0 if d >= 1.0 else 0.5 + 0.5 * cos(d * PI)

# --- audio push -----------------------------------------------------------
## Everything is applied once per frame off a dirty flag, never inside the slider
## callback. During a fast drag ADAPT rewrites 16 lanes per input event; pushing 21 band
## gains plus five effect toggles on every one of those is what would stall the UI.
func _process(_delta: float) -> void:
	if not _dirty:
		return
	_dirty = false
	_push()
	changed.emit()

func _push() -> void:
	if not _eq:
		return
	var on := mode != Mode.OFF
	AudioServer.set_bus_effect_enabled(_bus, _idx[_eq], on)
	if on:
		var curve := lane_db if mode == Mode.ADVANCED else _ez_curve()
		var bands := _eq.get_band_count()
		for b in bands:
			# 21 bands sampled from a 16-point curve
			var t: float = float(b) / float(bands - 1) * float(LANES - 1)
			var i := int(floor(t))
			var f: float = t - float(i)
			var g: float = lerpf(curve[i], curve[mini(i + 1, LANES - 1)], f)
			_eq.set_band_gain_db(b, g)

	# T-BASS: shelf lift plus band-limited saturation, true-bypassed at zero
	var tb_on := on and tbass > 0.001
	AudioServer.set_bus_effect_enabled(_bus, _idx[_tb_shelf], tb_on)
	AudioServer.set_bus_effect_enabled(_bus, _idx[_tb_drive], tb_on)
	if tb_on:
		_tb_shelf.gain = 1.0 + tbass * 1.8
		_tb_drive.drive = tbass * 0.35
		_tb_drive.pre_gain = tbass * 4.0
		_tb_drive.post_gain = -tbass * 6.0   # claw back the level the drive adds

	var boosting := boost_db > 0.05
	AudioServer.set_bus_effect_enabled(_bus, _idx[_boost], boosting)
	AudioServer.set_bus_effect_enabled(_bus, _idx[_limiter], boosting)
	if boosting:
		_boost.volume_db = boost_db

	# BBE: high shelf for the sparkle, plus a small inter-channel time offset, which is
	# the phase-alignment half of what a Sonic Maximizer actually does
	var bb_on := on and bbe > 0.001
	AudioServer.set_bus_effect_enabled(_bus, _idx[_bbe_shelf], bb_on)
	AudioServer.set_bus_effect_enabled(_bus, _idx[_bbe_phase], bb_on)
	if bb_on:
		_bbe_shelf.gain = 1.0 + bbe * 1.5
		_bbe_phase.time_pullout_ms = bbe * 12.0
		_bbe_phase.surround = bbe * 0.4

## Back to defaults. Kept here rather than in the UI so there is one definition of
## "off", and the dirty flag makes the bus follow on the next frame like any other edit.
func reset_all() -> void:
	mode = Mode.OFF
	adapt = true
	for i in LANES:
		lane_db[i] = 0.0
	for i in 3:
		ez_db[i] = 0.0
	tbass = 0.0
	bbe = 0.0
	boost_db = 0.0
	_dirty = true

# --- persistence ----------------------------------------------------------
func to_dict() -> Dictionary:
	return {"mode": int(mode), "adapt": adapt, "lanes": Array(lane_db),
		"ez": Array(ez_db), "tbass": tbass, "bbe": bbe}

func from_dict(d: Dictionary) -> void:
	mode = clampi(d.get("mode", 0), 0, 2) as Mode
	adapt = d.get("adapt", true)
	var l: Array = d.get("lanes", [])
	for i in mini(l.size(), LANES):
		lane_db[i] = l[i]
	var e: Array = d.get("ez", [])
	for i in mini(e.size(), 3):
		ez_db[i] = e[i]
	tbass = d.get("tbass", 0.0)
	bbe = d.get("bbe", 0.0)
	_dirty = true

## Chunky fader cap, generated rather than shipped as a PNG. Deliberately neutral grey
## so it reads on every skin without needing to be rebuilt when the palette changes.
static func grabber_texture() -> ImageTexture:
	var w := 13
	var h := 7
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var edge: bool = x == 0 or y == 0 or x == w - 1 or y == h - 1
			var notch: bool = y == h / 2
			img.set_pixel(x, y, Color.BLACK if edge or notch else Color(0.80, 0.82, 0.78))
	return ImageTexture.create_from_image(img)
