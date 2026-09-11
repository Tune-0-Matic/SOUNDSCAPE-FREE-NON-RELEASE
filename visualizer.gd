extends Control
## Pixelated spectrum visualizers. Drawn at low resolution inside a SubViewport and
## upscaled with NEAREST, so these are real pixels, not big smooth rectangles.
##
## Normalization (tilt + AGC + attack/release) is shared by every mode and was measured
## against this library -- see the constants below before changing any of them.

enum Mode { SEGMENTS, MIRROR, WATERFALL, GRID, RADIAL, MATRIX, TUNNEL, CRUISE, FIRE, KALEIDO }

const PRESETS: Array[Color] = [
	Color(0.18, 0.8, 0.443),   # green
	Color(1.0, 0.72, 0.2),     # amber
	Color(0.3, 0.85, 1.0),     # cyan
	Color(0.93, 0.93, 0.93),   # white
	Color(1.0, 0.35, 0.65),    # magenta
	Color(1.0, 0.29, 0.24),    # red
]
## One past the last preset: selecting it cycles hue instead of returning a fixed colour.
const RAINBOW := 6
const WF_HEIGHT := 96

var director: AudioDirector

var mode: Mode = Mode.SEGMENTS
var color_index := 0
## 0..1 -> span_db 80..30. A smaller window means quieter detail reaches full height.
var sensitivity := 0.5
## Cancels the library's ~39 dB natural slope (band 0 peaks -7 dBFS, band 28 -46).
## At 0 the top two thirds of the display never leave the floor.
var tilt_db := 20.0
var height_scale := 0.62

## 0..1 ballistics. Attack always outruns release -- equal rates read as flicker
## rather than as an EQ, so the two ranges never cross.
var speed := 0.5

# Auto-gain is mandatory, not polish: masters here range from -7 to -32 dBFS peak.
const AGC_FALL := 8.0
const AGC_FLOOR := -50.0

func _attack() -> float: return lerpf(0.22, 0.95, clampf(speed, 0.0, 1.0))
func _release() -> float: return lerpf(0.04, 0.40, clampf(speed, 0.0, 1.0))
func _peak_fall() -> float: return lerpf(0.15, 1.30, clampf(speed, 0.0, 1.0))

var _v := PackedFloat32Array()
var _peak := PackedFloat32Array()
var _db := PackedFloat32Array()
var _agc := -20.0
var _hue := 0.0
var _wf_img: Image
var _wf_tex: ImageTexture
var _wf_row := 0
var _tun_phase := 0.0
var _grid: Array[PackedFloat32Array] = []   # ring of past spectra, newest at _grid_head
var _grid_head := 0
var _fire: PackedFloat32Array           # heat grid, FIRE_W * FIRE_H
var _fire_img: Image
var _fire_tex: ImageTexture
var _road_phase := 0.0
var _car := Countach.new()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var n := AudioDirector.BAND_COUNT
	_v.resize(n)
	_peak.resize(n)
	_db.resize(n)
	for i in GRID_ROWS:
		var row := PackedFloat32Array()
		row.resize(n)
		_grid.append(row)
	_fire = PackedFloat32Array()
	_fire.resize(FIRE_W * FIRE_H)
	_fire_img = Image.create(FIRE_W, FIRE_H, false, Image.FORMAT_RGBA8)
	_fire_tex = ImageTexture.create_from_image(_fire_img)
	_wf_img = Image.create(n, WF_HEIGHT, false, Image.FORMAT_RGBA8)
	_wf_img.fill(Color(0, 0, 0, 0))
	_wf_tex = ImageTexture.create_from_image(_wf_img)
	add_child(_car)  # child so its _process drives the suspension jitter

func color() -> Color:
	if color_index >= PRESETS.size():
		# full saturation, full value: the bars are drawn on black, so a desaturated
		# sweep would just read as grey at the ends of the cycle
		return Color.from_hsv(fposmod(_hue, 1.0), 0.85, 1.0)
	return PRESETS[clampi(color_index, 0, PRESETS.size() - 1)]

