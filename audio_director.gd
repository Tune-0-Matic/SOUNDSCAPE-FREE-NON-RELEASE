class_name AudioDirector
extends Node
## Tracks music in real time: latency-corrected song clock, spectral-flux onsets,
## a phase-invariant tempo lock, and a PREDICTIVE beat clock (beats lead the kick,
## they never chase it). Attach a player with attach(), then listen to beat/bar/onset.

signal beat(index: int)
signal bar(index: int)
signal onset(strength: float)

## Analyser window. Measured (RaveShark): 0.1 -> beat clock -169 ms sd 196 (unlocked);
## 0.05 -> +6 ms sd 8; 0.03 collapses tempo confidence 0.87 -> 0.29. Do not "tune" this up.
const BUFFER_LENGTH := 0.05
const BAND_COUNT := 32   # >= 32 so the EQ has at least 32 bars to draw
const F_MIN := 30.0
const F_MAX := 16000.0
const HISTORY := 10.0     # seconds of onsets kept for the tempo fit
const MIN_ONSETS := 6     # below this a tempo fit is noise, not a reading
const PHASE_EASE := 0.25  # how hard a locked clock follows each new phase fit
## Onset flux is taken from the low bands only (~30-250 Hz: kick and low bass).
## Full-spectrum flux tracks a click track fine but smears on a real dense mix -
## measured 0.11 confidence on a pop track, versus a usable lock from these bands.
## (11 of 32 bands ~= 250 Hz, same cutoff as the old 9 of 24.)
const FLUX_BANDS := 11
const FLUX_WINDOW := 43   # ~0.7 s at 60 fps, the adaptive threshold window

## The analyser reports over a trailing buffer, and that lag is NOT covered by the
## standard latency formula. Calibration knob: onsets are timestamped back by this
## while the beat clock runs on true song time. 0.035 overcorrects to +42 ms.
@export var onset_lag := 0.066
@export var bus := "Master"
@export_range(1.0, 4.0) var sensitivity := 1.5
@export var beats_per_bar := 4
## Off by default: the spectrum feed costs almost nothing, but the tempo fit sweeps
## ~560 candidate periods every 0.5 s. Nothing but the BPM readout consumes it.
@export var track_tempo := false
@export_range(60.0, 200.0) var min_bpm := 60.0
@export_range(60.0, 240.0) var max_bpm := 200.0

var bpm := 0.0
var confidence := 0.0
var beat_index := -1
var bar_index := -1
var levels := PackedFloat32Array()
var energy := 0.0
var stereo := Vector2.ZERO   # summed left/right magnitude, for meters

var _player: AudioStreamPlayer
var _spectrum: AudioEffectSpectrumAnalyzerInstance
var _edges := PackedFloat32Array()
var _weight := PackedFloat32Array()
var _prev := PackedFloat32Array()
var _flux := PackedFloat32Array()
var _last_flux := 0.0
var _onsets := PackedFloat64Array()
var _last_onset := -1.0
var _phase := 0.0
var _next_fit := 0.0

# Sizing lives in _init, not _ready: a node added during SceneTree._initialize does not
# get _ready until the first idle frame, and attach() may legitimately be called before that.
func _init() -> void:
	for i in BAND_COUNT + 1:
		_edges.append(F_MIN * pow(F_MAX / F_MIN, float(i) / BAND_COUNT))
	for i in BAND_COUNT:
		_weight.append(1.0 + 2.0 * (1.0 - float(i) / BAND_COUNT))  # kick-weighted flux
	_prev.resize(BAND_COUNT)
	levels.resize(BAND_COUNT)

func _ready() -> void:
	_bind_analyser()  # in _ready so an inspector-set `bus` is already applied

## Inserting or removing a bus effect rebuilds every effect INSTANCE on that bus, which
## silently invalidates the analyser handle cached here -- levels just read 0.0 forever
## with no error. Anything that edits the Master chain must call this afterwards.
func rebind() -> void:
	_bind_analyser()

## Bus effects run BEFORE the bus volume is applied on send, so analysis is
## independent of wherever the user has the volume knob.
func _bind_analyser() -> void:
	var b := AudioServer.get_bus_index(bus)
	if b < 0:
		push_warning("AudioDirector: no bus named %s" % bus)
		return
	var slot := -1
	for i in AudioServer.get_bus_effect_count(b):
		if AudioServer.get_bus_effect(b, i) is AudioEffectSpectrumAnalyzer:
			slot = i
			break
	if slot < 0:
		var fx := AudioEffectSpectrumAnalyzer.new()
		fx.buffer_length = BUFFER_LENGTH
		AudioServer.add_bus_effect(b, fx)
		slot = AudioServer.get_bus_effect_count(b) - 1
	_spectrum = AudioServer.get_bus_effect_instance(b, slot)

func attach(p: AudioStreamPlayer) -> void:
	_player = p
	reset()

func reset() -> void:
	bpm = 0.0
	confidence = 0.0
	beat_index = -1
	bar_index = -1
	_onsets.clear()
	_flux.clear()
	_last_onset = -1.0
	_phase = 0.0
	_next_fit = 0.0
	_prev.fill(0.0)