func _process(delta: float) -> void:
	if not director:
		return
	var n := AudioDirector.BAND_COUNT
	if color_index >= PRESETS.size():
		# ~16 s per full cycle at the middle SPEED setting: a slow drift, not a strobe
		_hue += delta * 0.062 * lerpf(0.5, 2.0, speed)
	var span: float = lerpf(80.0, 30.0, clampf(sensitivity, 0.0, 1.0))
	var top := -200.0
	for i in n:
		# linear amplitude -> dB, then tilt. dB is the only mapping that spreads a real
		# mix over the full height instead of leaving it pinned to the floor.
		_db[i] = linear_to_db(maxf(director.levels[i], 1e-7)) + tilt_db * float(i) / float(n)
		top = maxf(top, _db[i])
	_agc = maxf(maxf(_agc - AGC_FALL * delta, top), AGC_FLOOR)
	var atk := _attack()
	var rel := _release()
	var pf := _peak_fall()
	for i in n:
		var t := clampf(inverse_lerp(_agc - span, _agc, _db[i]), 0.0, 1.0)
		_v[i] = lerpf(_v[i], t, atk if t > _v[i] else rel)
		_peak[i] = maxf(_peak[i] - pf * delta, _v[i])
	var bass := 0.0
	for i in mini(6, n):
		bass += _v[i]
	bass /= 6.0
	if mode == Mode.WATERFALL:
		_push_waterfall()
	elif mode == Mode.GRID:
		_push_grid()
	elif mode == Mode.FIRE:
		_step_fire(delta)
	elif mode == Mode.TUNNEL:
		# flight speed rides the bass; SPEED scales the whole thing
		_tun_phase += delta * (0.35 + bass * 2.4) * lerpf(0.5, 2.2, speed)
	elif mode == Mode.CRUISE:
		_road_phase += delta * (2.0 + bass * 9.0) * lerpf(0.5, 2.0, speed)
	queue_redraw()

## One new row per frame into a ring buffer. Writing a row and drawing the texture in
## two offset halves is far cheaper than shifting the image or drawing 32*96 rects.
func _push_waterfall() -> void:
	var c := color()
	for i in AudioDirector.BAND_COUNT:
		# squared: linear alpha made every cell bright and the display read as a green wall
		var v := _v[i] * _v[i]
		_wf_img.set_pixel(i, _wf_row, Color(c.r * v, c.g * v, c.b * v, v * 0.9))
	_wf_row = (_wf_row + 1) % WF_HEIGHT
	_wf_tex.update(_wf_img)

func _draw() -> void:
	match mode:
		Mode.SEGMENTS: _draw_segments(false)
		Mode.MIRROR: _draw_segments(true)
		Mode.WATERFALL: _draw_waterfall()
		Mode.GRID: _draw_grid()
		Mode.RADIAL: _draw_radial()
		Mode.MATRIX: _draw_matrix()
		Mode.TUNNEL: _draw_tunnel()
		Mode.CRUISE: _draw_cruise()
		Mode.FIRE: _draw_fire()
		Mode.KALEIDO: _draw_kaleido()

## Classic lit-cell ladder. Every coordinate is snapped to an integer or the low-res
## buffer smears the cell edges and the whole point of the SubViewport is lost.
func _draw_segments(mirror: bool) -> void:
	var n := AudioDirector.BAND_COUNT
	var c := color()
	var cell := 3
	var base := size.y * 0.5 if mirror else size.y
	var full := (size.y * 0.5 if mirror else size.y * height_scale)
	for i in n:
		var x := _col_x(i)
		var bw := _col_w(i)
		var lit := int(_v[i] * full / cell)
		for k in lit:
			var y := int(base - (k + 1) * cell)
			draw_rect(Rect2(x, y, bw, cell - 1), c.lerp(Color.WHITE, clampf(float(k) * cell / maxf(full, 1.0) - 0.55, 0.0, 1.0) * 0.8))
			if mirror:
				draw_rect(Rect2(x, int(base + k * cell), bw, cell - 1), c * 0.55)
		var py := int(base - _peak[i] * full)
		draw_rect(Rect2(x, clampi(py, 0, int(size.y) - 1), bw, 1), Color(c, 0.9))
		if mirror:
			draw_rect(Rect2(x, clampi(int(base + _peak[i] * full), 0, int(size.y) - 1), bw, 1), Color(c, 0.5))

func _draw_waterfall() -> void:
	var h := size.y
	var older := WF_HEIGHT - _wf_row
	# rows from _wf_row..end are the oldest, then 0.._wf_row wraps in beneath them
	draw_texture_rect_region(_wf_tex, Rect2(0, 0, size.x, h * older / WF_HEIGHT),
		Rect2(0, _wf_row, AudioDirector.BAND_COUNT, older))
	draw_texture_rect_region(_wf_tex, Rect2(0, h * older / WF_HEIGHT, size.x, h * _wf_row / WF_HEIGHT),
		Rect2(0, 0, AudioDirector.BAND_COUNT, _wf_row))



## Spectrum swept around a circle: 90s "scope" panel look.
func _draw_radial() -> void:
	var n := AudioDirector.BAND_COUNT
	var c := color()
	var cx := size.x * 0.5
	var cy := size.y * 0.5
	var span := minf(size.x, size.y)
	var r0 := span * 0.16
	var r1 := _outer(span, 0.46)
	for i in n:
		var a := TAU * float(i) / float(n) - PI * 0.5
		var d := cos(a)
		var e := sin(a)
		var len := r0 + _v[i] * (r1 - r0)
		var steps := int(len - r0)
		for k in steps:  # stepped so it stays chunky instead of an antialiased line
			var rr := r0 + k
			draw_rect(Rect2(int(cx + d * rr), int(cy + e * rr), 2, 2),
				Color(c, 0.35 + float(k) / maxf(float(steps), 1.0) * 0.65))
		var pr := r0 + _peak[i] * (r1 - r0)
		draw_rect(Rect2(int(cx + d * pr), int(cy + e * pr), 2, 2), Color(c, 0.95))
	draw_rect(Rect2(int(cx) - 1, int(cy) - 1, 2, 2), Color(c, 0.6))

## Dot-matrix panel: the whole grid is visible and unlit cells stay faintly on, the way
## a real VFD display looks. That dim grid is what separates it from SEGMENTS.
func _draw_matrix() -> void:
	var n := AudioDirector.BAND_COUNT
	var c := color()
	var rows := maxi(int(size.y * height_scale / 4.0), 1)
	for i in n:
		var x := _col_x(i)
		var bw := _col_w(i)
		var lit := int(_v[i] * rows)
		var pk := int(_peak[i] * rows)
		for k in rows:
			var y := int(size.y - (k + 1) * 4)
			if k < lit:
				draw_rect(Rect2(x, y, bw, 2), Color(c, 0.85))
			elif k == pk:
				draw_rect(Rect2(x, y, bw, 2), Color(c, 0.7))
			else:
				draw_rect(Rect2(x, y, bw, 2), Color(c, 0.18))  # unlit grid must stay visible or this is just SEGMENTS


## Column edges snapped independently so the bars tile the panel exactly. Some columns
## end up 1 px wider than others -- that is correct for pixel art, and it is what stops
## a dead strip appearing on the right at aspect ratios that do not divide evenly.
func _col_x(i: int) -> int:
	return int(float(i) * size.x / float(AudioDirector.BAND_COUNT))

func _col_w(i: int) -> int:
	var x1 := int(float(i + 1) * size.x / float(AudioDirector.BAND_COUNT))
	return maxi(x1 - _col_x(i) - 1, 1)


## Perspective wireframe tunnel. Rings recede on a 1/z curve and slide toward the
## viewer; the cross-section is not a circle but the spectrum itself, so the tube
## bulges wherever a band is loud. Strictly 1 px, unantialiased, no fills.
func _draw_tunnel() -> void:
	var n := AudioDirector.BAND_COUNT
	var c := color()
	var rings := 15
	# classic demoscene wobble -- the tunnel mouth drifts off centre
	var cx := size.x * 0.5 + sin(_tun_phase * 0.7) * size.x * 0.07
	var cy := size.y * 0.5 + cos(_tun_phase * 0.53) * size.y * 0.07
	var focal := minf(size.x, size.y) * 0.10
	var reach := lerpf(0.55, 1.15, height_scale)
	# fract is subtracted so depth indices stay monotonic: rings must be ordered for the
	# longitudinal spokes to join neighbours instead of leaping across the screen
	var frac: float = 1.0 - (_tun_phase - floor(_tun_phase))
	var prev := PackedVector2Array()
	var have_prev := false
	for k in rings:
		var z: float = (float(k) + frac) / float(rings)
		var rr: float = focal / maxf(z * z, 0.004) * reach
		if rr > maxf(size.x, size.y) * 2.0:
			continue  # this ring is past the camera
		var pts := PackedVector2Array()
		pts.resize(n)
		for i in n:
			var a := TAU * float(i) / float(n)
			var bulge := 1.0 + _v[i] * 0.75
			pts[i] = Vector2(cx + cos(a) * rr * bulge, cy + sin(a) * rr * bulge)
		var fade: float = clampf(1.0 - z * 0.85, 0.15, 1.0)
		for i in n:
			draw_line(pts[i], pts[(i + 1) % n], Color(c, fade), 1.0, false)
			if have_prev and i % 4 == 0:
				draw_line(pts[i], prev[i], Color(c, fade * 0.45), 1.0, false)
		prev = pts
		have_prev = true