## True song position: mix-ahead and output latency both removed.
func song_time() -> float:
	if not _player or not _player.playing:
		return 0.0
	var t := _player.get_playback_position() \
		+ AudioServer.get_time_since_last_mix() \
		- AudioServer.get_output_latency()
	return maxf(t, 0.0)

## Seconds until the next predicted beat; negative once it has passed. Use this to
## lead an animation instead of reacting after the fact.
func time_to_beat() -> float:
	if bpm <= 0.0:
		return INF
	var period := 60.0 / bpm
	return period - fposmod(song_time() - _phase, period)

func _process(_delta: float) -> void:
	if not _spectrum:
		return
	if not _player or not _player.playing:
		for i in BAND_COUNT:  # decay to silence instead of freezing the last frame
			levels[i] *= 0.85
		stereo *= 0.85
		return
	var t := song_time()
	_read_bands()
	if not track_tempo:
		return
	var f := _flux_now()
	if _is_onset(f, t):
		_onsets.append(t - onset_lag)  # timestamp back to where the sound really was
		_last_onset = t
		onset.emit(f)
	_last_flux = f
	while _onsets.size() > 0 and _onsets[0] < t - HISTORY:
		_onsets.remove_at(0)
	if t >= _next_fit:
		_next_fit = t + 0.5
		_fit_tempo()
	_advance_clock(t)

## get_magnitude_for_frequency_range returns a Vector2 of left/right magnitudes. The
## per-band level collapses that to one number, but the channel split is kept whole in
## `stereo` -- a VU meter needs it, and recomputing it later would mean a second FFT read.
func _read_bands() -> void:
	energy = 0.0
	stereo = Vector2.ZERO
	for i in BAND_COUNT:
		var lr := _spectrum.get_magnitude_for_frequency_range(_edges[i], _edges[i + 1])
		stereo += lr
		var m := lr.length()
		levels[i] = m
		energy += m

func _flux_now() -> float:
	var f := 0.0
	for i in BAND_COUNT:
		var d: float = levels[i] - _prev[i]
		if d > 0.0 and i < FLUX_BANDS:
			f += d * _weight[i]
		_prev[i] = levels[i]
	return f

## Adaptive threshold over a trailing window plus a debounce. Deliberately no
## local-peak test: it rejected the rising frame of short transients and starved the
## tempo fit (7-11 onsets where 15-30 were present). The debounce covers the tail.
func _is_onset(f: float, t: float) -> bool:
	_flux.append(f)
	if _flux.size() > FLUX_WINDOW:
		_flux.remove_at(0)
	if _flux.size() < FLUX_WINDOW:
		return false
	var mean := 0.0
	for v in _flux:
		mean += v
	mean /= _flux.size()
	if f <= mean * sensitivity:
		return false
	return _last_onset < 0.0 or t - _last_onset > 0.12  # debounce: cap at ~500 onsets/min

## Phase-invariant periodicity fit: treat onsets as impulses and take the DFT
## magnitude at each candidate tempo. The argument hands us the grid phase for free.
func _fit_tempo() -> void:
	if _onsets.size() < MIN_ONSETS:
		return
	var best := 0.0
	var best_bpm := 0.0
	var best_phase := 0.0
	var b := min_bpm
	while b <= max_bpm:
		var period := 60.0 / b
		var re := 0.0
		var im := 0.0
		for t in _onsets:
			var a := TAU * t / period
			re += cos(a)
			im += sin(a)
		var mag := sqrt(re * re + im * im) / _onsets.size()
		if mag > best:
			best = mag
			best_bpm = b
			best_phase = fposmod(atan2(im, re) / TAU * period, period)
		b += 0.25
	# Octave correction: an eighth-note grid scores as well as the quarter-note one.
	# Prefer the slower reading when it is nearly as strong.
	var half := best_bpm * 0.5
	if half >= min_bpm:
		var period := 60.0 / half
		var re := 0.0
		var im := 0.0
		for t in _onsets:
			var a := TAU * t / period
			re += cos(a)
			im += sin(a)
		var mag := sqrt(re * re + im * im) / _onsets.size()
		if mag > best * 0.8:
			best_bpm = half
			best = mag
			best_phase = fposmod(atan2(im, re) / TAU * period, period)
	# Once locked, ease the phase toward the new fit instead of snapping to it. A hard
	# re-anchor every fit makes the beat clock jitter (sd 89 ms at 90 BPM); this is a
	# PLL-lite that keeps the clock predictive while still following real tempo drift.
	if bpm > 0.0 and absf(best_bpm - bpm) < 1.0 and confidence > 0.5:
		var period := 60.0 / best_bpm
		var d := fposmod(best_phase - _phase + period * 0.5, period) - period * 0.5
		_phase = fposmod(_phase + d * PHASE_EASE, period)
	else:
		_phase = best_phase
	bpm = best_bpm
	confidence = best

func _advance_clock(t: float) -> void:
	if bpm <= 0.0:
		return
	var period := 60.0 / bpm
	var idx := int(floor((t - _phase) / period))
	if idx <= beat_index:
		return
	beat_index = idx
	beat.emit(idx)
	# A re-lock re-anchors the absolute index, so bars follow the music, not a
	# running count. bars_emitted != beats_emitted / beats_per_bar. That is correct.
	if idx % beats_per_bar == 0:
		bar_index = idx / beats_per_bar
		bar.emit(bar_index)