# --- CRUISE: wireframe coupe on a receding road, EQ bars along both verges ---------
# All geometry is generated here as 3-D points and projected by hand. There is no mesh,
# no Camera3D and no model file: a wireframe this small is cheaper to project directly
# than to stand up a 3D pipeline for, and it keeps the pixel snapping the other modes use.

const EYE_Y := 1.30          # camera height above the road plane
const ROAD_HALF := 5.0       # half width of the tarmac
const VERGE := 6.4           # x offset of the EQ bars
const Z_NEAR := 0.55
const Z_FAR := 46.0
const RIB_SPACING := 2.4     # gap between transverse road ribs

func _proj(p: Vector3) -> Vector2:
	var f := size.y * 1.15
	var horizon := size.y * 0.40
	return Vector2(size.x * 0.5 + p.x * f / p.z, horizon + (EYE_Y - p.y) * f / p.z)

## Clips the segment to the near plane before projecting; without this a line crossing
## behind the camera wraps to the far side of the screen instead of running off it.
func _seg(a: Vector3, b: Vector3, c: Color) -> void:
	var p := a
	var q := b
	if p.z < Z_NEAR and q.z < Z_NEAR:
		return
	if p.z < Z_NEAR:
		p = p.lerp(q, (Z_NEAR - p.z) / (q.z - p.z))
	elif q.z < Z_NEAR:
		q = q.lerp(p, (Z_NEAR - q.z) / (p.z - q.z))
	draw_line(_proj(p), _proj(q), c, 1.0, false)

## Flat-shaded quad. Bars are short and always well in front of the camera, so a
## whole-polygon clip is enough -- no need for per-edge near-plane clipping here.
func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	if a.z < Z_NEAR or b.z < Z_NEAR or c.z < Z_NEAR or d.z < Z_NEAR:
		return
	var p := PackedVector2Array([_proj(a), _proj(b), _proj(c), _proj(d)])
	# A silent band collapses its bar to zero height, and triangulating a degenerate
	# polygon fails -- Godot logs "Invalid polygon data" every frame for every such bar.
	var area: float = absf((p[1] - p[0]).cross(p[3] - p[0])) + absf((p[2] - p[1]).cross(p[3] - p[1]))
	if area < 0.5:
		return
	draw_colored_polygon(p, col)

func _depth_fade(z: float, c: Color) -> Color:
	return Color(c, clampf(1.0 - (z - Z_NEAR) / Z_FAR, 0.12, 1.0))

func _draw_cruise() -> void:
	var n := AudioDirector.BAND_COUNT
	var c := color()
	_draw_sun(c)

	# --- road: two edges, a centre dash line, and scrolling transverse ribs
	for x in [-ROAD_HALF, ROAD_HALF]:
		_seg(Vector3(x, 0.0, Z_NEAR), Vector3(x, 0.0, Z_FAR), Color(c, 0.75))
	# subtracted, not added: as the phase advances each rib's z must DECREASE so the
	# road runs toward the camera. Adding it made the ribs recede, i.e. driving backwards.
	var offset := RIB_SPACING - fposmod(_road_phase, RIB_SPACING)
	var z := Z_NEAR + offset
	while z < Z_FAR:
		var f := _depth_fade(z, c)
		_seg(Vector3(-ROAD_HALF, 0.0, z), Vector3(ROAD_HALF, 0.0, z), Color(f, f.a * 0.5))
		_seg(Vector3(0.0, 0.0, z), Vector3(0.0, 0.0, z + RIB_SPACING * 0.45), f)  # centre dashes
		z += RIB_SPACING

	# --- EQ bars: one band per slot down each verge, nearest band = lowest frequency
	var span := (Z_FAR - 4.0) / float(n)
	for i in n:
		var bz := 2.0 + i * span
		var h := _v[i] * 2.6
		var pk := _peak[i] * 2.6
		var f := _depth_fade(bz, c)
		var d := span * 0.55
		for sx in [-VERGE, VERGE]:
			var x0: float = sx - 0.45 if sx > 0.0 else sx + 0.45
			# solid: fill the face pointing at the camera and the inner flank, then
			# draw the outline over the top so the edges stay crisp at low resolution
			_quad(Vector3(x0, 0.0, bz), Vector3(sx, 0.0, bz),
				Vector3(sx, h, bz), Vector3(x0, h, bz), Color(f, f.a * 0.75))
			_quad(Vector3(x0, 0.0, bz), Vector3(x0, 0.0, bz + d),
				Vector3(x0, h, bz + d), Vector3(x0, h, bz), Color(f, f.a * 0.45))
			_seg(Vector3(x0, 0.0, bz), Vector3(x0, h, bz), f)
			_seg(Vector3(sx, 0.0, bz), Vector3(sx, h, bz), f)
			_seg(Vector3(x0, h, bz), Vector3(sx, h, bz), f)
			_seg(Vector3(sx, h, bz), Vector3(sx, h, bz + d), Color(f, f.a * 0.45))
			_seg(Vector3(x0, pk, bz), Vector3(sx, pk, bz), Color(c, f.a))  # peak rail

	# --- the car: square to the road, wheels sitting on the road plane
	var cz := 6.2
	var body := Color(c, 1.0)
	var pts := _car.edges()
	var i := 0
	while i < pts.size():
		_seg(_car_pt(pts[i], cz), _car_pt(pts[i + 1], cz), body)
		i += 2

## Local car space -> world. No yaw: the car's axis stays parallel to the road edges.
## The suspension offset is applied here rather than baked into the geometry, so the
## edge list stays immutable and is built exactly once.
func _car_pt(p: Vector3, cz: float) -> Vector3:
	var o := _car.offset
	return Vector3(p.x + o.x, p.y + o.y, cz + p.z)


## Retrowave sun sitting on the horizon: outline plus horizontal chords whose spacing
## widens toward the bottom, so the top reads solid and the base breaks into bands.
## Drawn in screen space -- it is at infinity, so running it through the perspective
## divide would only fight the road for the same vanishing point.
func _draw_sun(c: Color) -> void:
	var r := minf(size.x, size.y) * 0.26
	var cx := size.x * 0.5
	var horizon := size.y * 0.40
	var cy := horizon - r * 0.30          # bisected by the horizon, most of it above
	var prev := Vector2.ZERO
	for k in 41:
		var a: float = TAU * float(k) / 40.0
		var p := Vector2(cx + cos(a) * r, cy + sin(a) * r)
		if k > 0 and p.y < horizon and prev.y < horizon:
			draw_line(prev, p, Color(c, 0.55), 1.0, false)
		prev = p
	var y := cy - r
	while y < horizon:
		var dy: float = y - cy
		var half: float = sqrt(maxf(r * r - dy * dy, 0.0))
		if half > 1.0:
			draw_line(Vector2(int(cx - half), int(y)), Vector2(int(cx + half), int(y)),
				Color(c, 0.28), 1.0, false)
		# above centre the bands sit tight; below they spread into the classic slices
		y += 2.0 if dy < 0.0 else 2.0 + (dy / r) * 8.0


# --- 1990s modes -----------------------------------------------------------

const GRID_ROWS := 20
const FIRE_W := 56
const FIRE_H := 40

## Demoscene fire. The bottom row is seeded from the spectrum, then each cell above
## averages its neighbours and cools -- the classic cellular fire, at a deliberately
## coarse grid so it upscales into chunky pixels rather than smooth flame.
func _step_fire(delta: float) -> void:
	var n := AudioDirector.BAND_COUNT
	for x in FIRE_W:
		var band: int = clampi(int(float(x) / float(FIRE_W) * float(n)), 0, n - 1)
		_fire[(FIRE_H - 1) * FIRE_W + x] = clampf(_v[band] * 1.1, 0.0, 1.0)
	var cool: float = 1.0 - clampf(delta * lerpf(0.5, 2.2, speed), 0.0, 0.10)
	for y in range(FIRE_H - 1):
		for x in FIRE_W:
			var below := (y + 1) * FIRE_W + x
			var l: float = _fire[below - 1] if x > 0 else _fire[below]
			var r: float = _fire[below + 1] if x < FIRE_W - 1 else _fire[below]
			_fire[y * FIRE_W + x] = (_fire[below] * 2.0 + l + r) * 0.25 * cool
	var c := color()
	for y in FIRE_H:
		for x in FIRE_W:
			var h: float = _fire[y * FIRE_W + x]
			# black -> accent -> white, with the white stop held back to the top of the
			# range so the flame body keeps its colour instead of blowing out
			var col := Color.BLACK.lerp(c, minf(h * 1.8, 1.0))
			col = col.lerp(Color.WHITE, clampf((h - 0.78) * 4.0, 0.0, 1.0))
			col.a = clampf(h * 1.5, 0.0, 1.0)
			_fire_img.set_pixel(x, y, col)
	_fire_tex.update(_fire_img)

func _draw_fire() -> void:
	draw_texture_rect(_fire_tex, Rect2(0, 0, size.x, size.y), false)

## Four-way mirrored fan: the spectrum swept through a quarter turn and reflected into
## the other three quadrants.
func _draw_kaleido() -> void:
	var n := AudioDirector.BAND_COUNT
	var c := color()
	var cx := size.x * 0.5
	var cy := size.y * 0.5
	var span := minf(size.x, size.y)
	var r0 := span * 0.08
	var r1 := _outer(span, 0.5)
	for i in n:
		var a: float = (PI * 0.5) * float(i) / float(n)
		var len: float = r0 + _v[i] * (r1 - r0)
		var pk: float = r0 + _peak[i] * (r1 - r0)
		for q in 4:
			# reflect rather than rotate, so adjacent quadrants meet as mirror images
			var dx: float = cos(a) * (1.0 if q == 0 or q == 3 else -1.0)
			var dy: float = sin(a) * (1.0 if q < 2 else -1.0)
			var steps := int(len - r0)
			for k in steps:
				var rr := r0 + float(k)
				draw_rect(Rect2(int(cx + dx * rr), int(cy + dy * rr), 2, 2),
					Color(c, 0.25 + float(k) / maxf(float(steps), 1.0) * 0.7))
			draw_rect(Rect2(int(cx + dx * pk), int(cy + dy * pk), 2, 2), Color(c, 0.95))


## Perspective spectrum landscape: every frame pushes the current spectrum onto a ring
## and the whole history is drawn receding toward a horizon, newest at the front. The
## classic 90s media-player "3D bars" view, done as a wireframe so it stays crisp at
## this resolution instead of turning into mush.
func _push_grid() -> void:
	_grid_head = (_grid_head - 1 + GRID_ROWS) % GRID_ROWS
	var row := _grid[_grid_head]
	for i in AudioDirector.BAND_COUNT:
		row[i] = _v[i]
	_grid[_grid_head] = row

func _draw_grid() -> void:
	var n := AudioDirector.BAND_COUNT
	var c := color()
	var cx := size.x * 0.5
	var horizon := size.y * 0.30
	var front := size.y * 0.92
	var lift := size.y * 0.42 * (height_scale / 0.62)
	# drawn back to front so nearer rows overlap the ones behind them
	for r in range(GRID_ROWS - 1, -1, -1):
		var row := _grid[(_grid_head + r) % GRID_ROWS]
		var z := 1.0 + float(r) * 0.32
		var base := horizon + (front - horizon) / z
		var half := size.x * 0.46 / z
		var fade := clampf(1.0 - float(r) / float(GRID_ROWS), 0.10, 1.0)
		var prev := Vector2.ZERO
		for i in n:
			var t := float(i) / float(n - 1)
			var p := Vector2(cx + (t - 0.5) * 2.0 * half, base - row[i] * lift / z)
			if i > 0:
				draw_line(Vector2(int(prev.x), int(prev.y)), Vector2(int(p.x), int(p.y)),
					Color(c, fade * 0.85), 1.0, false)
			prev = p


## Outer radius for the ring modes, capped at the circle inscribed in the canvas.
## Unclamped, `height_scale` at maximum pushed RADIAL to 0.74 and KALEIDO to 0.81 of the
## short side -- past the 0.5 half-extent -- so in a short wide panel the ring was cut
## flat top and bottom and read as a squashed oval rather than a circle.
func _outer(span: float, frac: float) -> float:
	return span * minf(frac * (height_scale / 0.62), 0.48)
